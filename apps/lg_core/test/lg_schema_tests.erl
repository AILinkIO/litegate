-module(lg_schema_tests).

-include_lib("eunit/include/eunit.hrl").
-include("lg_core.hrl").

schema_test_() ->
    {setup, fun lg_core_test_util:start/0, fun lg_core_test_util:stop/1,
     fun(Dir) ->
         [?_test(tables_created(Dir)),
          ?_test(persist_across_restart()),
          ?_test(ids())]
     end}.

tables_created(Dir) ->
    Tabs = mnesia:system_info(tables),
    [?assert(lists:member(T, Tabs)) || {T, _} <- lg_schema:tables()],
    ?assertEqual(disc_copies, mnesia:table_info(schema, storage_type)),
    ?assertEqual(filename:join(Dir, "mnesia"), mnesia:system_info(directory)),
    ?assertEqual({ok, #lg_meta{key = schema_version, value = lg_schema:version()}},
                 lg_db:read(lg_meta, schema_version)).

persist_across_restart() ->
    Now = lg_time:now_ms(),
    ok = lg_db:write(#lg_user{id = <<"u1">>, username = <<"alice">>,
                              password_hash = <<"h">>, created_at = Now}),
    ok = application:stop(lg_core),
    stopped = mnesia:stop(),
    {ok, _} = application:ensure_all_started(lg_core),
    ?assertMatch([#lg_user{id = <<"u1">>}], lg_db:index_read(lg_user, <<"alice">>, username)),
    ?assertEqual({error, boom}, lg_db:transaction(fun() -> mnesia:abort(boom) end)).

ids() ->
    A = lg_id:new(<<"cred">>),
    ?assertMatch(<<"cred_", _:26/binary>>, A),
    timer:sleep(2),
    B = lg_id:new(<<"cred">>),
    ?assert(A < B).
