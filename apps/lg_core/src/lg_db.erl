%% @doc mnesia 访问辅助。
-module(lg_db).

-export([transaction/1, read/2, all/1, index_read/3, write/1, delete/2]).

%% @doc 执行事务，统一返回 {ok, Result} | {error, Reason}。
%% 事务体内 mnesia:abort(Reason) 会得到 {error, Reason}。
-spec transaction(fun(() -> term())) -> {ok, term()} | {error, term()}.
transaction(Fun) ->
    case mnesia:transaction(Fun) of
        {atomic, R} -> {ok, R};
        {aborted, Reason} -> {error, Reason}
    end.

-spec read(atom(), term()) -> {ok, tuple()} | not_found.
read(Tab, Key) ->
    case mnesia:dirty_read(Tab, Key) of
        [Rec] -> {ok, Rec};
        [] -> not_found
    end.

%% disc_copies 表在本节点有完整副本，dirty_select 即本地 ets 遍历
-spec all(atom()) -> [tuple()].
all(Tab) ->
    mnesia:dirty_select(Tab, [{'_', [], ['$_']}]).

-spec index_read(atom(), term(), atom()) -> [tuple()].
index_read(Tab, Value, Field) ->
    mnesia:dirty_index_read(Tab, Value, Field).

-spec write(tuple()) -> ok.
write(Rec) ->
    mnesia:dirty_write(Rec).

-spec delete(atom(), term()) -> ok.
delete(Tab, Key) ->
    mnesia:dirty_delete(Tab, Key).

