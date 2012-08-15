-module(etl1).

-author("hejin-2011-03-28").

-behaviour(gen_server).

%% Network Interface callback functions
-export([start_link/2,
        register_callback/1, register_callback/2,
        set_tl1/1, set_tl1_trap/1,
        get_tl1/0, get_tl1_req/0,
        input/2, input/3,
        input_group/2, input_group/3,
        input_asyn/2, input_asyn/3
     ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3, terminate/2]).


-include_lib("elog/include/elog.hrl").
-include("tl1.hrl").

-define(RETRIES, 2).

-define(REQ_TIMEOUT, 60000).

-define(CALL_TIMEOUT, 300000).

-import(extbif, [to_list/1, to_binary/1, to_integer/1]).

-record(request,  {id, type, ems, data, ref, timeout, time, from}).

-record(state, {sender, tl1_tcp, tl1_tcp_sup, req_id=0, req_type, req_over=0, req_timeout_over=0, callback=[]}).

%%%-------------------------------------------------------------------
%%% API
%%%-------------------------------------------------------------------
start_link(TcpSup, Tl1Options) ->
    ?INFO("start etl1....~p",[Tl1Options]),
	gen_server:start_link({local, ?MODULE},?MODULE, [TcpSup, Tl1Options], []).

register_callback(Callback) ->
    gen_server:call(?MODULE, {callback, Callback}).

register_callback(Pid, Callback) ->
    gen_server:call(Pid, {callback, Callback}).

get_tl1() ->
    gen_server:call(?MODULE, get_tl1, ?CALL_TIMEOUT).

get_tl1_req() ->
    gen_server:call(?MODULE, get_tl1_req, ?CALL_TIMEOUT).


set_tl1(Tl1Info) ->
    ?WARNING("set tl1 info....~p",[Tl1Info]),
    gen_server:call(?MODULE, {set_tl1, Tl1Info}, ?CALL_TIMEOUT).

set_tl1_trap(Tl1Info) ->
    gen_server:call(?MODULE, {set_tl1_trap, self(), Tl1Info}, ?CALL_TIMEOUT).

%%Cmd = LST-ONUSTATE::OLTID=${oltid},PORTID=${portid}:CTAG::;
input(Type, Cmd) ->
    input(Type, Cmd, ?REQ_TIMEOUT).

input(Type, Cmd, Timeout) when is_tuple(Type) and is_list(Cmd) ->
    case gen_server:call(?MODULE, {sync_input, self(), Type, Cmd, Timeout}, ?CALL_TIMEOUT) of
        {ok, {_CompCode, Data}, _} ->
            %Data :{ok , [Values]} | {ok, [[{en, En},{endesc, Endesc}]]}
            %send after : {error, {tl1_cmd_error, [{en, En},{endesc, Endesc},{reason, Reason}]}}
            Data;
        {error, Reason} ->
            %send before: {error, {invalid_request, Req}} | {error, no_ctag} | {error, {no_type, Type}}
            %             {error, {'EXIT',Reason }} | {error, {conn_failed, Info}} |{error, {login_failed, Info}}
            %sending    : {error, {tcp_send_error, Reason}} | {error, {tcp_send_exception, Error}}
            %send after : {error, {tl1_timeout, Data}}
            {error, Reason};
        Error ->
            %{'EXIT',{badarith,_}}
            {error, Error}
	end;
input(Type, {CmdDef, VarList}, Timeout) ->
    NCmd = varstr:eval(CmdDef, VarList),
    input(Type, NCmd, Timeout);
input(Type, Cmd, Timeout) ->
    input({Type, ""}, Cmd, Timeout).

input_group(Type, Cmd) ->
    input_group(Type, Cmd, ?REQ_TIMEOUT).

input_group(Type, Cmd, Timeout) ->
	case  input(Type, Cmd, Timeout) of
        {ok, [Data1|_]} ->
            ?INFO("get cmd:~p, data:~p",[Cmd, Data1]),
            {ok, Data1};
        Other ->
            Other
    end.

input_asyn(Type, Cmd) ->
    gen_server:cast(?MODULE, {asyn_input, Type, Cmd}).

input_asyn(Pid, Type, Cmd) ->
    gen_server:cast(Pid, {asyn_input, Type, Cmd}).

%%%-------------------------------------------------------------------
%%% Callback functions from gen_server
%%%-------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, State}          |
%%          {ok, State, Timeout} |
%%          ignore               |
%%          {stop, Reason}
%%--------------------------------------------------------------------
init([TcpSup, Tl1Options]) ->
        ?INFO("start etl1....~p",[Tl1Options]),
    case (catch do_init(TcpSup, Tl1Options)) of
        {error, Reason} ->
            {stop, Reason};
        {ok, Pids} ->
            ?INFO("get tl1_tcp :~p", [Pids]),
            {ok, #state{tl1_tcp = Pids, tl1_tcp_sup = TcpSup}}
    end.

do_init(TcpSup, Tl1Options) ->
    process_flag(trap_exit, true),
    ets:new(tl1_request_table, [set, named_table, protected, {keypos, #request.id}]),
    ets:new(tl1_request_timeout, [set, named_table, protected, {keypos, #request.id}]),
    Pids = connect_tl1(TcpSup, Tl1Options),
    {ok, Pids}.

connect_tl1(TcpSup, Tl1Infos) ->
    Pids = lists:map(fun(Tl1Info) ->
        case do_connect(TcpSup, Tl1Info) of
            {ok, Pid} -> Pid;
            {error, _Error} ->[]
        end
    end, Tl1Infos),
    lists:flatten(Pids).

do_connect(TcpSup, Tl1Info) ->
    ?INFO("get tl1 info:~p", [Tl1Info]),
    Type = proplists:get_value(manu, Tl1Info),
    CityId = proplists:get_value(cityid, Tl1Info, <<"">>),
    case do_connect2(TcpSup, Tl1Info) of
        {ok, Pid} ->
            etl1_tcp:shakehand(Pid),
            {ok, {{to_list(Type), to_list(CityId)}, Pid}};
        {error, Error} ->
            ?ERROR("get tcp error: ~p, ~p", [Error, Tl1Info]),
            {error, Error}
     end.

do_connect2(TcpSup, Tl1Info) ->
    case proplists:get_value(id, Tl1Info, false) of
        false ->
            etl1_tcp_sup:start_child(TcpSup, [self(), Tl1Info]);
        Id ->
            etl1_tcp_sup:start_child(TcpSup, [self(), list_to_atom("etl1_tcp_" ++ to_list(Id)), Tl1Info])
    end.

%%--------------------------------------------------------------------
%% Func: handle_call/3
%% Returns: {reply, Reply, State}          |
%%          {reply, Reply, State, Timeout} |
%%          {noreply, State}               |
%%          {noreply, State, Timeout}      |
%%          {stop, Reason, Reply, State}   | (terminate/2 is called)
%%          {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_call({callback, {Name, Pid}}, _From, #state{callback = Pids} = State) ->
    NewCall = lists:keystore(Name, 1, Pids, {Name, Pid}),
    {reply, ok, State#state{callback = NewCall}};

handle_call(get_tl1, _From, #state{tl1_tcp = Pids} = State) ->
    Result = lists:map(fun({_Type, Pid}) ->
        {ok, TcpState} = etl1_tcp:get_status(Pid),
        TcpState
    end, Pids),
    {reply, {ok, Result}, State};

handle_call(get_tl1_req, _From,  #state{req_id=Id, req_over=ReqOver, req_timeout_over = ReqTimeout} = State) ->
    Result = [{tl1_timeout, ets:info(tl1_request_timeout, size)},
            {tl1_table, ets:info(tl1_request_table, size)},
            {req_id, Id}, {req_over, ReqOver}, {req_timeout_over, ReqTimeout}],
    {reply, {ok, Result}, State};

handle_call({set_tl1, Tl1Info}, _From, #state{tl1_tcp = Pids, tl1_tcp_sup = TcpSup} = State) ->
    case do_connect(TcpSup, Tl1Info) of
        {ok, NewPid} ->
            {reply, {ok, NewPid}, State#state{tl1_tcp = [NewPid|Pids]}};
        {error, Error} ->
            {reply, {error, Error}, State}
    end;

handle_call({set_tl1_trap, Sender, Tl1Info}, _From, #state{tl1_tcp = Pids, tl1_tcp_sup = TcpSup} = State) ->
    case do_connect(TcpSup, Tl1Info) of
        {ok, {_Key, NewPid} = TcpPid} ->
            begin_recv_trap(NewPid),
            {reply, {ok, NewPid}, State#state{sender = Sender, tl1_tcp = [TcpPid | Pids]}};
        {error, {already_started, Pid}} ->
            begin_recv_trap(Pid),
            {reply, {error, {already_started, Pid}}, State#state{sender = Sender}};
        {error, Error} ->
            {reply, {error, Error}, State}
    end;

handle_call({sync_input, Send, Type, Cmd, Timeout}, From, #state{tl1_tcp = Pids} = State) ->
    ?INFO("handle_call,Pid:~p,from:~p, Cmd,~p", [{Send, node(Send)}, From, Cmd]),
    case get_tl1_tcp(Type, Pids) of
        [] ->
            {reply, {error, {no_type, Type}}, State};
        [Pid] ->
            case (catch handle_sync_input(Pid, Cmd, Timeout, From, State)) of
                {ok, NewState} ->
                    {noreply, NewState};
                Error ->
                    ?ERROR("error:~p, state:~p",[Error, State]),
                    {reply, Error, State}
            end
     end;

handle_call(Req, _From, State) ->
    ?WARNING("unexpect request: ~p", [Req]),
    {reply, {error, {invalid_request, Req}}, State}.

%%--------------------------------------------------------------------
%% Func: handle_cast/2
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_cast({asyn_input, Type, Cmd}, #state{tl1_tcp = Pids, callback = Callback} = State) ->
    ?INFO("handle_cast, Cmd,~p", [Cmd]),
    case get_tl1_tcp(Type, Pids) of
        [] ->
            lists:map(fun({_Name, Pid}) ->
                Pid ! {asyn_data, {error, {no_type, Type}}}
            end, Callback),
            {noreply, State};
        [Pid] ->
            handle_asyn_input(Pid, Cmd, Type, State)
    end;

handle_cast(Msg, State) ->
    ?WARNING("unexpected message: ~n~p", [Msg]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% Func: handle_info/2
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_info({sync_timeout, ReqId, From}, State) ->
    case ets:lookup(tl1_request_table, ReqId) of
        [#request{from = From, data = Data} = Req] ->
            ?WARNING("received sync_timeout [~w] message: ~p", [ReqId, Req]),
            gen_server:reply(From, {error, {tl1_timeout, [ReqId, Data]}}),
            ets:insert(tl1_request_timeout, Req),
            ets:delete(tl1_request_table, ReqId);
        V ->
            ?ERROR("cannot lookup reqid:~p, v:~p", [ReqId, V])
    end,
    {noreply, State};

handle_info({tl1_error, Pct, Reason}, State) ->
    handle_tl1_error(Pct, Reason, State),
    {noreply, State};

handle_info({tl1_tcp, _Tcp, Pct}, State) ->
    NState = handle_recv_tcp(Pct, State),
    {noreply, NState};

handle_info({tl1_trap, Tcp, Pct}, #state{sender = Sender} = State) ->
    Sender ! {tl1_trap, Tcp, Pct},
    {noreply, State};

handle_info({tl1_tcp_closed, Tcp}, State) ->
    timer:apply_after(10000, etl1_tcp, reconnect, [Tcp]),
    {noreply, State};

handle_info({reconn_fail, Tcp}, #state{tl1_tcp = Pids} = State) ->
    ?ERROR("reconn fail:~p", [State]),
    exit(Tcp, "reconn fail"),
    NewPids = [{Type, Pid}||{Type, Pid} <- Pids, Pid =/= Tcp],
    {noreply, State#state{tl1_tcp=NewPids}};

handle_info({'EXIT', Pid, Reason}, #state{tl1_tcp = Pids} = State) ->
    Type = [T || {T, P} <- Pids, P == Pid],
	?ERROR("unormal exit message received: ~p, ~p", [Type, Reason]),
	{noreply, State};

handle_info(Info, State) ->
    ?WARNING("unexpected info: ~n~p", [Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% Func: terminate/2
%% Purpose: Shutdown the server
%% Returns: any (ignored by gen_server)
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%----------------------------------------------------------------------
%% Func: code_change/3
%% Purpose: Convert process state when code is changed
%% Returns: {ok, NewState}
%%----------------------------------------------------------------------
code_change(_Vsn, State, _Extra) ->
    {ok, State}.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------
%% send
handle_sync_input(Pid, Cmd, Timeout, From, #state{req_id = ReqId} = State) ->
    NextReqId = get_next_reqid(ReqId),
    ?INFO("input reqid:~p, cmd:~p, state:~p",[NextReqId, Cmd, State]),
    Msg    = {sync_timeout, NextReqId, From},
    Ref    = erlang:send_after(Timeout, self(), Msg),
    Req    = #request{id = NextReqId,
              type    = 'input',
              data    = Cmd,
              ref     = Ref,
              time    = extbif:timestamp(),
              timeout = Timeout,
              from    = From},
    ets:insert(tl1_request_table, Req),
    send_req(Pid, Req, Cmd, State),
    {ok, State#state{req_id = NextReqId}}.

handle_asyn_input(Pid, Cmd, Ems, #state{req_id = ReqId} = State) ->
    NextReqId = get_next_reqid(ReqId),
    ?INFO("input reqid:~p, cmd:~p, state:~p",[NextReqId, Cmd, State]),
    Req    = #request{id = NextReqId,
              type    = 'asyn_input',
              ems     = Ems,
              data    = Cmd,
              time    = extbif:timestamp()},
    ets:insert(tl1_request_table, Req),
    send_req(Pid, Req, Cmd, State),
    {noreply, State#state{req_id = NextReqId}}.


send_req(Pid, Req, Cmd, State) ->
    try etl1_mpd:generate_msg(Req#request.id, Cmd) of
        {ok, NewCmd} ->
            etl1_tcp:send_tcp(Pid, {Req#request.id, NewCmd});
        {discarded, Reason} ->
            Pct = #pct{request_id = Req#request.id},
            handle_tl1_error(Pct, Reason, State)
         catch
            Error:Exception ->
                ?ERROR("exception: ~p, ~n ~p", [{Error, Exception}, erlang:get_stacktrace()]),
                Pct = #pct{request_id = Req#request.id},
                handle_tl1_error(Pct, {'EXIT',Exception}, State)
    end.

%% send error
handle_tl1_error(#pct{request_id = ReqId} = Pct, Reason, #state{callback = Callback} = _State) ->
    case ets:lookup(tl1_request_table, to_integer(ReqId)) of
        [#request{type = 'input', ref = Ref, from = From}] ->
            catch cancel_timer(Ref),
            gen_server:reply(From, {error, Reason}),
            ets:delete(tl1_request_table, ReqId),
            ok;
        [#request{type = 'asyn_input',data = Cmd, time = Time}] ->
            Now = extbif:timestamp(),
            ?INFO("recv tcp reqid:~p, time:~p, cmd :~p",[ReqId, Now - Time, Cmd]),
            lists:map(fun({_Name, Pid}) ->
                Pid ! {asyn_data, {error, Reason}}
            end, Callback);
        _ ->
            ?ERROR("unexpected tl1, reqid:~p, ~p,~n error: ~p",[ReqId, Pct, Reason])
    end;
handle_tl1_error(Tcp, Reason, _State) ->
    ?ERROR("tl1 error: ~p, ~p",[Tcp, Reason]).

%% receive
handle_recv_tcp(#pct{request_id = ReqId, type = 'output', complete_code = CompCode, data = Data} = _Pct,  
    #state{callback = Callback, req_over = ReqOver, req_timeout_over = ReqTimeoutOver} = State) ->
%    ?INFO("recv tcp reqid:~p, code:~p, data:~p",[ReqId, CompCode, Data]),
    case ets:lookup(tl1_request_table, to_integer(ReqId)) of
        [#request{type = 'input', ref = Ref, data = Cmd, timeout = Timeout, from = From}] ->
            Remaining = case (catch cancel_timer(Ref)) of
                Rem when is_integer(Rem) -> Rem;
                _ -> 0
            end,
            OutputData = {CompCode, Data},
            Reply = {ok, OutputData, {ReqId, Timeout - Remaining}},
            ?INFO("recv tcp reqid:~p, from:~p, cmd :~p",[{ReqId, (Timeout - Remaining)/1000}, From,Cmd]),
            %TODO Terminator判断是否结束，然后回复，需要reqid是否一致，下一个包是否有head，目的多次信息收集，一次返回
            gen_server:reply(From, Reply),
            ets:delete(tl1_request_table, to_integer(ReqId)),
            State#state{req_over = ReqOver + 1};
       [#request{type = 'asyn_input',ems = {Type, Cityid}, data = Cmd, time = Time}] ->
           Now = extbif:timestamp(),
           ?INFO("recv tcp reqid:~p, ems:~p, time:~p, cmd :~p",[ReqId, {Type, Cityid}, Now - Time, Cmd]),
            lists:map(fun({_Name, Pid}) ->
                Reply = {asyn_data, Data, {Type, Cityid}},
                Pid ! Reply
            end, Callback),
            State;
	_ ->
        case ets:lookup(tl1_request_timeout, to_integer(ReqId)) of
            [#request{data = Cmd, time = Time}] ->
                Now = extbif:timestamp(),
                ?ERROR("cannot find reqid:~p, time:~p, cmd:~p, ~n data:~p", [ReqId, Now - Time, Cmd, Data]),
                ets:delete(tl1_request_timeout, to_integer(ReqId)),
                State#state{req_timeout_over = ReqTimeoutOver + 1};
             _ ->
                ?ERROR("cannot find reqid2:~p, data: ~p", [ReqId, Data]),
                State
        end
	end;
handle_recv_tcp(Pct, State) ->
    ?ERROR("received crap  pct :~p", [Pct]),
    State.

%% second fun
cancel_timer(undefined) ->
    ok;
cancel_timer(Ref) ->
    (catch erlang:cancel_timer(Ref)).

get_next_reqid(ReqId) ->
    if ReqId == 1000 * 1000 * 1000 ->
           0;
         true ->
            ReqId + 1
        end.

get_tl1_tcp({Type, City}, Pids) ->
    GetPids = [Pid || {{T, C}, Pid} <- Pids, {T, C} == {to_list(Type), to_list(City)}],
    case length(GetPids) > 1 of
        false ->
            GetPids;
        true ->
            [lists:nth(random:uniform(length(GetPids)), GetPids)]
    end.

begin_recv_trap(Pid) ->
    etl1_tcp:send_tcp(Pid, "SUBSCRIBE:::subscribe::;").
