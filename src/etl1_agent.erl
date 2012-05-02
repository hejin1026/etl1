-module(etl1_agent).

-author("hejin 11-12-19").

-include_lib("elog/include/elog.hrl").

-export([start_link/0]).

-behavior(gen_server).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3 ]).

-record(state, {channel}).

-record(rpc, {type, request_id, msg, reply}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, Conn} = amqp:connect(),
    Channel = open(Conn),
    {ok, #state{channel = Channel}}.

open(Conn) ->
    {ok, Channel} = amqp:open_channel(Conn),
    amqp:queue(Channel, <<"tl1.agent">>),
    amqp:consume(Channel, <<"tl1.agent">>),
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


handle_info(Info, State) ->
    ?ERROR("badinfo:  ~p", [Info]),
    {noreply, State}.

terminate(_Reason, #state{channel = Channel}) ->
    amqp_client:stop(Channel).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%%%%%%%%% interface fun %%%%%%%%
handle_rpc_req(#rpc{type = tl1, msg = {tl1, Cmd, Info}} = Rpc, #state{channel = Channel}) ->
    {value, DeviceManu} = dataset:get_value(device_manu, Info, "null"),
    {value, DeviceArea} = dataset:get_value(device_area, Info, "null"),
    Reply = etl1:input_group({DeviceManu, DeviceArea}, Cmd),
    amqp:send(Channel, <<"inter.agent">>, term_to_binary(Rpc#rpc{reply = Reply}));
handle_rpc_req(#rpc{type = Type} = Rpc, #state{channel = Channel}) ->
    amqp:send(Channel, <<"inter.agent">>, term_to_binary(Rpc#rpc{reply = {error, {unsupport_type, Type}}}));
handle_rpc_req(_Rpc, _State) ->
    unsupport.
        
