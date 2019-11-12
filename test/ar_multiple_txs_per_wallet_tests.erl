-module(ar_multiple_txs_per_wallet_tests).

-include("src/ar.hrl").
-include_lib("eunit/include/eunit.hrl").

-import(ar_test_node, [start/1, slave_start/1, connect_to_slave/0]).
-import(ar_test_node, [slave_mine/1]).
-import(ar_test_node, [assert_wait_until_receives_txs/2]).
-import(ar_test_node, [wait_until_height/2, assert_slave_wait_until_height/2]).
-import(ar_test_node, [slave_call/3]).
-import(ar_test_node, [post_tx_to_slave/2, post_tx_to_master/2]).
-import(ar_test_node, [assert_post_tx_to_slave/2, assert_post_tx_to_master/2]).
-import(ar_test_node, [sign_tx/1, sign_tx/2, sign_tx/3]).
-import(ar_test_node, [get_tx_anchor/0, get_tx_anchor/1, join/1]).
-import(ar_test_node, [assert_wait_until_block_hash_list/2]).
-import(ar_test_node, [get_last_tx/1, get_last_tx/2]).
-import(ar_test_node, [get_tx_confirmations/2]).
-import(ar_test_node, [disconnect_from_slave/0]).

-import(ar_test_fork, [test_on_fork/3]).

accepts_gossips_and_mines_test_() ->
	PrepareTestFor = fun(BuildTXSetFun) ->
		fun() ->
			%% The weave has to be initialised under the fork so that
			%% we can get the correct price estimations according
			%% to the new pricinig model.
			Key = {_, Pub} = ar_wallet:new(),
			Wallets = [{ar_wallet:to_address(Pub), ?AR(5), <<>>}],
			[B0] = ar_weave:init(Wallets),
			accepts_gossips_and_mines(B0, BuildTXSetFun(Key, B0))
		end
	end,
	lists:map(
		fun({Name, TestFun}) ->
			test_on_fork(
				height_1_8,
				0,
				{Name, TestFun}
			)
		end,
		[
			{
				"One transaction with wallet list anchor followed by one with block anchor",
				PrepareTestFor(fun one_wallet_list_one_block_anchored_txs/2)
			},
			{
				"Two transactions with block anchor",
				PrepareTestFor(fun two_block_anchored_txs/2)
			}
		]
	).

keeps_txs_after_new_block_test_() ->
	PrepareTestFor = fun(BuildFirstTXSetFun, BuildSecondTXSetFun) ->
		fun() ->
			Key = {_, Pub} = ar_wallet:new(),
			Wallets = [{ar_wallet:to_address(Pub), ?AR(5), <<>>}],
			[B0] = ar_weave:init(Wallets),
			keeps_txs_after_new_block(
				B0,
				BuildFirstTXSetFun(Key, B0),
				BuildSecondTXSetFun(Key, B0)
			)
		end
	end,
	lists:map(
		fun({Name, TestFun}) ->
			test_on_fork(
				height_1_8,
				0,
				{Name, TestFun}
			)
		end,
		[
			%% Master receives the second set then the first set. Slave only
			%% receives the second set.
			{
				"First set: two block anchored txs, second set: empty",
				PrepareTestFor(fun two_block_anchored_txs/2, fun empty_tx_set/2)
			},
			{
				"First set: empty, second set: two block anchored txs",
				PrepareTestFor(fun empty_tx_set/2, fun two_block_anchored_txs/2)
			},
			{
				"First set: two block anchored txs, second set: two block anchored txs",
				PrepareTestFor(fun two_block_anchored_txs/2, fun two_block_anchored_txs/2)
			}
		]
	).

returns_error_when_txs_exceed_balance_test_() ->
	PrepareTestFor = fun(BuildTXSetFun) ->
		fun() ->
			{B0, TXs, ExceedBalanceTX} = BuildTXSetFun(),
			returns_error_when_txs_exceed_balance(B0, TXs, ExceedBalanceTX)
		end
	end,
	lists:map(
		fun({Name, TestFun}) ->
			test_on_fork(
				height_1_8,
				0,
				{Name, TestFun}
			)
		end,
		[
			{
				"Three transactions with block anchor",
				PrepareTestFor(fun block_anchor_txs_spending_balance_plus_one_more/0)
			},
			{
				"Five transactions with mixed anchors",
				PrepareTestFor(fun mixed_anchor_txs_spending_balance_plus_one_more/0)
			}
		]
	).

rejects_transactions_above_the_size_limit_test_() ->
	test_on_fork(height_1_8, 0, fun rejects_transactions_above_the_size_limit/0).

accepts_at_most_one_wallet_list_anchored_tx_per_block_test_() ->
	test_on_fork(height_1_8, 0, fun accepts_at_most_one_wallet_list_anchored_tx_per_block/0).

does_not_allow_to_spend_mempool_tokens_test_() ->
	test_on_fork(height_1_8, 0, fun does_not_allow_to_spend_mempool_tokens/0).

does_not_allow_to_replay_empty_wallet_txs_test_() ->
	test_on_fork(height_1_8, 0, fun does_not_allow_to_replay_empty_wallet_txs/0).

mines_blocks_under_the_size_limit_test_() ->
	PrepareTestFor = fun(BuildTXSetFun) ->
		fun() ->
			{B0, TXGroups} = BuildTXSetFun(),
			mines_blocks_under_the_size_limit(B0, TXGroups)
		end
	end,
	lists:map(
		fun({Name, TestFun}) ->
			test_on_fork(
				height_1_8,
				0,
				{Name, TestFun}
			)
		end,
		[
			{
				"Five transactions with block anchors",
				PrepareTestFor(fun() -> grouped_txs(block_anchor) end)
			},
			{
				"Five transactions with mixed anchors",
				PrepareTestFor(fun() -> grouped_txs(wallet_list_anchor) end)
			}
		]
	).

rejects_txs_with_outdated_anchors_test_() ->
	test_on_fork(height_1_8, 0, fun rejects_txs_with_outdated_anchors/0).

rejects_txs_exceeding_mempool_limit_test_() ->
	test_on_fork(height_1_8, 0, fun rejects_txs_exceeding_mempool_limit/0).

joins_network_successfully_test_() ->
	%% Fork height must be a retarget height so that we have
	%% a difficulty switch on time.
	test_on_fork(height_1_8, 10, fun() -> joins_network_successfully(10) end).

recovers_from_forks_test_() ->
	test_on_fork(height_1_8, 10, fun() -> recovers_from_forks(7, 10) end).

accepts_gossips_and_mines(B0, TXFuns) ->
	%% Post the given transactions made from the given wallets to a node.
	%%
	%% Expect them to be accepted, gossiped to the peer and included into the block.
	%% Expect the block to be accepted by the peer.
	{Master, _} = start(B0),
	{Slave, _} = slave_start(B0),
	%% Sign here after the node has started to get the correct price
	%% estimation from it.
	TXs = lists:map(fun(TXFun) -> TXFun() end, TXFuns),
	connect_to_slave(),
	%% Post the transactions to slave.
	lists:foreach(
		fun(TX) ->
			assert_post_tx_to_slave(Slave, TX),
			%% Expect transactions to be gossiped to master.
			assert_wait_until_receives_txs(Master, [TX])
		end,
		TXs
	),
	%% Mine a block.
	slave_mine(Slave),
	%% Expect both transactions to be included into block.
	SlaveBHL = assert_slave_wait_until_height(Slave, 1),
	TXIDs = lists:map(fun(TX) -> TX#tx.id end, TXs),
	?assertEqual(
		TXIDs,
		(slave_call(ar_storage, read_block, [hd(SlaveBHL), SlaveBHL]))#block.txs
	),
	lists:foreach(
		fun(TX) ->
			?assertEqual(TX, slave_call(ar_storage, read_tx, [TX#tx.id]))
		end,
		TXs
	),
	%% Expect the block to be accepted by master.
	BHL = wait_until_height(Master, 1),
	?assertEqual(
		TXIDs,
		(ar_storage:read_block(hd(BHL), BHL))#block.txs
	),
	lists:foreach(
		fun(TX) ->
			?assertEqual(TX, ar_storage:read_tx(TX#tx.id))
		end,
		TXs
	).

keeps_txs_after_new_block(B0, FirstTXSetFuns, SecondTXSetFuns) ->
	%% Post the transactions from the first set to a node but do not gossip them.
	%% Post transactiongs from the second set to both nodes.
	%% Mine a block with transactions from the second set on a different node
	%% and gossip it to the node with transactions.
	%%
	%% Expect the block to be accepted.
	%% Expect transactions from the difference between the two sets to be kept in the mempool.
	%% Mine a block on the first node, expect the difference to be included into the block.
	{Master, _} = start(B0),
	{Slave, _} = slave_start(B0),
	%% Sign here after the node has started to get the correct price
	%% estimation from it.
	FirstTXSet = lists:map(fun(TXFun) -> TXFun() end, FirstTXSetFuns),
	SecondTXSet = lists:map(fun(TXFun) -> TXFun() end, SecondTXSetFuns),
	%% Do not connect the nodes so that slave does not receive txs.
	%% Post transactions from the first set to master.
	lists:foreach(
		fun(TX) ->
			post_tx_to_master(Master, TX)
		end,
		SecondTXSet ++ FirstTXSet
	),
	?assertEqual([], slave_call(ar_node, get_all_known_txs, [Slave])),
	%% Post transactions from the second set to slave.
	lists:foreach(
		fun(TX) ->
			assert_post_tx_to_slave(Slave, TX)
		end,
		SecondTXSet
	),
	%% Connect the nodes and mine a block on slave.
	connect_to_slave(),
	slave_mine(Slave),
	%% Expect master to receive the block.
	BHL = wait_until_height(Master, 1),
	SecondSetTXIDs = lists:map(fun(TX) -> TX#tx.id end, SecondTXSet),
	?assertEqual(SecondSetTXIDs, (ar_storage:read_block(hd(BHL), BHL))#block.txs),
	%% Expect master to have the set difference in the mempool.
	assert_wait_until_receives_txs(Master, FirstTXSet -- SecondTXSet),
	%% Mine a block on master and expect both transactions to be included.
	ar_node:mine(Master),
	BHL2 = wait_until_height(Master, 2),
	SetDifferenceTXIDs = lists:map(fun(TX) -> TX#tx.id end, FirstTXSet -- SecondTXSet),
	?assertEqual(
		SetDifferenceTXIDs,
		(ar_storage:read_block(hd(BHL2), BHL2))#block.txs
	).

returns_error_when_txs_exceed_balance(B0, TXs, ExceedBalanceTX) ->
	{Master, _} = start(B0),
	{Slave, _} = slave_start(B0),
	connect_to_slave(),
	%% Post the given transactions that do not exceed the balance.
	lists:foreach(
		fun(TX) ->
			assert_post_tx_to_slave(Slave, TX)
		end,
		TXs
	),
	%% Expect the balance exceeding transactions to be included
	%% into the mempool cause it can be potentially included by
	%% other nodes.
	assert_post_tx_to_slave(Slave, ExceedBalanceTX),
	%% Expect only the first two to be included into the block.
	slave_mine(Slave),
	SlaveBHL = assert_slave_wait_until_height(Slave, 1),
	TXIDs = lists:map(fun(TX) -> TX#tx.id end, TXs),
	?assertEqual(
		TXIDs,
		(slave_call(ar_storage, read_block, [hd(SlaveBHL), SlaveBHL]))#block.txs
	),
	BHL = wait_until_height(Master, 1),
	?assertEqual(
		TXIDs,
		(ar_storage:read_block(hd(BHL), BHL))#block.txs
	),
	%% Post the balance exceeding transaction again
	%% and expect the balance exceeded error.
	slave_call(ets, delete, [ignored_ids, ExceedBalanceTX#tx.id]),
	{ok, {{<<"400">>, _}, _, <<"[\"tx_insufficient_funds\"]">>, _, _}} =
		ar_httpc:request(
			<<"POST">>,
			{127, 0, 0, 1, slave_call(ar_meta_db, get, [port])},
			"/tx",
			[],
			ar_serialize:jsonify(ar_serialize:tx_to_json_struct(ExceedBalanceTX))
		).

rejects_transactions_above_the_size_limit() ->
	%% Create a genesis block with a wallet.
	Key1 = {_, Pub1} = ar_wallet:new(),
	Key2 = {_, Pub2} = ar_wallet:new(),
	[B0] = ar_weave:init([
		{ar_wallet:to_address(Pub1), ?AR(20), <<>>},
		{ar_wallet:to_address(Pub2), ?AR(20), <<>>}
	]),
	%% Start the node.
	{Slave, _} = slave_start(B0),
	connect_to_slave(),
	SmallData = << <<1>> || _ <- lists:seq(1, ?TX_DATA_SIZE_LIMIT) >>,
	BigData = << <<1>> || _ <- lists:seq(1, ?TX_DATA_SIZE_LIMIT + 1) >>,
	GoodTX = sign_tx(Key1, #{ data => SmallData }),
	assert_post_tx_to_slave(Slave, GoodTX),
	BadTX = sign_tx(Key2, #{ data => BigData }),
	{ok, {{<<"400">>, _}, _, <<"[\"tx_data_too_large\"]">>, _, _}} = post_tx_to_slave(Slave, BadTX),
	{ok, [tx_data_too_large]} = slave_call(ar_tx_db, get_error_codes, [BadTX#tx.id]).

accepts_at_most_one_wallet_list_anchored_tx_per_block() ->
	%% Post a TX, mine a block.
	%% Post another TX referencing the first one.
	%% Post the third TX referencing the second one.
	%%
	%% Expect the third to be rejected.
	%%
	%% Post the fourth TX referencing the block.
	%%
	%% Expect the fourth TX to be accepted and mined into a block.
	Key = {_, Pub} = ar_wallet:new(),
	[B0] = ar_weave:init([
		{ar_wallet:to_address(Pub), ?AR(20), <<>>}
	]),
	{Slave, _} = slave_start(B0),
	connect_to_slave(),
	TX1 = sign_tx(Key),
	assert_post_tx_to_slave(Slave, TX1),
	slave_mine(Slave),
	assert_slave_wait_until_height(Slave, 1),
	TX2 = sign_tx(Key, #{ last_tx => TX1#tx.id }),
	assert_post_tx_to_slave(Slave, TX2),
	TX3 = sign_tx(Key, #{ last_tx => TX2#tx.id }),
	{ok, {{<<"400">>, _}, _, <<"[\"last_tx_in_mempool\"]">>, _, _}} = post_tx_to_slave(Slave, TX3),
	TX4 = sign_tx(Key, #{ last_tx => B0#block.indep_hash }),
	assert_post_tx_to_slave(Slave, TX4),
	slave_mine(Slave),
	SlaveBHL = assert_slave_wait_until_height(Slave, 2),
	B2 = slave_call(ar_storage, read_block, [hd(SlaveBHL), SlaveBHL]),
	?assertEqual([TX2#tx.id, TX4#tx.id], B2#block.txs).

does_not_allow_to_spend_mempool_tokens() ->
	%% Post a transaction sending tokens to a wallet with few tokens.
	%% Post the second transaction spending the new tokens.
	%%
	%% Expect the second transaction to be rejected.
	%%
	%% Mine a block.
	%% Post another transaction spending the rest of tokens from the new wallet.
	%%
	%% Expect the transaction to be accepted.
	Key1 = {_, Pub1} = ar_wallet:new(),
	Key2 = {_, Pub2} = ar_wallet:new(),
	[B0] = ar_weave:init([
		{ar_wallet:to_address(Pub1), ?AR(20), <<>>},
		{ar_wallet:to_address(Pub2), ?AR(0), <<>>}
	]),
	{Slave, _} = slave_start(B0),
	connect_to_slave(),
	TX1 = sign_tx(Key1, #{ target => ar_wallet:to_address(Pub2), reward => ?AR(1), quantity => ?AR(2) }),
	assert_post_tx_to_slave(Slave, TX1),
	TX2 = sign_tx(
		Key2,
		#{
			target => ar_wallet:to_address(Pub1),
			reward => ?AR(1),
			quantity => ?AR(1),
			last_tx => B0#block.indep_hash,
			tags => [{<<"nonce">>, <<"1">>}]
		}
	),
	{ok, {{<<"400">>, _}, _, <<"[\"tx_insufficient_funds\"]">>, _, _}} = post_tx_to_slave(Slave, TX2),
	slave_mine(Slave),
	SlaveBHL = assert_slave_wait_until_height(Slave, 1),
	B1 = slave_call(ar_storage, read_block, [hd(SlaveBHL), SlaveBHL]),
	?assertEqual([TX1#tx.id], B1#block.txs),
	TX3 = sign_tx(
		Key2,
		#{
			target => ar_wallet:to_address(Pub1),
			reward => ?AR(1),
			quantity => ?AR(1),
			last_tx => B1#block.indep_hash,
			tags => [{<<"nonce">>, <<"3">>}]
		}
	),
	assert_post_tx_to_slave(Slave, TX3),
	slave_mine(Slave),
	SlaveBHL2 = assert_slave_wait_until_height(Slave, 2),
	B2 = slave_call(ar_storage, read_block, [hd(SlaveBHL2), SlaveBHL2]),
	?assertEqual([TX3#tx.id], B2#block.txs).

does_not_allow_to_replay_empty_wallet_txs() ->
	%% Create a new wallet by sending some tokens to it. Mine a block.
	%% Send the tokens back so that the wallet balance is back to zero. Mine a block.
	%% Send the same amount of tokens to the same wallet again. Mine a block.
	%% Try to replay the transaction which sent the tokens back (before and after mining).
	%%
	%% Expect the replay to be rejected.
	Key1 = {_, Pub1} = ar_wallet:new(),
	Key2 = {_, Pub2} = ar_wallet:new(),
	[B0] = ar_weave:init([
		{ar_wallet:to_address(Pub1), ?AR(50), <<>>}
	]),
	{Slave, _} = slave_start(B0),
	TX1 = sign_tx(
		Key1,
		#{
			target => ar_wallet:to_address(Pub2),
			reward => ?AR(6),
			quantity => ?AR(2)
		}
	),
	assert_post_tx_to_slave(Slave, TX1),
	slave_mine(Slave),
	assert_slave_wait_until_height(Slave, 1),
	SlaveIP = {127, 0, 0, 1, slave_call(ar_meta_db, get, [port])},
	GetBalancePath = binary_to_list(ar_util:encode(ar_wallet:to_address(Pub2))),
	{ok, {{<<"200">>, _}, _, Body, _, _}} =
		ar_httpc:request(
			<<"GET">>,
			SlaveIP,
			"/wallet/" ++ GetBalancePath ++ "/balance",
			[]
		),
	Balance = binary_to_integer(Body),
	TX2 = sign_tx(
		Key2,
		#{
			target => ar_wallet:to_address(Pub1),
			reward => Balance - ?AR(1),
			quantity => ?AR(1)
		}
	),
	assert_post_tx_to_slave(Slave, TX2),
	slave_mine(Slave),
	assert_slave_wait_until_height(Slave, 2),
	{ok, {{<<"200">>, _}, _, Body2, _, _}} =
		ar_httpc:request(
			<<"GET">>,
			SlaveIP,
			"/wallet/" ++ GetBalancePath ++ "/balance",
			[]
		),
	?assertEqual(0, binary_to_integer(Body2)),
	TX3 = sign_tx(
		Key1,
		#{
			target => ar_wallet:to_address(Pub2),
			reward => ?AR(6),
			quantity => ?AR(2),
			last_tx => TX1#tx.id
		}
	),
	assert_post_tx_to_slave(Slave, TX3),
	slave_mine(Slave),
	assert_slave_wait_until_height(Slave, 3),
	%% Remove the replay TX from the ingnore list (to simulate e.g. a node restart).
	slave_call(ets, delete, [ignored_ids, TX2#tx.id]),
	{ok, {{<<"400">>, _}, _, <<"[\"tx_bad_anchor\"]">>, _, _}} =
		post_tx_to_slave(Slave, TX2).

mines_blocks_under_the_size_limit(B0, TXGroups) ->
	%% Post the given transactions grouped by block size to a node.
	%%
	%% Expect them to be mined into the corresponding number of blocks so that
	%% each block fits under the limit.
	{Master, _} = start(B0),
	{Slave, _} = slave_start(B0),
	connect_to_slave(),
	lists:foreach(
		fun(TX) ->
			assert_post_tx_to_slave(Slave, TX),
			assert_wait_until_receives_txs(Master, [TX])
		end,
		lists:flatten(TXGroups)
	),
	%% Mine blocks, expect the transactions there.
	lists:foldl(
		fun(Group, Height) ->
			slave_mine(Slave),
			SlaveBHL = assert_slave_wait_until_height(Slave, Height),
			GroupTXIDs = lists:map(fun(TX) -> TX#tx.id end, Group),
			?assertEqual(
				GroupTXIDs,
				(slave_call(ar_storage, read_block, [hd(SlaveBHL), SlaveBHL]))#block.txs
			),
			Height + 1
		end,
		1,
		TXGroups
	).

rejects_txs_with_outdated_anchors() ->
	%% Post a transaction anchoring the block at ?MAX_TX_ANCHOR_DEPTH + 1.
	%%
	%% Expect the transaction to be rejected.
	Key = {_, Pub} = ar_wallet:new(),
	[B0] = ar_weave:init([
		{ar_wallet:to_address(Pub), ?AR(20), <<>>}
	]),
	{Slave, _} = slave_start(B0),
	slave_mine_blocks(Slave, ?MAX_TX_ANCHOR_DEPTH),
	assert_slave_wait_until_height(Slave, ?MAX_TX_ANCHOR_DEPTH),
	TX1 = sign_tx(Key, #{ last_tx => B0#block.indep_hash }),
	{ok, {{<<"400">>, _}, _, <<"[\"tx_bad_anchor\"]">>, _, _}} =
		post_tx_to_slave(Slave, TX1).

rejects_txs_exceeding_mempool_limit() ->
	%% Post transactions which exceed the mempool size limit.
	%%
	%% Expect the exceeding transaction to be rejected.
	Key = {_, Pub} = ar_wallet:new(),
	[B0] = ar_weave:init([
		{ar_wallet:to_address(Pub), ?AR(20), <<>>}
	]),
	{Slave, _} = slave_start(B0),
	BigChunk = << <<1>> || _ <- lists:seq(1, ?TX_DATA_SIZE_LIMIT) >>,
	TXs = lists:map(
		fun(N) ->
			sign_tx(
				Key,
				#{
					last_tx => B0#block.indep_hash,
					data => BigChunk,
					tags => [{<<"nonce">>, integer_to_binary(N)}]
				}
			)
		end,
		lists:seq(1, 6)
	),
	lists:foreach(
		fun(TX) ->
			assert_post_tx_to_slave(Slave, TX)
		end,
		lists:sublist(TXs, 5)
	),
	{ok, {{<<"400">>, _}, _, <<"[\"mempool_is_full\"]">>, _, _}} =
		post_tx_to_slave(Slave, lists:last(TXs)).

joins_network_successfully(ForkHeight) ->
	%% Start a node and mine ?MAX_TX_ANCHOR_DEPTH blocks, some of them
	%% with transactions.
	%%
	%% Join this node by another node.
	%% Post a transaction with an outdated anchor to the new node.
	%% Expect it to be rejected.
	%%
	%% Try to replay the transactions from the weave on the new node.
	%% Expect them to be rejected.
	%%
	%% Isolate the nodes. Mine 1 block with a transaction anchoring the
	%% oldest block possible on slave. Mine a block on master so that it stops
	%% tracking the block just referenced by slave. Reconnect the nodes, mine another
	%% two blocks with transactions anchoring the oldest block possible on slave.
	%% Expect master to fork recover successfully.
	Key = {_, Pub} = ar_wallet:new(),
	[B0] = ar_weave:init([
		{ar_wallet:to_address(Pub), ?AR(20), <<>>}
	]),
	{Slave, _} = slave_start(B0),
	slave_call(ar_meta_db, put, [requests_per_minute_limit, 10000]),
	{PreForkTXs, _} = lists:foldl(
		fun(Height, {TXs, LastTX}) ->
			TX = sign_tx(Key, #{ last_tx => LastTX }),
			assert_post_tx_to_slave(Slave, TX),
			slave_mine(Slave),
			assert_slave_wait_until_height(Slave, Height),
			{TXs ++ [TX], TX#tx.id}
		end,
		{[], <<>>},
		lists:seq(1, ForkHeight)
	),
	PostForkTXs = lists:foldl(
		fun(Height, TXs) ->
			BH = get_tx_anchor(),
			NewTXs = lists:map(
				fun(_) ->
					TX = sign_tx(
						Key,
						#{
							last_tx => BH,
							tags => [{<<"nonce">>, integer_to_binary(rand:uniform(100))}]
						}
					),
					assert_post_tx_to_slave(Slave, TX),
					TX
				end,
				lists:seq(1, rand:uniform(5))
			),
			slave_mine(Slave),
			assert_slave_wait_until_height(Slave, Height),
			TXs ++ NewTXs
		end,
		[],
		lists:seq(ForkHeight + 1, ?MAX_TX_ANCHOR_DEPTH)
	),
	Master = join({127, 0, 0, 1, slave_call(ar_meta_db, get, [port])}),
	BHL = slave_call(ar_node, get_hash_list, [Slave]),
	assert_wait_until_block_hash_list(Master, BHL),
	TX1 = sign_tx(Key, #{ last_tx => lists:nth(?MAX_TX_ANCHOR_DEPTH + 1, BHL) }),
	{ok, {{<<"400">>, _}, _, <<"[\"tx_bad_anchor\"]">>, _, _}} =
		post_tx_to_master(Master, TX1),
	TX2 = sign_tx(Key, #{ last_tx => lists:nth(?MAX_TX_ANCHOR_DEPTH, BHL) }),
	assert_post_tx_to_master(Master, TX2),
	%% Remove transactions from the ignore list.
	forget_txs(PreForkTXs ++ PostForkTXs),
	lists:foreach(
		fun(TX) ->
			{ok, {{<<"400">>, _}, _, <<"[\"tx_bad_anchor\"]">>, _, _}} =
				post_tx_to_master(Master, TX)
		end,
		PreForkTXs
	),
	lists:foreach(
		fun(TX) ->
			{ok, {{<<"400">>, _}, _, <<"[\"tx_already_in_weave\"]">>, _, _}} =
				post_tx_to_master(Master, TX)
		end,
		PostForkTXs
	),
	disconnect_from_slave(),
	TX3 = sign_tx(Key, #{ last_tx => lists:nth(?MAX_TX_ANCHOR_DEPTH, BHL) }),
	assert_post_tx_to_slave(Slave, TX3),
	slave_mine(Slave),
	BHL2 = assert_slave_wait_until_height(Slave, ?MAX_TX_ANCHOR_DEPTH + 1),
	ar_node:mine(Master),
	connect_to_slave(),
	TX4 = sign_tx(Key, #{ last_tx => lists:nth(?MAX_TX_ANCHOR_DEPTH, BHL2) }),
	assert_post_tx_to_slave(Slave, TX4),
	slave_mine(Slave),
	BHL3 = assert_slave_wait_until_height(Slave, ?MAX_TX_ANCHOR_DEPTH + 2),
	TX5 = sign_tx(Key, #{ last_tx => lists:nth(?MAX_TX_ANCHOR_DEPTH, BHL3) }),
	assert_post_tx_to_slave(Slave, TX5),
	slave_mine(Slave),
	BHL4 = wait_until_height(Master, ?MAX_TX_ANCHOR_DEPTH + 3),
	?assertEqual([TX5#tx.id], (ar_storage:read_block(hd(BHL4), BHL4))#block.txs),
	?assertEqual([TX4#tx.id], (ar_storage:read_block(hd(BHL3), BHL3))#block.txs),
	?assertEqual([TX3#tx.id], (ar_storage:read_block(hd(BHL2), BHL2))#block.txs).

recovers_from_forks(ForkHeight, ForkHeight_1_8) ->
	%% Mine a number of blocks with transactions on slave and master in sync,
	%% then mine another bunch independently. Place the 1.8 fork in the middle
	%% of the extra bulk.
	%%
	%% Mine an extra block on slave to make master fork recover to it.
	%% Expect the fork recovery to be successful.
	%%
	%% Try to replay all the past transactions on master. Expect the transactions to be rejected.
	%%
	%% Resubmit all the transactions from the orphaned fork. Expect them to be accepted
	%% and successfully mined into a block.
	Key = {_, Pub} = ar_wallet:new(),
	[B0] = ar_weave:init([
		{ar_wallet:to_address(Pub), ?AR(20), <<>>}
	]),
	{Slave, _} = slave_start(B0),
	{Master, _} = start(B0),
	connect_to_slave(),
	{PreForkTXs, _} = lists:foldl(
		fun(Height, {TXs, LastTX}) ->
			TX = sign_tx(Key, #{ last_tx => LastTX }),
			assert_post_tx_to_slave(Slave, TX),
			slave_mine(Slave),
			BHL = assert_slave_wait_until_height(Slave, Height),
			BHL = wait_until_height(Master, Height),
			slave_assert_block_txs([TX], BHL),
			assert_block_txs([TX], BHL),
			{TXs ++ [TX], TX#tx.id}
		end,
		{[], <<>>},
		lists:seq(1, ForkHeight)
	),
	disconnect_from_slave(),
	{SlavePostForkTXs, SlavePostForkBlockAnchoredTXs} = lists:foldl(
		fun(Height, {TXs, BlockAnchoredTXs}) ->
			LastTX = get_last_tx(Key),
			TX = sign_tx(Key, #{ last_tx => LastTX }),
			BlockAnchoredTX = case Height of
				H when H > ForkHeight_1_8 ->
					BTX = sign_tx(
						Key,
						#{ last_tx => get_tx_anchor(), tags => [{<<"nonce">>, random_nonce()}] }
					),
					assert_post_tx_to_slave(Slave, BTX),
					[BTX];
				_ ->
					[]
			end,
			assert_post_tx_to_slave(Slave, TX),
			slave_mine(Slave),
			BHL = assert_slave_wait_until_height(Slave, Height),
			slave_assert_block_txs([TX] ++ BlockAnchoredTX, BHL),
			{TXs ++ [TX], BlockAnchoredTXs ++ BlockAnchoredTX}
		end,
		{[], []},
		lists:seq(ForkHeight + 1, ForkHeight_1_8 + 2)
	),
	IncludeOnMasterTX = ar_util:pick_random(SlavePostForkBlockAnchoredTXs),
	forget_txs([IncludeOnMasterTX]),
	?assertEqual(ForkHeight, length(ar_node:get_blocks(Master)) - 1),
	?assertEqual([], ar_node:get_all_known_txs(Master)),
	{MasterPostForkTXs, MasterPostForkBlockAnchoredTXs} = lists:foldl(
		fun(Height, {TXs, BlockAnchoredTXs}) ->
			%% Post one wallet list anchored tx per block. After fork 1.8
			%% post 1 block anchored tx per block. At fork block, post
			%% one of the transactions included by slave on the different fork.
			LastTX = get_last_tx(master, Key),
			TX = sign_tx(master, Key, #{ last_tx => LastTX }),
			assert_post_tx_to_master(Master, TX),
			AdditionalTXs = case Height of
				H when H == ForkHeight_1_8 + 1 ->
					assert_post_tx_to_master(Master, IncludeOnMasterTX),
					[IncludeOnMasterTX];
				H when H > ForkHeight_1_8 ->
					BlockAnchoredTX = sign_tx(
						master,
						Key,
						#{ last_tx => get_tx_anchor(master), tags => [{<<"nonce">>, random_nonce()}] }
					),
					assert_post_tx_to_master(Master, BlockAnchoredTX),
					[BlockAnchoredTX];
				_ ->
					[]
			end,
			ar_node:mine(Master),
			BHL = wait_until_height(Master, Height),
			assert_block_txs([TX] ++ AdditionalTXs, BHL),
			{TXs ++ [TX], BlockAnchoredTXs ++ AdditionalTXs}
		end,
		{[], []},
		lists:seq(ForkHeight + 1, ForkHeight_1_8 + 1)
	),
	connect_to_slave(),
	TX2 = sign_tx(Key, #{ last_tx => get_tx_anchor(), tags => [{<<"nonce">>, random_nonce()}] }),
	assert_post_tx_to_slave(Slave, TX2),
	assert_wait_until_receives_txs(Master, [TX2]),
	slave_mine(Slave),
	assert_slave_wait_until_height(Slave, ForkHeight_1_8 + 3),
	wait_until_height(Master, ForkHeight_1_8 + 3),
	forget_txs(
		PreForkTXs ++
		MasterPostForkTXs ++
		MasterPostForkBlockAnchoredTXs ++
		SlavePostForkTXs ++
		SlavePostForkBlockAnchoredTXs ++
		[TX2]
	),
	%% Assert pre-fork transactions, the transactions which came during
	%% fork recovery, and the freshly created transaction are in the
	%% weave.
	lists:foreach(
		fun(TX) ->
			Confirmations = get_tx_confirmations(master, TX#tx.id),
			?assert(Confirmations > 0),
			{ok, {{<<"400">>, _}, _, _, _, _}} =
				post_tx_to_master(Master, TX)
		end,
		PreForkTXs ++ SlavePostForkTXs ++ SlavePostForkBlockAnchoredTXs ++ [TX2]
	),
	%% Assert the transactions included in the abandoned fork are removed.
	lists:foreach(
		fun(TX) ->
			Confirmations = get_tx_confirmations(master, TX#tx.id),
			?assertEqual(-1, Confirmations)
		end,
		MasterPostForkTXs ++ MasterPostForkBlockAnchoredTXs -- [IncludeOnMasterTX]
	),
	%% Assert the block anchored transactions from the abandoned fork can
	%% be reposted.
	lists:foreach(
		fun(TX) ->
			assert_post_tx_to_master(Master, TX)
		end,
		MasterPostForkBlockAnchoredTXs -- [IncludeOnMasterTX]
	),
	ar_node:mine(Master),
	wait_until_height(Master, ForkHeight_1_8 + 4),
	forget_txs(MasterPostForkBlockAnchoredTXs),
	lists:foreach(
		fun(TX) ->
			Confirmations = get_tx_confirmations(master, TX#tx.id),
			?assertEqual(1, Confirmations),
			{ok, {{<<"400">>, _}, _, <<"[\"tx_already_in_weave\"]">>, _, _}} =
				post_tx_to_master(Master, TX)
		end,
		MasterPostForkBlockAnchoredTXs -- [IncludeOnMasterTX]
	).

one_wallet_list_one_block_anchored_txs(Key, B0) ->
	%% Sign only after the node has started to get the correct price
	%% estimation from it.
	TX1Fun = fun() -> sign_tx(Key) end,
	TX2Fun = fun() -> sign_tx(Key, #{ last_tx => B0#block.indep_hash }) end,
	[TX1Fun, TX2Fun].

two_block_anchored_txs(Key, B0) ->
	%% Sign only after the node has started to get the correct price
	%% estimation from it.
	TX1Fun = fun() -> sign_tx(Key, #{ last_tx => B0#block.indep_hash }) end,
	TX2Fun = fun() -> sign_tx(Key, #{ last_tx => B0#block.indep_hash }) end,
	[TX1Fun, TX2Fun].

empty_tx_set(_Key, _B0) ->
	[].

block_anchor_txs_spending_balance_plus_one_more() ->
	Key = {_, Pub} = ar_wallet:new(),
	[B0] = ar_weave:init([{ar_wallet:to_address(Pub), ?AR(20), <<>>}]),
	TX1 = sign_tx(Key, #{ quantity => ?AR(4), reward => ?AR(6), last_tx => B0#block.indep_hash }),
	TX2 = sign_tx(Key, #{ reward => ?AR(10), last_tx => B0#block.indep_hash }),
	ExceedBalanceTX = sign_tx(Key, #{ reward => ?AR(1), last_tx => B0#block.indep_hash }),
	{B0, [TX1, TX2], ExceedBalanceTX}.

mixed_anchor_txs_spending_balance_plus_one_more() ->
	Key = {_, Pub} = ar_wallet:new(),
	[B0] = ar_weave:init([{ar_wallet:to_address(Pub), ?AR(20), <<>>}]),
	TX1 = sign_tx(Key, #{ quantity => ?AR(4), reward => ?AR(6) }),
	TX2 = sign_tx(Key, #{ reward => ?AR(5), last_tx => B0#block.indep_hash }),
	TX3 = sign_tx(Key, #{ reward => ?AR(2), last_tx => B0#block.indep_hash }),
	TX4 = sign_tx(Key, #{ reward => ?AR(3), last_tx => B0#block.indep_hash }),
	ExceedBalanceTX = sign_tx(Key, #{ reward => ?AR(1), last_tx => B0#block.indep_hash }),
	{B0, [TX1, TX2, TX3, TX4], ExceedBalanceTX}.

grouped_txs(FirstAnchorType) ->
	Key1 = {_, Pub1} = ar_wallet:new(),
	Key2 = {_, Pub2} = ar_wallet:new(),
	Wallets = [
		{ar_wallet:to_address(Pub1), ?AR(100), <<>>},
		{ar_wallet:to_address(Pub2), ?AR(100), <<>>}
	],
	[B0] = ar_weave:init(Wallets),
	%% Expect transactions to be chosen from biggest to smallest.
	Chunk1 = << <<1>> || _ <- lists:seq(1, ?TX_DATA_SIZE_LIMIT) >>,
	Chunk2 = << <<1>> || _ <- lists:seq(1, (?TX_DATA_SIZE_LIMIT) - 1) >>,
	Chunk3 = <<1>>,
	Chunk4 = << <<1>> || _ <- lists:seq(1, (?TX_DATA_SIZE_LIMIT) - 5) >>,
	Chunk5 = << <<1>> || _ <- lists:seq(1, 5) >>,
	%% Block 1: 1 TX.
	FirstAnchor = case FirstAnchorType of
		wallet_list_anchor ->
			<<>>;
		block_anchor ->
			B0#block.indep_hash
	end,
	Wallet1TX1 = sign_tx(Key1, #{ data => Chunk1, last_tx => FirstAnchor }),
	%% Block 2: 2 TXs from different wallets.
	Wallet2TX1 = sign_tx(Key2, #{ data => Chunk2, last_tx => B0#block.indep_hash }),
	Wallet1TX2 = sign_tx(Key1, #{ data => Chunk3, last_tx => B0#block.indep_hash }),
	%% Block 3: 2 TXs from the same wallet.
	Wallet1TX3 = sign_tx(Key1, #{ data => Chunk4, last_tx => B0#block.indep_hash }),
	Wallet1TX4 = sign_tx(Key1, #{ data => Chunk5, last_tx => B0#block.indep_hash }),
	{B0, [[Wallet1TX1], [Wallet2TX1, Wallet1TX2], [Wallet1TX3, Wallet1TX4]]}.

slave_mine_blocks(Slave, TargetHeight) ->
	slave_mine_blocks(Slave, 1, TargetHeight).

slave_mine_blocks(_Slave, Height, TargetHeight) when Height == TargetHeight + 1 ->
	ok;
slave_mine_blocks(Slave, Height, TargetHeight) ->
	slave_mine(Slave),
	assert_slave_wait_until_height(Slave, Height),
	slave_mine_blocks(Slave, Height + 1, TargetHeight).

forget_txs(TXs) ->
	lists:foreach(
		fun(TX) ->
			ets:delete(ignored_ids, TX#tx.id)
		end,
		TXs
	).

slave_assert_block_txs(TXs, BHL) ->
	TXIDs = lists:map(fun(TX) -> TX#tx.id end, TXs),
	B = slave_call(ar_storage, read_block, [hd(BHL), BHL]),
	?assertEqual(lists:sort(TXIDs), lists:sort(B#block.txs)).

assert_block_txs(TXs, BHL) ->
	TXIDs = lists:map(fun(TX) -> TX#tx.id end, TXs),
	B = ar_storage:read_block(hd(BHL), BHL),
	?assertEqual(lists:sort(TXIDs), lists:sort(B#block.txs)).

random_nonce() ->
	integer_to_binary(rand:uniform(1000000)).
