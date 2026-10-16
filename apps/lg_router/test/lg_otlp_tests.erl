-module(lg_otlp_tests).

-include_lib("eunit/include/eunit.hrl").

parse_test() ->
    ?assertEqual({ok, <<"4bf92f3577b34da6a3ce929d0e0e4736">>, <<"00f067aa0ba902b7">>},
                 lg_otlp:parse_traceparent(<<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01">>)),
    ?assertEqual(error, lg_otlp:parse_traceparent(<<"01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01">>)),
    ?assertEqual(error, lg_otlp:parse_traceparent(<<"00-00000000000000000000000000000000-00f067aa0ba902b7-01">>)),
    ?assertEqual(error, lg_otlp:parse_traceparent(undefined)),
    ?assertEqual([{<<"authorization">>, <<"Basic abc==">>}, {<<"x-langfuse-ingestion-version">>, <<"4">>}],
                 lg_otlp:parse_headers(<<"Authorization=Basic%20abc==, x-langfuse-ingestion-version=4">>)),
    ?assertEqual([], lg_otlp:parse_headers(<<>>)).
