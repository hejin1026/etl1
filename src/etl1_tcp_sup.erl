-module(etl1_tcp_sup).

-created("hejin 2012-3-12").

-behaviour(supervisor).

-export([start_link/0, start_link/1, start_child/2]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, etl1_tcp_sup}, ?MODULE, []).

start_link(Name) ->
    supervisor:start_link({local, Name}, ?MODULE, []).

start_child(Sup, Params) ->
    supervisor:start_child(Sup, Params).

init([]) ->
    {ok, {{simple_one_for_one, 0, 1},
        [{etl1_tcp, {etl1_tcp, start_link, []},
            transient , 10, worker, [etl1_tcp]}]}}.
