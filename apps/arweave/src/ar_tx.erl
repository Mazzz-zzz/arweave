-module(ar_tx).
-export([new/0, new/1, new/2, new/3, new/4]).
-export([sign/2, sign/3, verify/5, verify_txs/5, signature_data_segment/1]).
-export([tx_to_binary/1, tags_to_list/1]).
-export([calculate_min_tx_cost/4, calculate_min_tx_cost/6, check_last_tx/2]).
-include("ar.hrl").
-include_lib("eunit/include/eunit.hrl").

%%% Transaction creation, signing and verification for Arweave.

%% @doc Generate a new transaction for entry onto a weave.
new() ->
	#tx { id = generate_id() }.
new(Data) ->
	#tx { id = generate_id(), data = Data }.
new(Data, Reward) ->
	#tx { id = generate_id(), data = Data, reward = Reward }.
new(Data, Reward, Last) ->
	#tx { id = generate_id(), last_tx = Last, data = Data, reward = Reward }.
new(Dest, Reward, Qty, Last) when bit_size(Dest) == ?HASH_SZ ->
	#tx {
		id = generate_id(),
		last_tx = Last,
		quantity = Qty,
		target = Dest,
		data = <<>>,
		reward = Reward
	};
new(Dest, Reward, Qty, Last) ->
	% Convert wallets to addresses before building transactions.
	new(ar_wallet:to_address(Dest), Reward, Qty, Last).

%% @doc A testing function used for giving transactions an ID being placed on the weave.
%% This function is for testing only. A tx with this ID will not pass verification.
%% A valid tx id in the Arweave network is a SHA256 hash of the signature.
generate_id() -> crypto:strong_rand_bytes(32).

%% @doc Generate a hashable binary from a #tx object.
%% NB: This function cannot be used for signature data as the id and signature fields are not set.
tx_to_binary(T) ->
	<<
		(T#tx.id)/binary,
		(T#tx.last_tx)/binary,
		(T#tx.owner)/binary,
		(tags_to_binary(T#tx.tags))/binary,
		(T#tx.target)/binary,
		(list_to_binary(integer_to_list(T#tx.quantity)))/binary,
		(T#tx.data)/binary,
		(T#tx.signature)/binary,
		(list_to_binary(integer_to_list(T#tx.reward)))/binary
	>>.

%% @doc Generate the data segment to be signed for a given TX.
signature_data_segment(T) ->
	<<
		(T#tx.owner)/binary,
		(T#tx.target)/binary,
		(T#tx.data)/binary,
		(list_to_binary(integer_to_list(T#tx.quantity)))/binary,
		(list_to_binary(integer_to_list(T#tx.reward)))/binary,
		(T#tx.last_tx)/binary,
		(tags_to_binary(T#tx.tags))/binary
	>>.

%% @doc Cryptographicvally sign ('claim ownership') of a transaction.
%% After it is signed, it can be placed into a block and verified at a later date.
sign(TX, {PrivKey, PubKey}) -> sign(TX, PrivKey, PubKey).
sign(TX, PrivKey, PubKey) ->
	NewTX = TX#tx{ owner = PubKey },
	Sig = ar_wallet:sign(PrivKey, signature_data_segment(NewTX)),
	ID = crypto:hash(?HASH_ALG, <<Sig/binary>>),
	NewTX#tx {
		signature = Sig, id = ID
	}.

%% @doc Verify whether a transaction is valid to be regossiped and mined on.
%% NB: The signature verification is the last step due to the potential of an attacker
%% submitting an arbitrary length signature field and having it processed.
-ifdef(DEBUG).
verify(#tx { signature = <<>> }, _, _, _, _) -> true;
verify(TX, Diff, Height, Wallets, Timestamp) ->
	do_verify(TX, Diff, Height, Wallets, Timestamp).
-else.
verify(TX, Diff, Height, Wallets, Timestamp) ->
	do_verify(TX, Diff, Height, Wallets, Timestamp).
-endif.

do_verify(TX, Diff, Height, Wallets, Timestamp) ->
	Fork_1_8 = ar_fork:height_1_8(),
	LastTXCheck = case Height of
		H when H >= Fork_1_8 ->
			true;
		_ ->
			check_last_tx(Wallets, TX)
	end,
	Checks = [
		{"quantity_negative",
		 TX#tx.quantity >= 0},
		{"same_owner_as_target",
		 (ar_wallet:to_address(TX#tx.owner) =/= TX#tx.target)},
		{"tx_too_cheap",
		 tx_cost_above_min(TX, Diff, Height, Wallets, TX#tx.target, Timestamp)},
		{"tx_fields_too_large",
		 tx_field_size_limit(TX, Height)},
		{"tag_field_illegally_specified",
		 tag_field_legal(TX)},
		{"last_tx_not_valid",
		 LastTXCheck},
		{"tx_id_not_valid",
		 tx_verify_hash(TX)},
		{"overspend",
		 validate_overspend(TX, ar_node_utils:apply_tx(Wallets, TX, Height))},
		{"tx_signature_not_valid",
		 ar_wallet:verify(TX#tx.owner, signature_data_segment(TX), TX#tx.signature)}
	],
	KeepFailed = fun
		({_, true}) ->
			false;
		({ErrorCode, false}) ->
			{true, ErrorCode}
	end,
	case lists:filtermap(KeepFailed, Checks) of
		[] ->
			true;
		ErrorCodes ->
			ar_tx_db:put_error_codes(TX#tx.id, ErrorCodes),
			false
	end.

validate_overspend(TX, Wallets) ->
	From = ar_wallet:to_address(TX#tx.owner),
	To = TX#tx.target,
	lists:all(
		fun(Addr) ->
			case ar_node_utils:get_wallet_by_address(Addr, Wallets) of
				{_, 0, Last} when byte_size(Last) == 0 ->
					false;
				{_, Quantity, _} when Quantity < 0 ->
					false;
				_ ->
					true
			end
		end,
		[From, To]
	).

%% @doc Verify a list of transactions.
%% Returns false if any TX in the set fails verification.
verify_txs(TXs, Diff, Height, WalletList, Timestamp) ->
	WalletMap = ar_node_utils:wallet_map_from_wallet_list(WalletList),
	case ar_fork:height_1_8() of
		H when Height >= H ->
			case verify_txs_size(TXs) of
				true ->
					verify_txs(valid_size_txs, TXs, Diff, Height, WalletMap, Timestamp);
				false ->
					false
			end;
		_ ->
			verify_txs(valid_size_txs, TXs, Diff, Height, WalletMap, Timestamp)
	end.

verify_txs_size(TXs) ->
	case length(TXs) of
		L when L > ?BLOCK_TX_COUNT_LIMIT ->
			false;
		_ ->
			TotalTXSize = lists:foldl(
				fun(TX, CurrentTotalTXSize) ->
					CurrentTotalTXSize + byte_size(TX#tx.data)
				end,
				0,
				TXs
			),
			TotalTXSize =< ?BLOCK_TX_DATA_SIZE_LIMIT
	end.

verify_txs(valid_size_txs, [], _, _, _, _) ->
	true;
verify_txs(valid_size_txs, [TX | TXs], Diff, Height, WalletMap, Timestamp) ->
	case verify(TX, Diff, Height, WalletMap, Timestamp) of
		true ->
			verify_txs(
				valid_size_txs,
				TXs,
				Diff,
				Height,
				ar_node_utils:apply_tx(WalletMap, TX, Height),
				Timestamp
			);
		false ->
			false
	end.

%% @doc Ensure that transaction cost above proscribed minimum.
tx_cost_above_min(TX, Diff, Height, Wallets, Addr, Timestamp) ->
	TX#tx.reward >=
		calculate_min_tx_cost(byte_size(TX#tx.data), Diff, Height + 1, Wallets, Addr, Timestamp).

%% @doc Calculate the minimum transaction cost for a TX with the given data size.
%% Cost per byte is static unless size is bigger than 10mb, at which
%% point cost per byte starts increasing.
calculate_min_tx_cost(DataSize, Diff, Height, Timestamp) ->
	case ar_fork:height_1_8() of
		H when Height >= H ->
			ar_tx_perpetual_storage:calculate_tx_fee(DataSize, Diff, Height, Timestamp);
		_ ->
			DiffCenter = case ar_fork:height_1_7() of
				ForkHeight when Height >= ForkHeight ->
					?DIFF_CENTER + ?RANDOMX_DIFF_ADJUSTMENT;
				_ ->
					?DIFF_CENTER
			end,
			min_tx_cost(DataSize, Diff, DiffCenter)
	end.

calculate_min_tx_cost(DataSize, Diff, Height, _, undefined, Timestamp) ->
	calculate_min_tx_cost(DataSize, Diff, Height, Timestamp);
calculate_min_tx_cost(DataSize, Diff, Height, _, <<>>, Timestamp) ->
	calculate_min_tx_cost(DataSize, Diff, Height, Timestamp);
calculate_min_tx_cost(DataSize, Diff, Height, Wallets, Addr, Timestamp) ->
	case ar_node_utils:get_wallet_by_address(Addr, Wallets) of
		false ->
			calculate_min_tx_cost(DataSize, Diff, Height, Timestamp) + ?WALLET_GEN_FEE;
		{_, _, _} ->
			calculate_min_tx_cost(DataSize, Diff, Height, Timestamp)
	end.

min_tx_cost(DataSize, Diff, DiffCenter) when Diff >= DiffCenter ->
	Size = ?TX_SIZE_BASE + DataSize,
	CurveSteepness = 2,
	BaseCost = CurveSteepness*(Size*?COST_PER_BYTE) / (Diff - (DiffCenter - CurveSteepness)),
	erlang:trunc(BaseCost * math:pow(1.2, Size/(1024*1024)));
min_tx_cost(DataSize, _Diff, DiffCenter) ->
	min_tx_cost(DataSize, DiffCenter, DiffCenter).

%% @doc Check whether each field in a transaction is within the given byte size limits.
tx_field_size_limit(TX, Height) ->
	Fork_1_8 = ar_fork:height_1_8(),
	LastTXLimit = case Height of
		H when H >= Fork_1_8 ->
			48;
		_ ->
			32
	end,
	case tag_field_legal(TX) of
		true ->
			(byte_size(TX#tx.id) =< 32) and
			(byte_size(TX#tx.last_tx) =< LastTXLimit) and
			(byte_size(TX#tx.owner) =< 512) and
			(byte_size(tags_to_binary(TX#tx.tags)) =< 2048) and
			(byte_size(TX#tx.target) =< 32) and
			(byte_size(integer_to_binary(TX#tx.quantity)) =< 21) and
			(byte_size(TX#tx.data) =< (?TX_DATA_SIZE_LIMIT)) and
			(byte_size(TX#tx.signature) =< 512) and
			(byte_size(integer_to_binary(TX#tx.reward)) =< 21);
		false -> false
	end.

%% @doc Verify that the transactions ID is a hash of its signature.
tx_verify_hash(#tx {signature = Sig, id = ID}) ->
	ID == crypto:hash(?HASH_ALG, <<Sig/binary>>).

%% @doc Check that the structure of the txs tag field is in the expected
%% key value format.
tag_field_legal(TX) ->
	lists:all(
		fun(X) ->
			case X of
				{_, _} -> true;
				_ -> false
			end
		end,
		TX#tx.tags
	).

%% @doc Convert a transactions key-value tags to binary a format.
tags_to_binary(Tags) ->
	list_to_binary(
		lists:foldr(
			fun({Name, Value}, Acc) ->
				[Name, Value | Acc]
			end,
			[],
			Tags
		)
	).

tags_to_list(Tags) ->
	[[Name, Value] || {Name, Value} <- Tags].

%% @doc A check if the transactions last_tx field and owner match the expected
%% value found in the wallet list wallet list, if so returns true else false.
-ifdef(DEBUG).
check_last_tx([], _) -> true;
check_last_tx(_WalletList, TX) when TX#tx.owner == <<>> -> true;
check_last_tx(WalletList, TX) when is_list(WalletList) ->
	Address = ar_wallet:to_address(TX#tx.owner),
	case lists:keyfind(Address, 1, WalletList) of
		{Address, _Quantity, Last} ->
			Last == TX#tx.last_tx;
		_ -> false
	end;
check_last_tx(WalletMap, TX) when is_map(WalletMap) ->
	case maps:size(WalletMap) of
		0 ->
			true;
		_ ->
			Addr = ar_wallet:to_address(TX#tx.owner),
			case maps:get(Addr, WalletMap, not_found) of
				not_found ->
					false;
				{_, _, LastTX} ->
					LastTX == TX#tx.last_tx
			end
	end.
-else.
check_last_tx([], _) -> true;
check_last_tx(WalletList, TX) when is_list(WalletList) ->
	Address = ar_wallet:to_address(TX#tx.owner),
	case lists:keyfind(Address, 1, WalletList) of
		{Address, _Quantity, Last} -> Last == TX#tx.last_tx;
		_ -> false
	end;
check_last_tx(WalletMap, TX) when is_map(WalletMap) ->
	Addr = ar_wallet:to_address(TX#tx.owner),
	case maps:get(Addr, WalletMap, not_found) of
		not_found ->
			false;
		{_, _, LastTX} ->
			LastTX == TX#tx.last_tx
	end.
-endif.

%%% Tests: ar_tx

%% @doc Ensure that a public and private key pair can be used to sign and verify data.
sign_tx_test() ->
	NewTX = new(<<"TEST DATA">>, ?AR(10)),
	{Priv, Pub} = ar_wallet:new(),
	Diff = 1,
	Height = 0,
	Timestamp = os:system_time(seconds),
	?assert(verify(sign(NewTX, Priv, Pub), Diff, Height, [], Timestamp)).

%% @doc Ensure that a forged transaction does not pass verification.
forge_test() ->
	NewTX = new(<<"TEST DATA">>, ?AR(10)),
	{Priv, Pub} = ar_wallet:new(),
	Diff = 1,
	Height = 0,
	InvalidSignTX = (sign(NewTX, Priv, Pub))#tx { data = <<"FAKE DATA">> },
	Timestamp = os:system_time(seconds),
	?assert(not verify(InvalidSignTX, Diff, Height, [], Timestamp)).

%% @doc Ensure that transactions above the minimum tx cost are accepted.
tx_cost_above_min_test() ->
	ValidTX = new(<<"TEST DATA">>, ?AR(10)),
	InvalidTX = new(<<"TEST DATA">>, 1),
	Diff = 10,
	Height = 123,
	Timestamp = os:system_time(seconds),
	?assert(tx_cost_above_min(ValidTX, 1, Height, [], <<"non-existing-addr">>, Timestamp)),
	?assert(not tx_cost_above_min(InvalidTX, Diff, Height, [], <<"non-existing-addr">>, Timestamp)).

%% @doc Ensure that the check_last_tx function only validates transactions in which
%% last tx field matches that expected within the wallet list.
check_last_tx_test_() ->
	{timeout, 60, fun() ->
		ar_storage:clear(),
		{_Priv1, Pub1} = ar_wallet:new(),
		{Priv2, Pub2} = ar_wallet:new(),
		{Priv3, Pub3} = ar_wallet:new(),
		TX = ar_tx:new(Pub2, ?AR(1), ?AR(500), <<>>),
		TX2 = ar_tx:new(Pub3, ?AR(1), ?AR(400), TX#tx.id),
		TX3 = ar_tx:new(Pub1, ?AR(1), ?AR(300), TX#tx.id),
		SignedTX2 = sign(TX2, Priv2, Pub2),
		SignedTX3 = sign(TX3, Priv3, Pub3),
		WalletList =
			[
				{ar_wallet:to_address(Pub1), 1000, <<>>},
				{ar_wallet:to_address(Pub2), 2000, TX#tx.id},
				{ar_wallet:to_address(Pub3), 3000, <<>>}
			],
		false = check_last_tx(WalletList, SignedTX3),
		true = check_last_tx(WalletList, SignedTX2)
	end}.

tx_cost_test() ->
	{_, Pub1} = ar_wallet:new(),
	{_, Pub2} = ar_wallet:new(),
	Addr1 = ar_wallet:to_address(Pub1),
	Addr2 = ar_wallet:to_address(Pub2),
	WalletList = [{Addr1, 1000, <<>>}],
	Size = 1000,
	Diff = 20,
	Height = 123,
	Timestamp = os:system_time(seconds),
	?assertEqual(
		calculate_min_tx_cost(Size, Diff, Height, Timestamp),
		calculate_min_tx_cost(Size, Diff, Height, WalletList, Addr1, Timestamp)
	),
	?assertEqual(
		calculate_min_tx_cost(Size, Diff, Height, Timestamp) + ?WALLET_GEN_FEE,
		calculate_min_tx_cost(Size, Diff, Height, WalletList, Addr2, Timestamp)
	).
