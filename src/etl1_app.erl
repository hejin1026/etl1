-module(etl1_app).

-behaviour(application).

-include_lib("elog/include/elog.hrl").

-export([start/0, stop/0]).

%%%-----------------------------------------------------------------
%%% application callbacks
%%%-----------------------------------------------------------------
-export([start/2, stop/1]).

start() ->
    application:start(etl1).

stop() ->
    application:stop(etl1).

start(normal, []) ->
    Opts = application:get_all_env(etl1),
    etl1_sup:start_link(Opts).

stop(_) ->
    ok.
