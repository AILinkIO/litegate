%% @doc models.dev 供应商 npm 包名 → 网关协议适配器。
%%
%% models.dev 的供应商绝大多数是 @ai-sdk/openai-compatible，走 OpenAI 透传；
%% 未列出的 SDK（如 Google、Bedrock）暂不支持自动适配，用户可手动建凭证并指定协议。
-module(lg_catalog_protocol).

-export([from_npm/1]).

-spec from_npm(binary() | undefined) ->
          {ok, openai | anthropic, binary() | undefined} | unsupported.
from_npm(<<"@ai-sdk/anthropic">>) ->
    {ok, anthropic, <<"https://api.anthropic.com">>};
from_npm(<<"@ai-sdk/openai">>) ->
    {ok, openai, <<"https://api.openai.com/v1">>};
from_npm(<<"@ai-sdk/openai-compatible">>) -> {ok, openai, undefined};
from_npm(<<"@openrouter/ai-sdk-provider">>) ->
    {ok, openai, <<"https://openrouter.ai/api/v1">>};
from_npm(<<"@ai-sdk/deepinfra">>) ->
    {ok, openai, <<"https://api.deepinfra.com/v1/openai">>};
from_npm(<<"@ai-sdk/cerebras">>) ->
    {ok, openai, <<"https://api.cerebras.ai/v1">>};
from_npm(<<"@ai-sdk/groq">>) ->
    {ok, openai, <<"https://api.groq.com/openai/v1">>};
from_npm(<<"@ai-sdk/xai">>) ->
    {ok, openai, <<"https://api.x.ai/v1">>};
from_npm(<<"@ai-sdk/mistral">>) ->
    {ok, openai, <<"https://api.mistral.ai/v1">>};
from_npm(<<"@ai-sdk/togetherai">>) ->
    {ok, openai, <<"https://api.together.xyz/v1">>};
from_npm(<<"@ai-sdk/fireworks">>) ->
    {ok, openai, <<"https://api.fireworks.ai/inference/v1">>};
from_npm(<<"@ai-sdk/perplexity">>) ->
    {ok, openai, <<"https://api.perplexity.ai">>};
from_npm(<<"@ai-sdk/deepseek">>) ->
    {ok, openai, <<"https://api.deepseek.com">>};
from_npm(<<"venice-ai-sdk-provider">>) ->
    {ok, openai, <<"https://api.venice.ai/api/v1">>};
from_npm(<<"@aihubmix/ai-sdk-provider">>) ->
    {ok, openai, <<"https://aihubmix.com/v1">>};
%% Gemini 的 OpenAI 兼容端点
from_npm(<<"@ai-sdk/google">>) ->
    {ok, openai, <<"https://generativelanguage.googleapis.com/v1beta/openai">>};
from_npm(_) ->
    unsupported.
