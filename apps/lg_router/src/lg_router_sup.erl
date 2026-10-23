-module(lg_router_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
    Children = [#{id => lg_alert, start => {lg_alert, start_link, []}},
                #{id => lg_login_guard, start => {lg_login_guard, start_link, []}},
                #{id => lg_backup, start => {lg_backup, start_link, []}},
                #{id => lg_cooldown, start => {lg_cooldown, start_link, []}},
                #{id => lg_conc, start => {lg_conc, start_link, []}},
                #{id => lg_affinity, start => {lg_affinity, start_link, []}},
                #{id => lg_out_rate, start => {lg_out_rate, start_link, []}},
                #{id => lg_live_pg, start => {pg, start_link, [lg_live_pg]}},
                #{id => lg_live, start => {lg_live, start_link, []}},
                #{id => lg_realtime, start => {lg_realtime, start_link, []}},
                #{id => lg_middleware, start => {lg_middleware, start_link, []}},
                #{id => lg_otlp, start => {lg_otlp, start_link, []}},
                #{id => lg_otlp_metrics, start => {lg_otlp_metrics, start_link, []}},
                #{id => lg_limiter, start => {lg_limiter, start_link, []}},
                #{id => lg_budget, start => {lg_budget, start_link, []}},
                #{id => lg_health, start => {lg_health, start_link, []}},
                #{id => lg_plan, start => {lg_plan, start_link, []}},
                #{id => lg_balance, start => {lg_balance, start_link, []}}],
    {ok, {SupFlags, Children}}.
