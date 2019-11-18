-module(ar_storage).

-export([start/0]).
-export([write_file_atomic/2]).
-export([write_block/1, write_full_block/1, write_full_block/2, read_block/2, clear/0]).
-export([write_encrypted_block/2, read_encrypted_block/1, invalidate_block/1]).
-export([blocks_on_disk/0]).
-export([write_tx/1, read_tx/1]).
-export([write_wallet_list/1, read_wallet_list/1]).
-export([write_block_hash_list/2, read_block_hash_list/1]).
-export([enough_space/1, select_drive/2]).
-export([calculate_disk_space/0, calculate_used_space/0, start_update_used_space/0]).
-export([lookup_block_filename/1, lookup_tx_filename/1]).
-export([read_tx_file/1]).
-export([ensure_directories/0]).

-include("ar.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

%%% Reads and writes blocks from disk.


-define(DIRECTORY_SIZE_TIMER, 300000).

%% @doc Ready the system for block/tx reading and writing.
%% %% This function should block.
start() ->
	ar_firewall:start(),
	ensure_directories(),
	count_blocks_on_disk(),
	case ar_meta_db:get(disk_space) of
		undefined ->
			%% Add some margin for filesystem overhead.
			DiskSpaceWithMargin = round(calculate_disk_space() * 0.98),
			ar_meta_db:put(disk_space, DiskSpaceWithMargin),
			ok;
		_ ->
			ok
	end.

%% @doc Ensure that all of the relevant storage directories exist.
ensure_directories() ->
	DataDir = ar_meta_db:get(data_dir),
	%% Append "/" to every path so that filelib:ensure_dir/1 creates a directory if it does not exist.
	filelib:ensure_dir(filename:join(DataDir, ?TX_DIR) ++ "/"),
	filelib:ensure_dir(filename:join(DataDir, ?BLOCK_DIR) ++ "/"),
	filelib:ensure_dir(filename:join(DataDir, ?ENCRYPTED_BLOCK_DIR) ++ "/"),
	filelib:ensure_dir(filename:join(DataDir, ?WALLET_LIST_DIR) ++ "/"),
	filelib:ensure_dir(filename:join(DataDir, ?HASH_LIST_DIR) ++ "/").

count_blocks_on_disk() ->
	spawn(
		fun() ->
			DataDir = ar_meta_db:get(data_dir),
			case file:list_dir(filename:join(DataDir, ?BLOCK_DIR)) of
				{ok, List} ->
					ar_meta_db:increase(blocks_on_disk, length(List));
				{error, Reason} ->
					ar:warn([
						{event, failed_to_count_blocks_on_disk},
						{reason, Reason}
					])
			end
		end
	).

write_file_atomic(Filename, Data) ->
	SwapFilename = Filename ++ ".swp",
	case file:write_file(SwapFilename, Data) of
		ok ->
			file:rename(SwapFilename, Filename);
		Error ->
			Error
	end.

lookup_block_filename(Hash) ->
	Filepath = block_filepath(Hash),
	case filelib:is_file(Filepath) of
		true ->
			Filepath;
		false ->
			unavailable
	end.

%% @doc Remove blocks from disk. Used in tests.
clear() ->
	clear_internal().

-ifdef(DEBUG).
clear_internal() ->
	lists:map(
		fun file:delete/1,
		filelib:wildcard(
			filename:join([ar_meta_db:get(data_dir), ?BLOCK_DIR, "*.json"])
		)
	),
	ar_meta_db:put(blocks_on_disk, 0).
-else.
clear_internal() ->
	noop.
-endif.

%% @doc Returns the number of blocks stored on disk.
blocks_on_disk() ->
	ar_meta_db:get(blocks_on_disk).

%% @doc Move a block into the 'invalid' block directory.
invalidate_block(B) ->
	ar_meta_db:increase(blocks_on_disk, -1),
	TargetFile = invalid_block_filepath(B),
	filelib:ensure_dir(TargetFile),
	file:rename(block_filepath(B), TargetFile).

write_block(Bs) when is_list(Bs) -> lists:foreach(fun write_block/1, Bs);
write_block(RawB) ->
	case ar_meta_db:get(disk_logging) of
		true ->
			ar:report([{writing_block_to_disk, ar_util:encode(RawB#block.indep_hash)}]);
		_ ->
			do_nothing
	end,
	WalletID = write_wallet_list(RawB#block.wallet_list),
	B = RawB#block { wallet_list = WalletID },
	BlockToWrite = ar_serialize:jsonify(ar_serialize:block_to_json_struct(B)),
	case enough_space(byte_size(BlockToWrite)) of
		true ->
			write_file_atomic(Name = block_filepath(B), BlockToWrite),
			ar_meta_db:increase(blocks_on_disk, 1),
			ar_meta_db:increase(used_space, byte_size(BlockToWrite)),
			Name;
		false ->
			ar:err(
				[
					{not_enough_space_to_write_block},
					{block_not_written}
				]
			),
			{error, not_enough_space}
	end.

write_full_block(B) ->
	BShadow = B#block { txs = [T#tx.id || T <- B#block.txs] },
	write_full_block(BShadow, B#block.txs).

write_full_block(BShadow, TXs) ->
	%% We only store data that passes the firewall configured by the miner.
	ScannedTXs = lists:filter(
		fun(TX) ->
			case ar_firewall:scan_tx(TX) of
				accept ->
					true;
				reject ->
					false
			end
		end,
		TXs
	),
	write_tx(ScannedTXs),
	write_block(BShadow),
	ar_sqlite3:insert_full_block(BShadow#block{ txs = ScannedTXs }),
	app_ipfs:maybe_ipfs_add_txs(ScannedTXs).

write_encrypted_block(Hash, B) ->
	BlockToWrite = B,
	case enough_space(byte_size(BlockToWrite)) of
		true ->
			write_file_atomic(Name = encrypted_block_filepath(Hash), BlockToWrite),
			ar_meta_db:increase(used_space, byte_size(BlockToWrite)),
			Name;
		false ->
			ar:report(
				[
					{not_enough_space_to_write_block},
					{block_not_written}
				]
			),
			{error, enospc}
	end.

%% @doc Read the block from disk, given a hash or a height.
read_block(unavailable, _HL) ->
	unavailable;
read_block(B, _HL) when is_record(B, block) ->
	B;
read_block(Blocks, HL) when is_list(Blocks) ->
	lists:map(fun(B) -> read_block(B, HL) end, Blocks);
read_block(Height, HL) when is_integer(Height) ->
	case Height of
		_ when Height < 0 ->
			unavailable;
		_ when Height > length(HL) - 1 ->
			unavailable;
		_ ->
			BH = lists:nth(length(HL) - Height, HL),
			read_block(BH, HL)
	end;
read_block(Hash, HL) when is_binary(Hash) ->
	case lookup_block_filename(Hash) of
		unavailable ->
			unavailable;
		Filename ->
			read_block_file(Filename, HL)
	end.

read_block_file(Filename, HL) ->
	{ok, Binary} = file:read_file(Filename),
	B = ar_serialize:json_struct_to_block(Binary),
	WL = B#block.wallet_list,
	FinalB =
		B#block {
			hash_list = ar_block:generate_hash_list_for_block(B, HL),
			wallet_list =
				case WL of
					WL when is_list(WL) ->
						WL;
					WL when is_binary(WL) ->
						case read_wallet_list(WL) of
							{ok, ReadWL} ->
								ReadWL;
							{error, Type} ->
								ar:report(
									[
										{
											error_reading_wallet_list_from_disk,
											ar_util:encode(B#block.indep_hash)
										},
										{type, Type}
									]
								),
								not_found
						end
				end
		},
	case FinalB#block.wallet_list of
		not_found ->
			invalidate_block(B),
			unavailable;
		_ -> FinalB
	end.

%% @doc Read an encrypted block from disk, given a hash.
read_encrypted_block(unavailable) -> unavailable;
read_encrypted_block(ID) ->
	case file:read_file(encrypted_block_filepath(ID)) of
		{ok, Binary} ->
			Binary;
		{error, _} ->
			unavailable
	end.

%% @doc Recalculate the used space in bytes of the data directory disk.
start_update_used_space() ->
	spawn(
		fun() ->
			UsedSpace = ar_meta_db:get(used_space),
			catch ar_meta_db:put(used_space, max(calculate_used_space(), UsedSpace)),
			timer:apply_after(
				?DIRECTORY_SIZE_TIMER,
				?MODULE,
				start_update_used_space,
				[]
			)
		end
	).

write_tx(TXs) when is_list(TXs) -> lists:foreach(fun write_tx/1, TXs);
write_tx(TX) ->
	TXToWrite = ar_serialize:jsonify(ar_serialize:tx_to_json_struct(TX)),
	case enough_space(byte_size(TXToWrite)) of
		true ->
			write_file_atomic(
				Name = tx_filepath(TX),
				ar_serialize:jsonify(ar_serialize:tx_to_json_struct(TX))
			),
			ar_meta_db:increase(used_space, byte_size(TXToWrite)),
			Name;
		false ->
			ar:report(
				[
					{not_enough_space_to_write_tx},
					{tx_not_written}
				]
			),
			{error, enospc}
	end.

%% @doc Read a tx from disk, given a hash.
read_tx(unavailable) -> unavailable;
read_tx(Tx) when is_record(Tx, tx) -> Tx;
read_tx(Txs) when is_list(Txs) ->
	lists:map(fun read_tx/1, Txs);
read_tx(ID) ->
	case lookup_tx_filename(ID) of
		unavailable -> unavailable;
		Filename -> read_tx_file(Filename)
	end.

read_tx_file(Filename) ->
	{ok, Binary} = file:read_file(Filename),
	ar_serialize:json_struct_to_tx(Binary).

%% Write a block hash list to disk for retreival later (in emergencies).
write_block_hash_list(Hash, BHL) ->
	ar:report([{writing_block_hash_list_to_disk, ID = ar_util:encode(Hash)}]),
	JSON = ar_serialize:jsonify(ar_serialize:hash_list_to_json_struct(BHL)),
	write_file_atomic(hash_list_filepath(Hash), JSON),
	ID.

%% Write a block hash list to disk for retreival later (in emergencies).
write_wallet_list(WalletList) ->
	ID = ar_block:hash_wallet_list(WalletList),
	JSON = ar_serialize:jsonify(ar_serialize:wallet_list_to_json_struct(WalletList)),
	write_file_atomic(wallet_list_filepath(ID), JSON),
	ID.

%% @doc Read a list of block hashes from the disk.
read_block_hash_list(Hash) ->
	{ok, Binary} = file:read_file(hash_list_filepath(Hash)),
	ar_serialize:json_struct_to_hash_list(ar_serialize:dejsonify(Binary)).

%% @doc Read a given wallet list (by hash) from the disk.
read_wallet_list(WalletListHash) ->
	Filename = wallet_list_filepath(WalletListHash),
	case file:read_file(Filename) of
		{ok, JSON} ->
			parse_wallet_list_json(JSON);
		{error, Reason} ->
			{error, {failed_reading_file, Filename, Reason}}
	end.

parse_wallet_list_json(JSON) ->
	case ar_serialize:json_decode(JSON) of
		{ok, JiffyStruct} ->
			{ok, ar_serialize:json_struct_to_wallet_list(JiffyStruct)};
		{error, Reason} ->
			{error, {invalid_json, Reason}}
	end.

lookup_tx_filename(ID) ->
	Filepath = tx_filepath(ID),
	case filelib:is_file(Filepath) of
		false -> unavailable;
		true -> Filepath
	end.

% @doc Check that there is enough space to write Bytes bytes of data
enough_space(Bytes) ->
	(ar_meta_db:get(disk_space)) >= (Bytes + ar_meta_db:get(used_space)).

%% @doc Calculate the available space in bytes on the data directory disk.
calculate_disk_space() ->
	{_, KByteSize, _} = get_data_dir_disk_data(),
	KByteSize * 1024.

%% @doc Calculate the used space in bytes on the data directory disk.
calculate_used_space() ->
	{_, KByteSize, UsedPercentage} = get_data_dir_disk_data(),
	math:ceil(KByteSize * UsedPercentage / 100 * 1024).

get_data_dir_disk_data() ->
	application:ensure_started(sasl),
	application:ensure_started(os_mon),
	DataDir = filename:absname(ar_meta_db:get(data_dir)),
	[DiskData | _] = select_drive(disksup:get_disk_data(), DataDir),
	DiskData.

%% @doc Calculate the root drive in which the Arweave server resides
select_drive(Disks, []) ->
	CWD = "/",
	case
		Drives = lists:filter(
			fun({Name, _, _}) ->
				case Name == CWD of
					false -> false;
					true -> true
				end
			end,
			Disks
		)
	of
		[] -> false;
		Drives ->
			Drives
	end;
select_drive(Disks, CWD) ->
	try
		case
			Drives = lists:filter(
				fun({Name, _, _}) ->
					try
						case string:find(Name, CWD) of
							nomatch -> false;
							_ -> true
						end
					catch _:_ -> false
					end
				end,
				Disks
			)
		of
			[] -> select_drive(Disks, hd(string:split(CWD, "/", trailing)));
			Drives -> Drives
		end
	catch _:_ -> select_drive(Disks, [])
	end.

filepath(PathComponents) ->
	to_string(filename:join([ar_meta_db:get(data_dir) | PathComponents])).

to_string(Bin) when is_binary(Bin) ->
	binary_to_list(Bin);
to_string(String) ->
	String.

block_filename(B) when is_record(B, block) ->
	block_filename(B#block.indep_hash);
block_filename(Hash) when is_binary(Hash) ->
	binary_to_list(ar_util:encode(Hash)) ++ ".json".

block_filepath(B) ->
	filepath([?BLOCK_DIR, block_filename(B)]).

invalid_block_filepath(B) ->
	filepath([?BLOCK_DIR, "invalid", block_filename(B)]).

encrypted_block_filepath(Hash) when is_binary(Hash) ->
	filepath([?ENCRYPTED_BLOCK_DIR, iolist_to_binary(["encrypted_", ar_util:encode(Hash), ".json"])]).

tx_filepath(TX) ->
	filepath([?TX_DIR, tx_filename(TX)]).

tx_filename(TX) when is_record(TX, tx) ->
	iolist_to_binary([ar_util:encode(TX#tx.id), ".json"]);
tx_filename(TXID) when is_binary(TXID) ->
	iolist_to_binary([ar_util:encode(TXID), ".json"]).

hash_list_filepath(Hash) when is_binary(Hash) ->
	filepath([?HASH_LIST_DIR, iolist_to_binary([ar_util:encode(Hash), ".json"])]).

wallet_list_filepath(Hash) when is_binary(Hash) ->
	filepath([?WALLET_LIST_DIR, iolist_to_binary([ar_util:encode(Hash), ".json"])]).

%% @doc Test block storage.
store_and_retrieve_block_test() ->
	ar_storage:clear(),
	?assertEqual(0, blocks_on_disk()),
	B0s = [B0] = ar_weave:init([]),
	ar_storage:write_block(B0),
	B0 = read_block(B0#block.indep_hash, B0#block.hash_list),
	B1s = [B1|_] = ar_weave:add(B0s, []),
	ar_storage:write_block(B1),
	[B2|_] = ar_weave:add(B1s, []),
	ar_storage:write_block(B2),
	write_block(B1),
	?assertEqual(3, blocks_on_disk()),
	B1 = read_block(B1#block.indep_hash, B2#block.hash_list),
	B1 = read_block(B1#block.height, B2#block.hash_list).

clear_blocks_test() ->
	ar_storage:clear(),
	?assertEqual(0, blocks_on_disk()).

store_and_retrieve_tx_test() ->
	Tx0 = ar_tx:new(<<"DATA1">>),
	write_tx(Tx0),
	Tx0 = read_tx(Tx0),
	Tx0 = read_tx(Tx0#tx.id),
	file:delete(tx_filepath(Tx0)).

%% @doc Ensure blocks can be written to disk, then moved into the 'invalid'
%% block directory.
invalidate_block_test() ->
	[B] = ar_weave:init(),
	write_full_block(B),
	invalidate_block(B),
	timer:sleep(500),
	unavailable = read_block(B#block.indep_hash, B#block.hash_list),
	TargetFile = filename:join([
		ar_meta_db:get(data_dir),
		?BLOCK_DIR,
		"invalid",
		binary_to_list(ar_util:encode(B#block.indep_hash)) ++ ".json"
	]),
	?assertEqual(B, read_block_file(TargetFile, B#block.hash_list)).

store_and_retrieve_block_hash_list_test() ->
	ID = crypto:strong_rand_bytes(32),
	B0s = ar_weave:init([]),
	write_block(hd(B0s)),
	B1s = ar_weave:add(B0s, []),
	write_block(hd(B1s)),
	[B2|_] = ar_weave:add(B1s, []),
	write_block_hash_list(ID, B2#block.hash_list),
	receive after 500 -> ok end,
	BHL = read_block_hash_list(ID),
	BHL = B2#block.hash_list.

store_and_retrieve_wallet_list_test() ->
	[B0] = ar_weave:init(),
	write_wallet_list(WL = B0#block.wallet_list),
	receive after 500 -> ok end,
	?assertEqual({ok, WL}, read_wallet_list(ar_block:hash_wallet_list(WL))).

handle_corrupted_wallet_list_test() ->
	ar_storage:clear(),
	[B0] = ar_weave:init([]),
	ar_storage:write_block(B0),
	?assertEqual(B0, read_block(B0#block.indep_hash, B0#block.hash_list)),
	WalletListHash = ar_block:hash_wallet_list(B0#block.wallet_list),
	ok = write_file_atomic(wallet_list_filepath(WalletListHash), <<>>),
	?assertEqual(unavailable, read_block(B0#block.indep_hash, B0#block.hash_list)).
