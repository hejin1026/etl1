-module(etl1_agent).

-author("hejin 11-12-19").

-include_lib("elog/include/elog.hrl").

-export([start_link/0]).

-behavior(gen_server).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3 ]).

-record(state, {channel}).

-record(rpc, {type, request_id, msg, reply}).

start_link() ->
    gen_server:start_link({global, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, Conn} = amqp:connect(),
    Channel = open(Conn),
    {ok, #state{channel = Channel}}.

open(Conn) ->
    {ok, Channel} = amqp:open_channel(Conn),
    amqp:queue(Pid, <<"tl1.agent">>),
    amqp:consume(Pid, <<"tl1.agent">>, self()),
    Channel.


handle_call(Req, _From, State) ->
    ?ERROR("badreq: ~p", [Req]),
    {reply, {badreq, Req}, State}.

handle_cast(Msg, State) ->
    ?ERROR("bagmsg: ~p", [Msg]),
    {noreply, State}.

handle_info({deliver, <<"tl1.agent">>, _, Payload}, State) ->
    ?INFO("get inter.agent...~p", [binary_to_term(Payload)]),
    handle_rpc_req(binary_to_term(Payload), State),
    {noreply, State};

handle_info(reconnect, #state{broker_opts = Opts} = State) ->
    {ok, Pid} = connect(Opts),
    {noreply, State#state{broker = Pid}};

handle_info({'EXIT', Pid, _Reason}, #state{broker = Pid} = State) ->
    ?ERROR("amqp client is terminated: ~p", [Pid]),
    erlang:send_after(20000, self(), reconnect),
    {noreply, State#state{broker = undefined}};

handle_info(Info, State) ->
    ?ERROR("badinfo:  ~p", [Info]),
    {noreply, State}.

terminate(_Reason, #state{broker = Broker}) ->
    amqp_client:stop(Broker).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%%%%%%%%% interface fun %%%%%%%%
handle_rpc_req(#rpc{type = tl1, msg = {tl1, Cmd, Info}} = Rpc, #state{broker = Broker}) ->
    {value, DeviceManu} = dataset:get_value(device_manu, Info, "null"),
    {value, DeviceArea} = dataset:get_value(device_area, Info, "null"),
    Reply = etl1:input_group({DeviceManu, DeviceArea}, Cmd),
    amqp:send(Broker, <<"inter.agent">>, term_to_binary(Rpc#rpc{reply = Reply}));
handle_rpc_req(#rpc{type = Type} = Rpc, #state{broker = Broker}) ->
    amqp:send(Broker, <<"inter.agent">>, term_to_binary(Rpc#rpc{reply = {error, {unsupport_type, Type}}}));
handle_rpc_req(_Rpc, _State) ->
    unsupport.
        
