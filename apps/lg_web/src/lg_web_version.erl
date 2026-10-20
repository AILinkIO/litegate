%% @doc 版本信息：GET /api/version（不涉密，无需登录）。
%% commit 由构建时注入 priv/build-info.json（Docker 构建传 GIT_SHA），本地开发缺省为 dev。
-module(lg_web_version).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req, State) ->
    {ok, lg_web_util:json(200, info(), Req), State}.

info() ->
    Vsn = case application:get_key(lg_web, vsn) of
              {ok, V} -> iolist_to_binary(V);
              _ -> <<"unknown">>
          end,
    #{<<"version">> => Vsn, <<"commit">> => commit()}.

commit() ->
    case file:read_file(filename:join(code:priv_dir(lg_web), "build-info.json")) of
        {ok, Bin} ->
            try json:decode(Bin) of
                #{<<"commit">> := C} when is_binary(C) -> C;
                _ -> <<"dev">>
            catch
                error:_ -> <<"dev">>
            end;
        {error, _} ->
            <<"dev">>
    end.
