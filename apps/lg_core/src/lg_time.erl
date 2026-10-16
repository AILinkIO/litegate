%% @doc 时间工具。
-module(lg_time).

-export([now_ms/0, now_us/0]).

-spec now_ms() -> non_neg_integer().
now_ms() -> erlang:system_time(millisecond).

-spec now_us() -> non_neg_integer().
now_us() -> erlang:system_time(microsecond).
