-module(etl1_tcp).

-author("hejin-2011-03-24").

-behaviour(gen_server2).

%% Network Interface callback functions
-export([start_link/2, start_link/3,
        get_status/1,
        shakehand/1, check_shakehand/1,
        send_tcp/2,
        reconnect/1]).

%% gen_server callbacks
-export([init/1,
        handle_call/3,
        handle_cast/2,
        handle_info/2,
        prioritise_info/2,
        code_change/3,
        terminate/2]).

-include_lib("elog/include/elog.hrl").
-include("tl1.hrl").

-define(TCP_OPTIONS, [binary, {packet, 0}, {active, true}, {reuseaddr, true}, {send_timeout, 6000}]).

-define(SHAKEHAND_TIME, 5 * 60 * 1000).
-define(TIMEOUT, 3000).

-define(MAX_CONN, 100).


-record(state, {server, host, port, username, password, max_conn,
        socket,  % null | S
        count=0, tl1_table, conn_num=0,
        conn_state, %  disconnect | connected
        login_state, % undefined | succ | fail | ignore
        rest, dict=dict:new()}).

-import(dataset, [get_value/2, get_value/3]).

-import(extbif, [to_list/1]).

%%%-------------------------------------------------------------------
%%% API
%%%-------------------------------------------------------------------
start_link(Server, NetIfOpts) ->
    ?WARNING("start etl1_tcp....~p",[NetIfOpts]),
	gen_server2:start_link(?MODULE, [Server, NetIfOpts], []).

start_link(Server, Name, NetIfOpts) ->
    ?WARNING("start etl1_tcp....~p,~p",[Name, NetIfOpts]),
	gen_server2:start_link({local, Name}, ?MODULE, [Server, NetIfOpts], []).

login_state(Pid, LoginState) ->
    gen_server2:cast(Pid, {login_state, LoginState}).

get_status(Pid) ->
    gen_server2:call(Pid, get_status, 6000).

shakehand(Pid) ->
    Pid ! shakehand.

check_shakehand(Pid) ->
    Pid ! check_shakehand.

send_tcp(Pid, {ReqId, Cmd}) ->
    Pct = #pct{request_id = ReqId,
                type = 'req',
                data = Cmd
            },
    gen_server2:cast(Pid, {send, Pct});
send_tcp(Pid, Cmd) ->
    Pct = #pct{type = 'req',
                data = Cmd
            },
    gen_server2:cast(Pid, {send, Pct}).

reconnect(Pid) ->
    gen_server2:call(Pid, reconnect).


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
init([Server, Args]) ->
    case (catch do_init(Server, Args)) of
	{error, Reason} ->
	    {stop, Reason};
	{ok, State} ->
	    {ok, State}
    end.

do_init(Server, Args) ->
    Tl1Table = ets:new(tl1_table, [ordered_set, {keypos, #pct.id}]),
    %% -- Socket --
    Host = proplists:get_value(host, Args),
    Port = proplists:get_value(port, Args),
    Username = proplists:get_value(username, Args, undefined),
    Password = proplists:get_value(password, Args, undefined),
    MaxConn = proplists:get_value(max_conn, Args, ?MAX_CONN),
    {ok, Socket, ConnState} = connect(Host, Port, Username, Password),
    %%-- We are done ---
    {ok, #state{server = Server, host = Host, port = Port, username = Username, password = Password, max_conn = MaxConn,
        socket = Socket, tl1_table = Tl1Table, conn_state = ConnState, rest = <<>>}}.


connect(Host, Port, Username, Password) when is_binary(Host) ->
    connect(binary_to_list(Host), Port, Username, Password);
connect(Host, Port, Username, Password) ->
    case gen_tcp:connect(Host, Port, ?TCP_OPTIONS, ?TIMEOUT) of
    {ok, Socket} ->
        ?WARNING("connect succ...~p,~p,~p",[Socket, Host, Port]),
        login(Socket, Username, Password),
        {ok, Socket, connected};
    {error, Reason} ->
        ?WARNING("tcp connect failure: ~p, ~p", [Reason, {Host, Port, Username, Password}]),
        {ok, null, disconnect}
    end.

login(_Socket, undefined, undefined) ->
    login_state(self(), ignore);
login(Socket, Username, Password) when is_binary(Username)->
    login(Socket, binary_to_list(Username), Password);
login(Socket, Username, Password) when is_binary(Password)->
    login(Socket, Username, binary_to_list(Password));
login(Socket, Username, Password) ->
    ?WARNING("begin to login,~p,~p,~p", [Socket, Username, Password]),
    Cmd = lists:concat(["LOGIN:::login::", "UN=", Username, ",PWD=", Password, ";"]),
    tcp_send(Socket, Cmd).

login_again(Socket, Username, Password) ->
    ?WARNING("begin to relogin,~p,~p,~p", [Socket, Username, Password]),
    Cmd = lists:concat(["LOGIN:::login_again::", "UN=", to_list(Username), ",PWD=", to_list(Password), ";"]),
    tcp_send(Socket, Cmd).

%%--------------------------------------------------------------------
%% Func: handle_call/3
%% Returns: {reply, Reply, State}          |
%%          {reply, Reply, State, Timeout} |
%%          {noreply, State}               |
%%          {noreply, State, Timeout}      |
%%          {stop, Reason, Reply, State}   | (terminate/2 is called)
%%          {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_call(get_status, _From, #state{tl1_table = Tl1Table, conn_num = ConnNum} = State) ->
    {reply, {ok, [{count, ets:info(Tl1Table, size), ConnNum}, State]}, State};

handle_call(reconnect, _From, #state{server=Server,host=Host, port=Port, username=Username, password=Password} = State) ->
%    ?INFO("reconnect :~p", [State]),
    {ok, Socket, ConnState} = connect(Host, Port, Username, Password),
    case ConnState of
        disconnect -> 
            ?ERROR("reconnect fail, tcp:~p, ~p", [self(),State]),
            Server ! {reconnect, fail, self()};
        connected ->
            ?ERROR("reconnect succ, tcp:~p, ~p", [self(),State]),
            Server ! {reconnect, succ, self()}
    end,
    {reply, ConnState, State#state{socket = Socket, conn_num = 0, conn_state = ConnState}};

handle_call(stop, _From, State) ->
    ?INFO("received stop request", []),
    {stop, normal, State};

handle_call(Req, _From, State) ->
    ?WARNING("unexpect request: ~p,~p", [Req, State]),
    {reply, {error, {invalid_request, Req}}, State}.

%%--------------------------------------------------------------------
%% Func: handle_cast/2
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_cast({login_state, LoginState}, State) ->
    ?WARNING("login state ...~p, ~p", [LoginState, State]),
    case LoginState of
        succ -> clean_tl1_table(State);
        ignore -> clean_tl1_table(State);
        fail -> ok
    end,
    {noreply, State#state{login_state = LoginState}};

handle_cast({send, Pct}, #state{server = Server, conn_state = disconnect} = State) ->
    send_failed(Server, Pct, {conn_failed, State}),
    {noreply, State};

handle_cast({send, Pct}, #state{count = Count, tl1_table = Tl1Table, login_state = undefined} = State) ->
    NewId = get_next_id(Count),
    NewPct = Pct#pct{id = NewId},
    ets:insert(Tl1Table, NewPct),
    ?WARNING("hold on, need login first : ~p", [NewPct]),
    {noreply, State#state{count = NewId}};

handle_cast({send, Pct}, #state{server = Server, login_state = fail} = State) ->
    send_failed(Server, Pct, {login_failed, State}),
    {noreply, State};

handle_cast({send, Pct}, #state{count = Count, tl1_table = Tl1Table,conn_num = ConnNum, max_conn=MaxConn} = State)
        when ConnNum > MaxConn ->
    NewId = get_next_id(Count),
    NewPct = Pct#pct{id = NewId},
    ets:insert(Tl1Table, NewPct),
    {noreply, State#state{count = NewId}};

handle_cast({send, Pct}, #state{count = Count} = State) ->
    NewId = get_next_id(Count),
    NewPct = Pct#pct{id = NewId},
    NewConnNum = handle_send_tcp(NewPct, State),
    {noreply, State#state{count = NewId, conn_num = NewConnNum}};

handle_cast(Msg, State) ->
    ?WARNING("unexpected message: ~n~p", [Msg]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% Func: handle_info/2
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_info({tcp, Sock, Bytes}, #state{socket = Sock} = State) ->
    ?INFO("received tcp ~p ", [Bytes]),
    {noreply, check_bytes(Bytes, State)};

handle_info({tcp_closed, Socket}, #state{server = Server, socket = Socket} = State) ->
    ?ERROR("tcp close: ~p, ~p", [Socket, State]),
    Server ! {tl1_tcp_closed, self()},
%    erlang:send_after(30000, self(), retry_connect),
    {noreply, State#state{socket = null, conn_state = disconnect}};


handle_info(shakehand, #state{conn_state = connected} = State) ->
    ?INFO("send shakehand:~p, ~p",[self(),State]),
    send_tcp(self(), "SHAKEHAND:::shakehand::;"),
    TimeRef = erlang:send_after(?SHAKEHAND_TIME, self(), shakehand),
    put(shakehand, TimeRef),
    {noreply, State};
handle_info(shakehand, State) ->
    erase(shakehand),
    {noreply, State};

handle_info(check_shakehand, #state{conn_state = connected} = State) ->
    ?INFO("check_shakehand:~p, ~p",[self(),State]),
     case get(shakehand) of
        'undefined' -> ok;
         TimeRef -> erlang:cancel_timer(TimeRef)
     end,
     handle_info(shakehand, State),
    {noreply, State};
handle_info(check_shakehand, State) ->
    {noreply, State};

handle_info(Info, State) ->
    ?WARNING("unexpected info: ~p, ~n ~p", [Info, State]),
    {noreply, State}.

prioritise_info(get_status, _State) ->
    9;
prioritise_info(tcp_closed, _State) ->
    7;
prioritise_info(reconnect, _State) ->
    7;
prioritise_info(shakehand, _State) ->
    5;
prioritise_info(_, _State) ->
    0.

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
clean_tl1_table(#state{tl1_table = Tl1Table} = State) ->
    ?WARNING("begin to clean tl1table:~p", [{ets:info(Tl1Table, size), ets:first(Tl1Table)}]),
    clean_tl1_table(ets:first(Tl1Table), State).

clean_tl1_table('$end_of_table', _State) ->
    ok;
clean_tl1_table(Reqid, #state{tl1_table = Tl1Table, server = Server, socket = Sock} = State) ->
    case ets:lookup(Tl1Table, Reqid) of
        [Pct] ->
            tcp_send(Server, Sock, Pct),
            ets:delete(Tl1Table, Reqid);
        [] ->
            ok
     end,
    clean_tl1_table(ets:next(Tl1Table, Reqid), State).


check_tl1_table(#state{login_state = undefined, conn_num = ConnNum} = _State) ->
    ConnNum;
check_tl1_table(#state{tl1_table = Tl1Table, conn_num = ConnNum} = State) ->
    check_tl1_table(ets:first(Tl1Table), ConnNum, State).


check_tl1_table('$end_of_table', ConnNum, _State) ->
     ConnNum - 1;
check_tl1_table(Reqid, ConnNum, #state{tl1_table = Tl1Table} = State) ->
    case ets:lookup(Tl1Table, Reqid) of
        [Pct] ->
            handle_send_tcp(Pct, State),
            ets:delete(Tl1Table, Reqid);
        [] ->
            ok
     end,
     ConnNum.



check_bytes(Bytes, #state{rest = Rest} = State) ->
    NowBytes = binary:split(list_to_binary([Rest, Bytes]), <<";">>, [global]),
%    ?INFO("get bytes:~p", [NowBytes]),
    {OtherBytes, [LastBytes]} = lists:split(length(NowBytes)-1, NowBytes),
    NewState = check_byte(OtherBytes, State),
    NewState#state{rest = LastBytes}.

check_byte(Data, State) when is_list(Data)->
    lists:foldl(fun(Byte, NewState) ->
        check_byte(Byte, NewState)
    end, State, Data);
check_byte(Byte, State) ->    
    NowByte = binary:split(Byte, <<">">>, [global]),
    {OtherByte, [LastByte]} = lists:split(length(NowByte)-1, NowByte),
    handle_recv_msg(LastByte, handle_recv_wait(OtherByte, State)).

%% send
handle_send_tcp(Pct, #state{server = Server, conn_num = ConnNum, socket = Sock}) ->
    case tcp_send(Server, Sock, Pct) of
            succ -> ConnNum + 1;
            fail -> ConnNum
    end.

tcp_send(Sock, Cmd) ->
    ?INFO("send cmd: ~p", [Cmd]),
    case (catch gen_tcp:send(Sock, Cmd)) of
	ok ->
	    succ;
	Error ->
	    ?ERROR("failed sending message to ~n   ~p",[Error]), 
        fail
    end.

tcp_send(Server, Sock, #pct{data = Data} = Pct) ->
    case (catch gen_tcp:send(Sock, Data)) of
	ok ->
	    ?INFO("send cmd  to :~p,~p", [self(),Data]),
	    succ;
	{error, Reason} ->
	    ?ERROR("failed sending message to ~p",[Reason]),
        send_failed(Server, Pct, {tcp_send_error, Reason}),
        fail;
	Error ->
	    ?ERROR("failed sending message to ~n   ~p",[Error]),
        send_failed(Server, Pct, {tcp_send_exception, Error}),
        fail
    end.

send_failed(Server, Pct, ERROR) ->
    Server ! {tl1_error, Pct, ERROR}.


%% receive
handle_recv_wait([], State) ->
    State;
handle_recv_wait([A|Bytes], State) ->
    handle_recv_wait(Bytes, handle_recv_wait(A, State));
handle_recv_wait(<<>>, State) ->
    State;
handle_recv_wait(Bytes, #state{dict = Dict} = State) when is_binary(Bytes)->
    case (catch etl1_mpd:process_msg(Bytes)) of
        {ok, #pct{request_id = ReqId, has_field = false, data = NewData} = _Pct}  -> %% for mobile
            case NewData of
                {ok, Data} ->
                     case dict:find(ReqId, Dict) of
                        {ok, Data0} ->
							?INFO("find reqid: ~p, ~p", [ReqId, Data0]),
                            State#state{dict = dict:append_list(ReqId, etl1_mpd:add_record_field(Data0, Data), Dict)};
                        error ->
                            ?ERROR("need has field data:~p,~n  ~p",[ReqId, Data]),
                            State
                    end;
                {error, _Reason} ->
                    State
            end;
        {ok, #pct{request_id = ReqId, data = NewData} = _Pct}  ->
            case NewData of
                {ok, Data} ->
                    State#state{dict = dict:append_list(ReqId, Data, Dict)};
                {error, _Reason} ->
                    State
            end;
        Error ->
            ?ERROR("processing of received message failed: ~n ~p", [Error]),
            State
    end.

handle_recv_msg(<<>>, State)  ->
    State;
handle_recv_msg(Bytes, #state{server = Server, socket = Socket, username = Username, password = Password,
    dict = Dict} = State) ->
    case (catch etl1_mpd:process_msg(Bytes)) of
        {ok, #pct{request_id = "shakehand", complete_code = _CompletionCode}} ->
            State#state{conn_num = check_tl1_table(State)};
        {ok, #pct{request_id = "login", complete_code = CompletionCode}} ->
            ?WARNING("login res: ~p", [CompletionCode]),
            case CompletionCode of
                "COMPLD" -> login_state(self(), succ);
                "DENY" -> login_again(Socket, Username, Password)
            end,
            State;
        {ok, #pct{request_id = "login_again", complete_code = CompletionCode}} ->
            ?WARNING("login_again res: ~p", [CompletionCode]),
            LoginState = case CompletionCode of
                "COMPLD" -> succ;
                "DENY" -> fail
            end,
            login_state(self(), LoginState),
            State;
            
        {ok, #pct{type = 'alarm', data = {ok, Data}} = Pct}  ->
            Server ! {tl1_trap, self(), Pct#pct{data = Data}},
            State;
        {ok, #pct{type = 'output',complete_code = "DENY", en = "AAFD"} = Pct}  ->
            ?WARNING("error authentication, login_again : ~n ~p,", [Pct]),
            login(Socket, Username, Password),
            Server ! {tl1_tcp, self(), Pct},
            State#state{conn_num = check_tl1_table(State)};
        {ok, #pct{type = 'output', request_id = ReqId, has_field = HasField, data = NewData} = Pct}  ->
            AccData = case NewData of
                {ok, Data} ->
                    case dict:find(ReqId, Dict) of
                        {ok, Data0} ->
							?INFO("find reqid: ~p, ~p", [ReqId, Data0]),
                            Data1 = case HasField of
                                false -> etl1_mpd:add_record_field(Data0, Data);
                                _ -> Data
                            end,        
                            {ok, Data0 ++ Data1};
                        error ->
                            case HasField of
                               false ->
                                   ?ERROR("need has field data:~p,~n  ~p",[ReqId, Data]),
                                   {error, need_field};
                               _ ->
                                   {ok, Data}
                            end
                    end;
                {error, _Reason} ->
                    {error, _Reason}
            end,
            Server ! {tl1_tcp, self(), Pct#pct{data = AccData}},
            ?INFO("send tl1_tcp reqid:~p", [ReqId]),
            State#state{conn_num = check_tl1_table(State), dict = dict:erase(ReqId, Dict)};
        Error ->
            ?ERROR("processing of received message failed: ~p,~p", [Socket,Error]),
            State#state{conn_num = check_tl1_table(State)}
    end.

get_next_id(Id) ->
    if Id == 1000 * 1000 * 1000 ->
           0;
         true ->
            Id + 1
        end.

