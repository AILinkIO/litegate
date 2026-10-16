-module(lg_client_tests).

-include_lib("eunit/include/eunit.hrl").

%% 请求头样本取自本地抓包（Claude Code 2.1.281、Codex CLI 0.156.1，2026-10-13）
detect_test() ->
    D = fun(H, F) -> element(1, lg_client:detect(H, F)) end,
    Claude = #{<<"x-claude-code-session-id">> => <<"43a8e32e-3525-4469-a198-98a1627985af">>,
               <<"x-stainless-lang">> => <<"js">>, <<"x-app">> => <<"cli">>,
               <<"user-agent">> => <<"claude-cli/2.1.281 (external, sdk-cli)">>},
    ?assertEqual(<<"claude-code">>, D(Claude, anthropic)),
    ?assertEqual(<<"claude-code">>, D(#{<<"user-agent">> => <<"claude-cli/2.1.281 (external, cli)">>}, anthropic)),
    Codex = #{<<"session-id">> => <<"01a13428-db00-7970-b1d6-0915eedab9a5">>, <<"originator">> => <<"codex_exec">>,
              <<"user-agent">> => <<"codex_exec/0.156.1 (Ubuntu 24.4.0; x86_64) xterm-256color">>},
    ?assertEqual(<<"codex">>, D(Codex, responses)),
    ?assertEqual(<<"codex">>, D(#{<<"originator">> => <<"codex_cli_rs">>}, responses)),
    ?assertEqual(<<"opencode">>, D(#{<<"user-agent">> => <<"opencode/1.18.30 ai-sdk/provider-utils/3.0">>}, openai)),
    ?assertEqual(<<"openai-sdk">>, D(#{<<"user-agent">> => <<"OpenAI/Python 3.19.2">>}, openai)),
    ?assertEqual(<<"anthropic-sdk">>, D(#{<<"user-agent">> => <<"Anthropic/Python 1.8.0">>}, anthropic)),
    ?assertEqual(<<"anthropic-sdk">>, D(#{<<"x-stainless-lang">> => <<"js">>, <<"user-agent">> => <<"node">>}, anthropic)),
    ?assertEqual(<<"other">>, D(#{<<"user-agent">> => <<"curl/8.5.0">>}, openai)),
    ?assertEqual(<<"other">>, D(#{}, openai)),
    %% 自报优先；非法的自报名忽略
    ?assertEqual(<<"my-bot">>, D(Claude#{<<"x-litegate-client">> => <<"my-bot">>}, anthropic)),
    ?assertEqual(<<"claude-code">>, D(Claude#{<<"x-litegate-client">> => <<"bad name!">>}, anthropic)),
    %% 只保留 other 的 User-Agent 前 128 字节
    {_, UA} = lg_client:detect(#{<<"user-agent">> => binary:copy(<<"x">>, 300)}, openai),
    ?assertEqual(128, byte_size(UA)),
    ?assertEqual({<<"other">>, undefined}, lg_client:detect(#{}, openai)).
