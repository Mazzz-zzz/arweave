-module(av_detect).
-export([is_infected/2]).
-include("av_recs.hrl").

%%% Perform the illicit content detection.
%%% Given it's task, we should optimise this as much as possible.

%% Given a binary and a set of signatures, test whether the binary
%% contains illicit content. If not, return false, if it is, return true and
%% the matching signatures. The list of matching signatures is empty if an issue
%% is discovered by a quick check.
is_infected(Binary, {Sigs, BinaryPattern, HashPattern}) ->
	Hash = av_utils:md5sum(Binary),
	case {quick_check(Binary, BinaryPattern), quick_check(Hash, HashPattern)} of
		{false, false} ->
			full_check(Binary, byte_size(Binary), Hash, Sigs);
		_ ->
			{true, []}
	end.

%% Perform a quick check. This only tells us whether there is probably an
%% infection, not what that infection is, if there is one. Has a very low
%% false-positive rate.
quick_check(_, no_pattern) -> false;
quick_check(Data, Pattern) ->
	binary:match(Data, Pattern) =/= nomatch.

%% Perform a full, slow check. This returns false, or true with a list of matched signatures.
full_check(Bin, Sz, Hash, Sigs) ->
	Res =
		lists:filtermap(
			fun(Sig) -> check_sig(Bin, Sz, Hash, Sig) end,
			Sigs
		),
	case Res of
		[] -> false;
		MatchedSigs -> {true, [ S#sig.name || S <- MatchedSigs ]}
	end.

%% Perform the actual check.
check_sig(Bin, _Sz, _Hash, S = #sig { type = binary, data = D }) ->
	case binary:match(Bin, D#binary_sig.binary) of
		nomatch -> false;
		{FoundOffset, _} ->
			% The file is infected. If the offset was set, check it.
			case D#binary_sig.offset of
				any -> {true, S};
				FoundOffset -> {true, S};
				_ -> false
			end
	end;
check_sig(_Bin, Sz, Hash,
		S = #sig { type = hash, data = D = #hash_sig { hash = SigHash } }) ->
	%% Check the binary size first, as this is very low cost.
	case D#hash_sig.size of
		Sz -> check_hash(Hash, SigHash, S);
		any -> check_hash(Hash, SigHash, S);
		_ -> false
	end.

%% Perform a hash check, returning filtermap format results.
check_hash(Hash, SigHash, S) ->
	if SigHash == Hash -> {true, S};
	true -> false
	end.
