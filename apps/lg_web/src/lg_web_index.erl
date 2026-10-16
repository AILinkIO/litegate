%% @doc 控制台入口页 index.html：带 cache-control: no-cache，升级后浏览器总能拿到引用新资源的入口页
%% （assets 文件名带内容哈希，可以长期缓存）。
-module(lg_web_index).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    File = filename:join([code:priv_dir(lg_web), "static", "index.html"]),
    Req = case file:read_file(File) of
              {ok, Html} ->
                  cowboy_req:reply(200, #{<<"content-type">> => <<"text/html; charset=utf-8">>,
                                          <<"cache-control">> => <<"no-cache">>}, Html, Req0);
              {error, _} ->
                  cowboy_req:reply(404, #{<<"content-type">> => <<"text/plain">>},
                                   <<"Console not built: run npm run build in web/">>, Req0)
          end,
    {ok, Req, State}.
