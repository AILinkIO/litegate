%% @doc HTTP 路由表。
-module(lg_web_routes).

-export([routes/0]).

-spec routes() -> list().
routes() ->
    [{"/health", lg_web_health, #{}},
     {"/metrics", lg_web_metrics, #{}},
     %% 代理 API
     {"/v1/chat/completions", lg_web_llm, #{format => openai}},
     {"/v1/messages", lg_web_llm, #{format => anthropic}},
     {"/v1/messages/count_tokens", lg_web_llm, #{format => anthropic, kind => count_tokens}},
     {"/v1/embeddings", lg_web_llm, #{format => openai, kind => embeddings}},
     {"/v1/images/generations", lg_web_llm, #{format => openai, kind => images}},
     {"/v1/audio/speech", lg_web_llm, #{format => openai, kind => speech}},
     %% 结构化决策（TypeSafe System One，如百炼 decision-model-preview；SDK 的 base_url 指向网关即可）
     {"/v1/systemone", lg_web_llm, #{format => openai, kind => systemone}},
     {"/v1/responses", lg_web_llm, #{format => responses}},
     {"/v1/models", lg_web_models, #{}},
     %% 控制台 Playground：控制台身份调用，走完整路由链路
     {"/api/playground/chat", lg_web_llm, #{format => openai, source => playground}},
     {"/api/playground/messages", lg_web_llm, #{format => anthropic, source => playground}},
     {"/api/playground/responses", lg_web_llm, #{format => responses, source => playground}},
     {"/api/playground/images", lg_web_llm, #{format => openai, kind => images, source => playground}},
     {"/api/playground/speech", lg_web_llm, #{format => openai, kind => speech, source => playground}},
     {"/api/playground/systemone", lg_web_llm, #{format => openai, kind => systemone, source => playground}},
     %% 控制台实时事件流（SSE）
     {"/api/live/stream", lg_web_live, #{}},
     %% 控制台管理 API
     {"/api/[...]", lg_api, #{}},
     %% 控制台静态资源（web/ 构建产物）；其余 /console 路径交给前端路由
     {"/", lg_web_redirect, #{to => <<"/console/">>}},
     {"/console/assets/[...]", cowboy_static, {priv_dir, lg_web, "static/assets"}},
     {"/console/favicon.svg", cowboy_static, {priv_file, lg_web, "static/favicon.svg"}},
     {"/console/[...]", lg_web_index, #{}}].
