%% ---------------------------------------------------------------------
%%
%% Copyright (c) 2007-2013 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% ---------------------------------------------------------------------

%% @doc MapReduce functions for storage calculation

-module(riak_cs_storage_mr).

-include("riak_cs.hrl").

-export([bucket_summary_map/3,
         bucket_summary_reduce/2]).
-export([object_size_map/3,
         object_size_reduce/2]).

-export([bytes_and_blocks/1]).

%% Record for summary information, each 3-tuple represents object
%% count, total bytes and total blocks.  Some of them are estimated
%% value, maybe (over|under)-estimated.
%% @see bytes_and_blocks/1 for details of calculation/estimation
-record(sum,
        {
          %% User accessible objects, which includes active and
          %% writing of multipart.
          user = {0, 0, 0},
          %% `active's but "deleted", i.e. other than user accessible
          ac_de = {0, 0, 0},
          %% MP writing (double count with `user')
          wr_mp = {0, 0, 0},
          %% non-MP writing, divided by <> leeway
          wr_new = {0, 0, 0},
          wr_old = {0, 0, 0},
          %% pending_delete, divided by <> leeway
          pd_new = {0, 0, 0},
          pd_old = {0, 0, 0},
          %% scheduled_delete, divided by <> leeway
          sd_new = {0, 0, 0},
          sd_old = {0, 0, 0}
        }).

-type sum() :: #sum{}.
-type div_point() :: erlang:timestamp().

-ifdef(TEST).
-compile(export_all).
-include_lib("eunit/include/eunit.hrl").
-endif.

bucket_summary_map({error, notfound}, _, _Args) ->
    [];
bucket_summary_map(Object, _, Args) ->
    DivPoint = proplists:get_value(div_point, Args),
    Summary = riak_cs_utils:maybe_process_resolved(
                Object, fun(History) -> sum_objs(DivPoint, History) end, #sum{}),
    Res = summary_to_list(Summary),
    [Res].

object_size_map({error, notfound}, _, _) ->
    [];
object_size_map(Object, _, _) ->
    Handler = fun(Resolved) -> object_size(Resolved) end,
    riak_cs_utils:maybe_process_resolved(Object, Handler, []).

object_size_reduce(Sizes, _) ->
    {Objects,Bytes} = lists:unzip(Sizes),
    [{lists:sum(Objects),lists:sum(Bytes)}].

%% Internal

-spec sum_objs(div_point(), [cs_uuid_and_manifest()]) -> sum().
sum_objs(DivPoint, History) ->
    case riak_cs_manifest_utils:active_manifest(History) of
        {ok, Active} ->
            {_, _, CBB} = bytes_and_blocks(Active),
            Sum = add_to(#sum{}, #sum.user, CBB),
            NonActiveHistory = lists:keydelete(Active?MANIFEST.uuid, 1, History),
            sum_objs(DivPoint, Sum, NonActiveHistory);
        _ ->
            sum_objs(DivPoint, #sum{}, History)
    end.

sum_objs(_DivPoint, Sum, []) ->
    Sum;
sum_objs(DivPoint, Sum, [{_UUID, M} | Rest]) ->
    NewSum = case bytes_and_blocks(M) of
                 {_, active, CBB} ->
                     %% Because user accessible active manifest had
                     %% been removed `sum_objs/2', active's here are
                     %% invisible for users.
                     add_to(Sum, #sum.ac_de, CBB);
                 {mp, writing, CBB} ->
                     %% MP writing is visible for user. Also add
                     %% to MP writing counters. Only this kind of
                     %% manifests are doubly counted.
                     Sum1 = add_to(Sum, #sum.user, CBB),
                     add_to(Sum1, #sum.wr_mp, CBB);
                 {non_mp, writing, CBB} ->
                     case new_or_old(DivPoint, M?MANIFEST.write_start_time) of
                         new ->
                             add_to(Sum, #sum.wr_new, CBB);
                         old ->
                             add_to(Sum, #sum.wr_old, CBB)
                     end;
                 {_, pending_delete, CBB} ->
                     case new_or_old(DivPoint, M?MANIFEST.delete_marked_time) of
                         new ->
                             add_to(Sum, #sum.pd_new, CBB);
                         old ->
                             add_to(Sum, #sum.pd_old, CBB)
                     end;
                 {_, scheduled_delete, CBB} ->
                     case new_or_old(DivPoint, M?MANIFEST.delete_marked_time) of
                         new ->
                             add_to(Sum, #sum.sd_new, CBB);
                         old ->
                             add_to(Sum, #sum.sd_old, CBB)
                     end
             end,
    sum_objs(DivPoint, NewSum, Rest).

-spec bytes_and_blocks(lfs_manifest()) ->
                              {non_mp | mp, State::atom(),
                               {Count::non_neg_integer(),
                                Bytes::non_neg_integer(),
                                Blocks::non_neg_integer()}}.
bytes_and_blocks(?MANIFEST{props=Props} = M) when is_list(Props) ->
    case proplists:get_value(multipart, Props) of
        ?MULTIPART_MANIFEST{} = MpM -> bytes_and_blocks_mp(M, MpM);
        _ -> bytes_and_blocks_non_mp(M)
    end;
bytes_and_blocks(M) ->
    bytes_and_blocks_non_mp(M).

bytes_and_blocks_non_mp(?MANIFEST{state=State, content_length=CL, block_size=BS})
  when is_integer(CL) andalso is_integer(BS) ->
    BlockCount = riak_cs_lfs_utils:block_count(CL, BS),
    {non_mp, State, {1, CL, BlockCount}};
bytes_and_blocks_non_mp(?MANIFEST{state=State} = _M) ->
    lager:debug("Strange manifest: ~p~n", [_M]),
    %% The branch above is for content_length is properly set.  This
    %% is true for non-MP v2 auth case but not always true for v4 of
    %% streaming sha256 check of writing. To avoid error, ignore
    %% this objects. Can this be guessed better from write_blocks_remaining?
    {non_mp, State, {1, 0, 0}}.

%% There are possibility of understimatation and overestimation for
%% Multipart cases.
%%
%% In writing state, there are two active fields in Multipart
%% manifests, `parts' and `done_parts'. To count bytes and blocks,
%% `parts' is used here, these counts may be overestimate because
%% `parts' includes unfinished blocks. We could use `done_parts'
%% instead, then counts may be underestimate because it does not
%% include unfinished ones.
%%
%% Once MP turned into active state, unused parts had already been
%% gone to GC bucket. These UUIDs are remaining in cleanup_parts, but
%% we can't know whether correspoinding blocks have beed GC'ed or not,
%% because dummy manifests for `cleanup_parts' have beed inserted to
%% GC bucket directly and no object in manifest buckets.  We don't
%% count cleanup_parts here.
bytes_and_blocks_mp(?MANIFEST{state=State, content_length=CL},
                    ?MULTIPART_MANIFEST{}=MpM)
  when State =:= active andalso is_integer(CL) ->
    {mp, State, {part_count(MpM), CL, blocks_mp_parts(MpM)}};
bytes_and_blocks_mp(?MANIFEST{state=State},
                    ?MULTIPART_MANIFEST{}=MpM) ->
    {mp, State, {part_count(MpM), bytes_mp_parts(MpM), blocks_mp_parts(MpM)}};
bytes_and_blocks_mp(?MANIFEST{state=State}, _MpM) ->
    %% Strange data. Don't break storage calc
    {mp, State, {1, 0, 0}}.

part_count(?MULTIPART_MANIFEST{parts=PartMs}) ->
    length(PartMs).

bytes_mp_parts(?MULTIPART_MANIFEST{parts=PartMs}) ->
    lists:sum([P?PART_MANIFEST.content_length || P <- PartMs]).

blocks_mp_parts(?MULTIPART_MANIFEST{parts=PartMs}) ->
    lists:sum([riak_cs_lfs_utils:block_count(
                 P?PART_MANIFEST.content_length,
                 P?PART_MANIFEST.block_size) || P <- PartMs]).

% @doc Returns `new' if Timestamp is 3-tuple and greater than `DivPoint',
% otherwise `old'.
-spec new_or_old(div_point(), erlang:timestamp()) -> new | old.
new_or_old(DivPoint, {_,_,_} = Timestamp) when DivPoint < Timestamp -> new;
new_or_old(_, _) -> old.

-spec add_to(sum(), pos_integer(),
             {non_neg_integer(), non_neg_integer(), non_neg_integer()}) -> sum().
add_to(Sum, Pos, {Count, Bytes, Blocks}) ->
    {C0, By0, Bl0} = element(Pos, Sum),
    setelement(Pos, Sum, {C0 + Count, By0 + Bytes, Bl0 + Blocks}).

%% @doc Convert `sum()' record to list.
-spec summary_to_list(sum()) -> [{term(), non_neg_integer()}].
summary_to_list(Sum) ->
    [_RecName | Triples] = tuple_to_list(Sum),
    summary_to_list(record_info(fields, sum), Triples, []).

summary_to_list([], _, Acc) ->
    Acc;
summary_to_list([F|Fields], [{C, By, Bl}|Triples], Acc) ->
    summary_to_list(Fields, Triples,
                    [{{F, ct}, C}, {{F, by}, By}, {{F, bl}, Bl} | Acc]).

object_size(Resolved) ->
    {MPparts, MPbytes} = count_multipart_parts(Resolved),
    case riak_cs_manifest_utils:active_manifest(Resolved) of
        {ok, ?MANIFEST{content_length=Length}} ->
            [{1 + MPparts, Length + MPbytes}];
        _ ->
            [{MPparts, MPbytes}]
    end.

-spec count_multipart_parts([{cs_uuid(), lfs_manifest()}]) ->
                                   {non_neg_integer(), non_neg_integer()}.
count_multipart_parts(Resolved) ->
    lists:foldl(fun count_multipart_parts/2, {0, 0}, Resolved).

-spec count_multipart_parts({cs_uuid(), lfs_manifest()},
                            {non_neg_integer(), non_neg_integer()}) ->
                                   {non_neg_integer(), non_neg_integer()}.
count_multipart_parts({_UUID, ?MANIFEST{props=Props, state=writing} = M},
                      {MPparts, MPbytes} = Acc)
  when is_list(Props) ->
    case proplists:get_value(multipart, Props) of
        ?MULTIPART_MANIFEST{parts=Ps} = _  ->
            {MPparts + length(Ps),
             MPbytes + lists:sum([P?PART_MANIFEST.content_length ||
                                     P <- Ps])};
        undefined ->
            %% Maybe not a multipart
            Acc;
        Other ->
            %% strange thing happened
            _ = lager:log(warning, self(),
                          "strange writing multipart manifest detected at ~p: ~p",
                          [M?MANIFEST.bkey, Other]),
            Acc
    end;
count_multipart_parts(_, Acc) ->
    %% Other state than writing, won't be counted
    %% active manifests will be counted later
    Acc.

bucket_summary_reduce(Sums, _) ->
    InitialCounters = orddict:new(),
    [bucket_summary_fold(Sums, InitialCounters)].

bucket_summary_fold([], Counters) ->
    Counters;
bucket_summary_fold([Sum | Sums], Counters) ->
    NewCounters = lists:foldl(
                    fun({K, Num}, Cs) -> orddict:update_counter(K, Num, Cs) end,
                    Counters, Sum),
    bucket_summary_fold(Sums, NewCounters).

-ifdef(TEST).

object_size_map_test_() ->
    M0 = ?MANIFEST{state=active, content_length=25},
    M1 = ?MANIFEST{state=active, content_length=35},
    M2 = ?MANIFEST{state=writing, props=undefined, content_length=42},
    M3 = ?MANIFEST{state=writing, props=pocketburger, content_length=234},
    M4 = ?MANIFEST{state=writing, props=[{multipart,undefined}],
                   content_length=23434},
    M5 = ?MANIFEST{state=writing, props=[{multipart,pocketburger}],
                   content_length=23434},

    [?_assertEqual([{1,25}], object_size([{uuid,M0}])),
     ?_assertEqual([{1,35}], object_size([{uuid2,M2},{uuid1,M1}])),
     ?_assertEqual([{1,35}], object_size([{uuid2,M3},{uuid1,M1}])),
     ?_assertEqual([{1,35}], object_size([{uuid2,M4},{uuid1,M1}])),
     ?_assertEqual([{1,35}], object_size([{uuid2,M5},{uuid1,M1}]))].

count_multipart_parts_test_() ->
    ZeroZero = {0, 0},
    ValidMPManifest = ?MULTIPART_MANIFEST{parts=[?PART_MANIFEST{content_length=10}]},
    [?_assertEqual(ZeroZero,
                   count_multipart_parts({<<"pocketburgers">>,
                                          ?MANIFEST{props=pocketburgers, state=writing}},
                                         ZeroZero)),
     ?_assertEqual(ZeroZero,
                   count_multipart_parts({<<"pocketburgers">>,
                                          ?MANIFEST{props=pocketburgers, state=iamyourfather}},
                                         ZeroZero)),
     ?_assertEqual(ZeroZero,
                   count_multipart_parts({<<"pocketburgers">>,
                                          ?MANIFEST{props=[], state=writing}},
                                         ZeroZero)),
     ?_assertEqual(ZeroZero,
                   count_multipart_parts({<<"pocketburgers">>,
                                          ?MANIFEST{props=[{multipart, pocketburger}], state=writing}},
                                         ZeroZero)),
     ?_assertEqual({1, 10},
                   count_multipart_parts({<<"pocketburgers">>,
                                          ?MANIFEST{props=[{multipart, ValidMPManifest}], state=writing}},
                                         ZeroZero))
    ].

-endif.
