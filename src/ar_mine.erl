-module(ar_mine).
-export([start/6, start/7, change_txs/2, stop/1, start_miner/2]).
-export([validate/3, validate_by_hash/2]).
-include("ar.hrl").
-include_lib("eunit/include/eunit.hrl").

%%% A module for managing mining of blocks on the weave,

%% State record for miners
-record(state, {
	parent, % miners parent process (initiator)
	current_block, % current block held by node
	recall_block, % recall block related to current
	txs, % the set of txs to be mined
	timestamp, % the block timestamp used for the mining
	timestamp_refresh_timer, % Reference for timer for updating the timestamp
	data_segment = <<>>, % the data segment generated for mining
	data_segment_duration, % duration in seconds of the last generation of the data segment.
	reward_addr, % the nodes reward address
	tags, % the nodes block tags
	diff, % the current network difficulty
	auto_update_diff, % should the diff be kept or updated automatically
	delay = 0, % hashing delay used for testing
	max_miners = ?NUM_MINING_PROCESSES, % max mining process to start (ar.hrl)
	miners = [], % miner worker processes
	nonces % nonce builder to ensure entropy
}).

%% @doc Spawns a new mining process and returns its PID.
start(CurrentB, RecallB, RawTXs, RewardAddr, Tags, Parent) ->
	do_start(CurrentB, RecallB, RawTXs, RewardAddr, Tags, auto_update, Parent).

start(CurrentB, RecallB, RawTXs, RewardAddr, Tags, StaticDiff, Parent) when is_integer(StaticDiff) ->
	do_start(CurrentB, RecallB, RawTXs, RewardAddr, Tags, StaticDiff, Parent).

do_start(CurrentB, RecallB, RawTXs, unclaimed, Tags, Diff, Parent) ->
	do_start(CurrentB, RecallB, RawTXs, <<>>, Tags, Diff, Parent);
do_start(CurrentB, RecallB, RawTXs, RewardAddr, Tags, Diff, Parent) ->
	{NewDiff, AutoUpdateDiff} = case Diff of
		auto_update -> {not_set, true};
		_ -> {Diff, false}
	end,
	start_server(
		#state {
			parent = Parent,
			current_block = CurrentB,
			recall_block = RecallB,
			data_segment_duration = 0,
			reward_addr = RewardAddr,
			tags = Tags,
			max_miners = ar_meta_db:get(max_miners),
			nonces = [],
			diff = NewDiff,
			auto_update_diff = AutoUpdateDiff
		},
		RawTXs
	).

%% @doc Stop a running mining server.
stop(PID) ->
	PID ! stop.

%% @doc Update the set of TXs that the miner is mining on.
change_txs(PID, NewTXs) ->
	PID ! {new_data, NewTXs}.

%% @doc Validate that a given hash/nonce satisfy the difficulty requirement.
validate(BDS, Nonce, Diff) ->
	case NewHash = ar_weave:hash(BDS, Nonce) of
		<< 0:Diff, _/bitstring >> -> NewHash;
		_ -> false
	end.

%% @doc Validate that a given block data segment hash satisfies the difficulty requirement.
validate_by_hash(BDSHash, Diff) ->
	case BDSHash of
		<< 0:Diff, _/bitstring >> ->
			true;
		_ ->
			false
	end.


%% PRIVATE


%% @doc Takes a state and a set of transactions and return a new state with the
%% new set of transactions.
update_txs(
	S = #state {
		current_block = CurrentB,
		diff = CurrentDiff,
		data_segment_duration = BDSGenerationDuration,
		auto_update_diff = AutoUpdateDiff
	},
	TXs
) ->
	NextBlockTimestamp = next_block_timestamp(BDSGenerationDuration),
	NextDiff = case AutoUpdateDiff of
		true -> calc_diff(CurrentB, NextBlockTimestamp);
		false -> CurrentDiff
	end,
	%% Filter out invalid TXs. A TX can be valid by itself, but still invalid
	%% in the context of the other TXs and the block it would be mined to.
	ValidTXs =
		lists:filter(
			fun(TX) ->
				ar_tx:verify(TX, NextDiff, CurrentB#block.wallet_list)
			end,
			ar_node_utils:filter_all_out_of_order_txs(
				CurrentB#block.wallet_list,
				TXs
			)
		),
	update_data_segment(S, ValidTXs, NextBlockTimestamp, NextDiff).

%% @doc Generate a new timestamp to be used in the next block. To compensate for
%% the time it takes to generate the block data segment, adjust the timestamp
%% with the same time it took to generate the block data segment the last time.
next_block_timestamp(BDSGenerationDuration) ->
	os:system_time(seconds) + BDSGenerationDuration.

%% @doc Given a block calculate the difficulty to mine on for the next block.
%% Difficulty is retargeted each ?RETARGET_BlOCKS blocks, specified in ar.hrl
%% This is done in attempt to maintain on average a fixed block time.
calc_diff(CurrentB, NextBlockTimestamp) ->
	ar_retarget:maybe_retarget(
		CurrentB#block.height + 1,
		CurrentB#block.diff,
		NextBlockTimestamp,
		CurrentB#block.last_retarget
	).

%% @doc Generate a new data_segment and update the timestamp and diff.
update_data_segment(S = #state { txs = TXs }) ->
	update_data_segment(S, TXs).

%% @doc Generate a new data_segment and update the timestamp, diff and transactions.
update_data_segment(
	S = #state {
		data_segment_duration = BDSGenerationDuration,
		auto_update_diff = AutoUpdateDiff,
		diff = CurrentDiff,
		current_block = CurrentB
	},
	TXs
) ->
	BlockTimestamp = next_block_timestamp(BDSGenerationDuration),
	Diff = case AutoUpdateDiff of
		true -> calc_diff(CurrentB, BlockTimestamp);
		false -> CurrentDiff
	end,
	update_data_segment(S, TXs, BlockTimestamp, Diff).

update_data_segment(S, TXs, BlockTimestamp, Diff) ->
	{DurationMicros, BDS} = timer:tc(fun() ->
		ar_block:generate_block_data_segment(
			S#state.current_block,
			S#state.recall_block,
			TXs,
			S#state.reward_addr,
			BlockTimestamp,
			S#state.tags
		)
	end),
	NewS = S#state {
		timestamp = BlockTimestamp,
		diff = Diff,
		txs = TXs,
		data_segment = BDS,
		data_segment_duration = round(DurationMicros / 1000000)
	},
	reschedule_timestamp_refresh(NewS).

reschedule_timestamp_refresh(S = #state{
	timestamp_refresh_timer = Timer,
	data_segment_duration = BDSGenerationDuration
}) ->
	timer:cancel(Timer),
	case ?MINING_TIMESTAMP_REFRESH_INTERVAL - BDSGenerationDuration  of
		TimeoutSeconds when TimeoutSeconds =< 0 ->
			ar:warn(
				"ar_mine: Updating data segment slower (~B seconds) than timestamp refresh interval (~B seconds)",
				[BDSGenerationDuration, ?MINING_TIMESTAMP_REFRESH_INTERVAL]
			),
			self() ! refresh_timestamp,
			S#state{ timestamp_refresh_timer = no_timer };
		TimeoutSeconds ->
			case timer:send_after(TimeoutSeconds * 1000, refresh_timestamp) of
				{ok, Ref} ->
					S#state{ timestamp_refresh_timer = Ref };
				{error, Reason} ->
					ar:err("ar_mine: Reschedule timestamp refresh failed: ~p", [Reason]),
					S
			end
	end.

%% @doc Start the main mining server.
start_server(S, TXs) ->
	spawn(fun() ->
		server(start_miners(update_txs(S, TXs)))
	end).

%% @doc The main mining server.
server(
	S = #state {
		parent = Parent,
		miners = Miners
	}
) ->
	receive
		% Stop the mining process and all the workers.
		stop ->
			stop_miners(Miners),
			ok;
		% Update the miner to mine on a new set of data.
		{new_data, TXs} ->
			server(restart_miners(update_txs(S, TXs)));
		%% The block timestamp must be reasonable fresh since it's going to be
		%% validated on the remote nodes when it's propagated to them. Only blocks
		%% with a timestamp close to current time will be accepted in the propagation.
		refresh_timestamp ->
			server(restart_miners(update_data_segment(S)));
		% Handle a potential solution for the mining puzzle.
		% Returns the solution back to the node to verify and ends the process.
		{solution, Hash, Nonces, MinedTXs, MinedDiff, MinedTimestamp} ->
			Parent ! {work_complete, MinedTXs, Hash, MinedDiff, Nonces, MinedTimestamp},
			stop_miners(Miners)
	end.

%% @doc Start the workers and return the new state.
start_miners(S = #state {max_miners = MaxMiners}) ->
	Miners =
		lists:map(
			fun(_) -> spawn(?MODULE, start_miner, [S, self()]) end,
			lists:seq(1, MaxMiners)
		),
	lists:foreach(
		fun(Pid) -> Pid ! hash end,
		Miners
	),
	S#state {miners = Miners}.

%% @doc Stop all workers.
stop_miners(Miners) ->
	lists:foreach(
		fun(Pid) -> Pid ! stop end,
		Miners
	).

%% @doc Stop and then start the workers again and return the new state.
restart_miners(S) ->
	stop_miners(S#state.miners),
	start_miners(S).

%% @doc A worker process to hash the data segment searching for a solution
%% for the given diff.
start_miner(S, Supervisor) ->
	process_flag(priority, low),
	miner(S, Supervisor).

%% @doc The minig server performing the hashing.
%% TODO: Change byte string for nonces to bitstring
miner(
	S = #state {
		data_segment = BDS,
		diff = Diff,
		nonces = Nonces,
		txs = TXs,
		timestamp = Timestamp
	},
	Supervisor
) ->
	receive
		stop -> ok;
		hash ->
			self() ! hash,
			case validate(BDS, iolist_to_binary(Nonces), Diff) of
				false ->
					case length(Nonces) >= 512 of
						false ->
							miner(
								S#state {
									nonces =
										[bool_to_binary(coinflip()) | Nonces]
								},
								Supervisor
							);
						true ->
							miner(
								S#state {
									nonces = []
								},
								Supervisor
							)
					end;
				Hash ->
					Supervisor ! {solution, Hash, iolist_to_binary(Nonces), TXs, Diff, Timestamp}
			end
	end.

%% @doc Converts a boolean value to a binary of 0 or 1.
bool_to_binary(true) -> <<1>>;
bool_to_binary(false) -> <<0>>.

%% @doc A simple boolean coinflip.
coinflip() ->
	case rand:uniform(2) of
		1 -> true;
		2 -> false
	end.


%% Tests


%% @doc Test that found nonces abide by the difficulty criteria.
basic_test() ->
	B0 = ar_weave:init(),
	ar_node:start([], B0),
	B1 = ar_weave:add(B0, []),
	B = hd(B1),
	RecallB = hd(B0),
	start(B, RecallB, [], unclaimed, [], self()),
	assert_mine_output(B, RecallB, []).

%% @doc Ensure that we can change the transactions while mining is in progress.
change_txs_test_() ->
	{timeout, 20, fun() ->
		[B0] = ar_weave:init(),
		B = B0,
		RecallB = B0,
		FirstTXSet = [ar_tx:new()],
		SecondTXSet = FirstTXSet ++ [ar_tx:new(), ar_tx:new()],
		%% Start mining with a high enough difficulty, so that the mining won't
		%% finish before adding more TXs.
		Diff = 20,
		PID = start(B, RecallB, FirstTXSet, unclaimed, [], Diff, self()),
		change_txs(PID, SecondTXSet),
		assert_mine_output(B, RecallB, SecondTXSet, Diff)
	end}.

%% @doc Ensure that the block timestamp gets updated regularly while mining.
timestamp_refresh_test_() ->
	{timeout, 20, fun() ->
		[B0] = ar_weave:init(),
		B = B0,
		RecallB = B0,
		%% Start mining with a high enough difficulty, so that the block
		%% timestamp gets refreshed at least once. Since we might be unlucky
		%% and find the block too fast, we retry until it succeeds.
		Run = fun(_) ->
			TXs = [],
			start(B, RecallB, TXs, unclaimed, [], 19, self()),
			StartTime = os:system_time(seconds),
			{_, MinedTimestamp} = assert_mine_output(B, RecallB, TXs),
			MinedTimestamp > StartTime
		end,
		?assert(lists:any(Run, lists:seq(1, 20)))
	end}.

%% @doc Ensures ar_mine can be started and stopped.
start_stop_test() ->
	B0 = ar_weave:init(),
	ar_node:start([], B0),
	B1 = ar_weave:add(B0, []),
	B = hd(B1),
	RecallB = hd(B0),
	PID = start(B, RecallB, [], unclaimed, [], self()),
	link(PID),
	stop(PID),
	assert_not_alive(PID, 500).

%% @doc Ensures a miner can be started and stopped.
miner_start_stop_test() ->
	S = #state{},
	PID = spawn_link(fun() -> start_miner(S, self()) end),
	stop_miners([PID]),
	assert_not_alive(PID, 500).

assert_mine_output(B, RecallB, TXs, Diff) ->
	Result = assert_mine_output(B, RecallB, TXs),
	?assertMatch({Diff, _}, Result),
	Result.

assert_mine_output(B, RecallB, TXs) ->
	receive
		{work_complete, MinedTXs, Hash, MinedDiff, Nonce, Timestamp} ->
			?assertEqual(lists:sort(TXs), lists:sort(MinedTXs)),
			BDS = ar_block:generate_block_data_segment(
				B,
				RecallB,
				TXs,
				<<>>,
				Timestamp,
				[]
			),
			?assertEqual(
				crypto:hash(
					?MINING_HASH_ALG,
					<< Nonce/binary, BDS/binary >>
				),
				Hash
			),
			?assertMatch(
				<< 0:MinedDiff, _/bitstring >>,
				Hash
			),
			{MinedDiff, Timestamp}
	after 20000 ->
		error(timeout)
	end.

assert_not_alive(PID, Timeout) ->
	Do = fun () -> not is_process_alive(PID) end,
	?assert(ar_util:do_until(Do, 50, Timeout)).
