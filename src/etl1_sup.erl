-module(etl1_sup).

-behaviour(supervisor).

-export([start_link/1, init/1]).

%%%-------------------------------------------------------------------
%%% API
%%%-------------------------------------------------------------------
start_link(Opts) ->
    {ok, Sup} = supervisor:start_link({local, ?MODULE}, ?MODULE, []),
    Tl1Options = proplists:get_value(ems, Opts, []),
    Etl1TcpSub = {etl1_tcp_sup, {etl1_tcp_sup, start_link, []},
        temporary, infinity , supervisor, [etl1_tcp_sup]},
    {ok, TcpSup} = supervisor:start_child(Sup, Etl1TcpSub),
    Etl1 = {etl1, {etl1, start_link, [TcpSup, Tl1Options]},
        permanent, 10, worker, [etl1]},
    supervisor:start_child(Sup, Etl1),
    {ok, Sup}.



init([]) ->
	{ok, {{one_for_one, 10, 100}, []}}.
