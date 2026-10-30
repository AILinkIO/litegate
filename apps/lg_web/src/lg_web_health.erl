%% @doc /health：存活与依赖检查（docker HEALTHCHECK、负载均衡探活）。
%%
%% mnesia 未运行（被停止、正在关停）时返回 503：此时鉴权、路由都会失败，不应再接流量。
%% mnesia 自行崩溃时节点随之退出（permanent，见 lg_schema），由 systemd / docker 拉起。
-module(lg_web_health).
-behaviour(cowboy_handler).

-export([init/2, status/0]).

%% 近期有写盘错误时返回 degraded（仍为 200：网关照常转发请求，只是日志 / 用量可能丢失）
init(Req, State) ->
    {Code, Body} = status(),
    {ok, lg_web_util:json(Code, Body, Req), State}.

%% mnesia 未运行：503（鉴权、路由都依赖它）；存储写盘出错：200 + degraded（不摘流量，见 T21）
-spec status() -> {200 | 503, map()}.
status() ->
    case mnesia:system_info(is_running) of
        yes ->
            case lg_store:health() of
                ok -> {200, #{<<"status">> => <<"ok">>}};
                {degraded, Store} -> {200, #{<<"status">> => <<"degraded">>, <<"store">> => Store}}
            end;
        Other -> {503, #{<<"status">> => <<"unavailable">>, <<"mnesia">> => atom_to_binary(Other)}}
    end.
