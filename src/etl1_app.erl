-module(etl1_app).

-behaviour(application).

-define(APPLICATION, etl1).

-export([start/0, stop/0]).

-export([test_start/0]).

%%%-----------------------------------------------------------------
%%% application callbacks
%%%-----------------------------------------------------------------
-export([start/2, stop/1]).

start() ->
    application:start(?APPLICATION).

stop() ->
    application:stop(?APPLICATION).

start(normal, []) ->
    Opts = application:get_all_env(?APPLICATION),
    etl1_sup:start_link(Opts).

stop(_) ->
    ok.

test_start() ->
    application:start(cryto),
    elog:init(5, "var/log/tl1.log"),
    start().
