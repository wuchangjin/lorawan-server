%
% Copyright (c) 2016-2017 Petr Gotthard <petr.gotthard@centrum.cz>
% All rights reserved.
% Distributed under the terms of the MIT License. See the LICENSE file.
%
-module(lorawan_db).

-export([ensure_tables/0, ensure_table/2, trim_tables/0]).
-export([get_rxframes/1, purge_txframes/1]).

-include_lib("lorawan_server_api/include/lorawan_application.hrl").
-include("lorawan.hrl").

ensure_tables() ->
    case mnesia:system_info(use_dir) of
        true ->
            ok;
        false ->
            stopped = mnesia:stop(),
            lager:info("Database create schema"),
            mnesia:create_schema([node()]),
            ok = mnesia:start()
    end,
    lists:foreach(fun({Name, TabDef}) -> ensure_table(Name, TabDef) end, [
        {users, [
            {record_name, user},
            {attributes, record_info(fields, user)},
            {disc_copies, [node()]}]},
        {gateways, [
            {record_name, gateway},
            {attributes, record_info(fields, gateway)},
            {disc_copies, [node()]}]},
        {multicast_groups, [
            {record_name, multicast_group},
            {attributes, record_info(fields, multicast_group)},
            {disc_copies, [node()]}]},
        {devices, [
            {record_name, device},
            {attributes, record_info(fields, device)},
            {index, [link]},
            {disc_copies, [node()]}]},
        {links, [
            {record_name, link},
            {attributes, record_info(fields, link)},
            {disc_copies, [node()]}]},
        {ignored_links, [
            {record_name, ignored_link},
            {attributes, record_info(fields, ignored_link)},
            {disc_copies, [node()]}]},
        {pending, [
            {record_name, pending},
            {attributes, record_info(fields, pending)},
            {disc_copies, [node()]}]},
        {txframes, [
            {type, ordered_set},
            {record_name, txframe},
            {attributes, record_info(fields, txframe)},
            {disc_copies, [node()]}]},
        {rxframes, [
            {record_name, rxframe},
            {attributes, record_info(fields, rxframe)},
            {index, [mac, devaddr]},
            {disc_copies, [node()]}]},
        {connectors, [
            {record_name, connector},
            {attributes, record_info(fields, connector)},
            {disc_copies, [node()]}]},
        {handlers, [
            {record_name, handler},
            {attributes, record_info(fields, handler)},
            {disc_copies, [node()]}]}
    ]).

ensure_table(Name, TabDef) ->
    case lists:member(Name, mnesia:system_info(tables)) of
        true ->
            mnesia:wait_for_tables([Name], 2000),
            ensure_indexes(Name, TabDef);
        false ->
            lager:info("Database create ~w", [Name]),
            mnesia:create_table(Name, TabDef),
            mnesia:wait_for_tables([Name], 2000),
            set_defaults(Name)
    end.

ensure_indexes(Name, TabDef) ->
    OldAttrs = mnesia:table_info(Name, attributes),
    OldIndexes = lists:sort(mnesia:table_info(Name, index)),
    NewAttrs = proplists:get_value(attributes, TabDef),
    NewIndexes =
        lists:sort(
            lists:map(fun(Key) ->
                index_of(Key, NewAttrs)+1
            end, proplists:get_value(index, TabDef, []))),
    if
        OldIndexes == NewIndexes ->
            ensure_fields(Name, TabDef);
        true ->
            lager:info("Database index update ~w: ~w to ~w", [Name, OldIndexes, NewIndexes]),
            [mnesia:del_table_index(Name, lists:nth(Idx-1, OldAttrs))
                || Idx <- lists:subtract(OldIndexes, NewIndexes), Idx =< length(OldAttrs)+1],
            ensure_fields(Name, TabDef),
            [mnesia:add_table_index(Name, lists:nth(Idx-1, NewAttrs))
                || Idx <- lists:subtract(NewIndexes, OldIndexes), Idx =< length(NewAttrs)+1]
    end.

ensure_fields(Name, TabDef) ->
    OldAttrs = mnesia:table_info(Name, attributes),
    NewAttrs = proplists:get_value(attributes, TabDef),
    if
        OldAttrs == NewAttrs ->
            ok;
        true ->
            lager:info("Database fields update ~w: ~w to ~w", [Name, OldAttrs, NewAttrs]),
            {atomic, ok} = mnesia:transform_table(Name,
                fun(OldRec) ->
                    [Rec|Values] = tuple_to_list(OldRec),
                    PropList = lists:zip(OldAttrs, Values),
                    list_to_tuple([Rec|[proplists:get_value(X, PropList) || X <- NewAttrs]])
                end,
                NewAttrs)
    end.

set_defaults(users) ->
    lager:info("Database create default user:password"),
    {ok, {User, Pass}} = application:get_env(lorawan_server, http_admin_credentials),
    mnesia:dirty_write(users, #user{name=User, pass=Pass});
set_defaults(_Else) ->
    ok.

trim_tables() ->
    lists:foreach(fun(R) -> trim_rxframes(R) end,
        mnesia:dirty_all_keys(links)).

get_rxframes(DevAddr) ->
    {_, Frames} = get_last_rxframes(DevAddr, 50),
    % return frames received since the last device restart
    case mnesia:dirty_read(links, DevAddr) of
        [#link{last_reset=Reset}] when is_tuple(Reset) ->
            lists:filter(
                fun(Frame) -> occured_rxframe_after(Reset, Frame) end,
                Frames);
        _Else ->
            Frames
    end.

get_last_rxframes(DevAddr, Count) ->
    Rec = mnesia:dirty_index_read(rxframes, DevAddr, #rxframe.devaddr),
    SRec = lists:sort(fun(#rxframe{frid = A}, #rxframe{frid = B}) -> A < B end, Rec),
    % split the list into expired and actual records
    if
        length(SRec) > Count -> lists:split(length(SRec)-Count, SRec);
        true -> {[], SRec}
    end.

occured_rxframe_after(StartDate, #rxframe{datetime = FrameDate}) ->
    StartDate =< FrameDate.

trim_rxframes(DevAddr) ->
    case get_last_rxframes(DevAddr, 50) of
        {[], _} ->
            ok;
        {ExpRec, _} ->
            lager:debug("Expired ~w rxframes from ~w", [length(ExpRec), DevAddr]),
            lists:foreach(fun(R) -> mnesia:dirty_delete_object(rxframes, R) end,
                ExpRec)
    end.

purge_txframes(DevAddr) ->
    [mnesia:dirty_delete_object(txframes, Obj) ||
        Obj <- mnesia:dirty_match_object(txframes, #txframe{devaddr=DevAddr, _='_'})].

index_of(Item, List) -> index_of(Item, List, 1).

index_of(_, [], _)  -> not_found;
index_of(Item, [Item|_], Index) -> Index;
index_of(Item, [_|Tl], Index) -> index_of(Item, Tl, Index+1).

% end of file
