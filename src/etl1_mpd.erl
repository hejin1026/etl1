-module(etl1_mpd).

-author("hejin 2011-03-24").

-export([process_msg/1, generate_msg/2, add_record_field/2]).

-export([get_status_value/2]).

-include_lib("elog/include/elog.hrl").
-include("tl1.hrl").

-import(extbif, [to_list/1, to_integer/1, to_atom/1]).

-record(tl1_response, {en, endesc, fields, records}).

%   ZTE_192.168.41.10 2011-07-19 16:45:35
%   M  CTAG DENY
process_msg(MsgData) when is_binary(MsgData) ->
    %    ?INFO("get respond :~p", [MsgData]),
    Lines = string:tokens(string:strip(to_list(MsgData)), "\r\n"),
    process_msg(Lines);

process_msg(Lines0) ->
    ?INFO("get respond splite :~p", [Lines0]),
    Lines = check(Lines0),
    _Header = lists:nth(1, Lines),
    RespondId = lists:nth(2, Lines),
    {ReqLevel, ReqId, CompletionCode} = get_response_id(RespondId),
    RespondBlock = lists:nthtail(2, Lines),
    process_msg({CompletionCode, ReqId, ReqLevel}, RespondBlock, Lines).

%% for bell
check(["<IP"++_,"<"|Lines]) -> Lines;
check(["IP"++_,"<"|Lines]) -> Lines;
check(Lines) ->Lines.


%% Code
get_response_id(RespondId) ->
    Data = string:tokens(RespondId, " "),
    ReqLevel = lists:nth(1, Data),
    ReqId = lists:nth(2, Data),
    CompletionCode = case lists:last(Data) of
        ReqId -> "NULL";
        Code -> Code
    end,
    {ReqLevel, ReqId, CompletionCode}.


get_trap_body(TrapLevel, TrapBody) ->
    %%TODO need support for mobile??
    {ok, Datas} = get_rows(telecom, TrapBody),
    lists:map(fun(Data) ->
          Rest =  lists:map(fun(Item) ->
                        case string:tokens(Item, "=") of
                            [Name,Value] ->
                                {list_to_atom(Name), Value};
                            _ ->
                                []
                        end
                    end, Data),
          {ok, [{alarm_level, TrapLevel}|lists:flatten(Rest)]}
     end, Datas).

%% message
process_msg({"ALARM", ReqId, TrapLevel}, RespondBlock, _Lines) ->
    TrapData = get_trap_body(TrapLevel, RespondBlock),
    ?INFO("get trap data ~p", [TrapData]),
    Pct = #pct{request_id = ReqId,
               type = 'alarm',
               data =  {ok, TrapData}
              },
    {ok, Pct};

process_msg({CompletionCode, ReqId, _ReqLevel}, RespondBlock, Lines) ->
    {{En, Endesc}, Rest} = get_response_status(RespondBlock, Lines),
    %    ?INFO("get en endesc :~p data:~p",[{En,Endesc}, Rest]),
    {CheckField, RespondData} = case check_version(CompletionCode, Rest) of
                                  telecom ->
                                      {true, check_response_body(CompletionCode, Rest)};
                                  mobile ->
                                      HasField = check_field(Rest),
                                      {HasField, check_response_body_2(CompletionCode, HasField, Rest)};
                                 {error, _} = Error ->
                                      {null, Error}
                              end,
    RespondData2 = case RespondData of
                      no_data ->
                          {ok, [[{en, En}, {endesc, Endesc}]]};
                      {data, #tl1_response{fields = null, records = Records}} ->
                          {ok, Records};
                      {data, #tl1_response{fields = Fileds, records = Records}} ->
                          {ok, to_tuple_records(Fileds, Records)};
                      {error, Reason} ->
                          {error, {tl1_cmd_error, [{en, En}, {endesc, Endesc}, {reason, Reason}]}}
                  end,
    %    Terminator = lists:last(RespondBlock),
    %    ?INFO("reqid:~p,comp_code: ~p, terminator: ~p, data:~p",[ReqId, CompletionCode, Terminator, RespondData]),
    Pct = #pct{request_id = ReqId,
               type = 'output',
               complete_code = CompletionCode,
               en = En,
               has_field = CheckField,
               data =  RespondData2
              },
    {ok, Pct}.

%% en endesc
get_response_status([Status|Data], _Lines) ->
    case get_status("EN=", Status) of
        false ->
            {{false, false}, [Status|Data]};
        En ->
            Endesc = get_status("ENDESC=", Status),
            {{En, Endesc}, Data}
    end;
get_response_status(_, Lines) ->
    ?WARNING("get unex data :~p", [Lines]),
    {{null, null}, []}.

get_status(Name, String) ->
    case re:run(String, Name) of
        nomatch -> false;
        {match, [{Start,Len}]} ->
            Rest = string:substr(String, Start + 1 + Len),
            get_status_value(Rest, [])
    end.

get_status_value([], Acc) ->
    lists:reverse(Acc);
get_status_value([$\t|_S], Acc) ->
    lists:reverse(Acc);
get_status_value([$\s,$E,$N|_S], Acc) -> %endesc
    lists:reverse(Acc);
get_status_value([A|String], Acc) ->
    get_status_value(String, [A|Acc]).


%%
check_version("COMPLD", Rest) ->
    case get_response_util_data("block_records=", lists:sublist(Rest, 5)) of
        {nomatch, _} -> mobile;
        _ -> telecom
     end;
check_version("PRTL", _Rest) -> telecom;
check_version("NULL", _Rest) -> mobile;
check_version(_CompCode, Rest) ->  {error, string:join(Rest, ",")}.


%DELAY, DENY, PRTL, RTRV 
check_response_body("COMPLD", Data) ->
    %\r\n\r\n -> error =[]
    get_response_data(Data);
check_response_body("PRTL", Data)->
    get_response_data(Data).

%NULL
check_response_body_2("COMPLD", HasField, Data)->
    get_response_data_2(HasField, Data);
check_response_body_2("NULL", HasField, Data)->
    get_response_data_2(HasField, Data).


check_field(Data) ->
    Pre = "totalrecord=",
    case get_response_util_data(Pre, lists:sublist(Data, 5)) of
        {nomatch, _} -> false;
        _ -> true
     end.

%% for telecom [has field] 
get_response_data(Block) ->
    ?INFO("get Block:~p", [Block]),
    %    {TotalPackageNo, Block0} = get_response_value("total_blocks=", Block),
    %    {CurrPackageNo, Block1} = get_response_value("block_number=", Block0),
    %    {PackageRecordsNo, Block2} = get_response_value("block_records=", Block1),
    %%    TitlePre  = "list |List |LST ..."
    %%    {Title, Block3} = get_response_value(TitlePre, Block2),
    %    ?INFO("get response:~p", [{TotalPackageNo, CurrPackageNo, PackageRecordsNo, Title}]),
    {_SpliteLine, Block4} = get_response_util_data("-----", Block),
    case get_response_value(fields, Block4) of
        {fields, []} ->
            no_data;
        {Fields, Block5} ->
            {ok, Rows} =  get_rows(telecom, Block5),
            {data, #tl1_response{fields = Fields, records = Rows}}
    end.


%% for mobile [not field || has field]
get_response_data_2(_, []) ->
    no_data;
get_response_data_2(false, Block) ->
    ?INFO("get Block:~p", [Block]),
    {ok, Rows} = get_rows(mobile, Block),
    {data, #tl1_response{fields = null, records = Rows}};
get_response_data_2(true, Block) ->
    ?INFO("get Block:~p", [Block]),
    {_SpliteLine, Block4} = get_response_util_data("-----", Block),
    case get_response_value(fields, Block4) of
        {fields, []} ->
            no_data;
        {Fields, Block5} ->
            {ok, Rows} =  get_rows(mobile, Block5),
            {data, #tl1_response{fields = Fields, records = Rows}}
    end.


%%%%%  common  %%%%
get_response_util_data(_Pre, []) ->
    {nomatch, []};
get_response_util_data(Pre, [Line|Response]) ->
    case re:run(Line, Pre) of
        nomatch ->
            get_response_util_data(Pre, Response);
        {match, _N} ->
            {Line, Response}
    end.

get_response_value(Name, []) ->
    {Name, []};
get_response_value(fields, [Line|Response]) ->
    Fields = string:tokens(Line, [$\s,$\t]),
    {Fields, Response};
get_response_value(Name, [Line|Response] = Block) ->
    case re:run(Line, Name) of
        nomatch ->
            {unknow, Block};
        {match, _N} ->
            Value = string:strip(Line) -- Name,
            {Value, Response}
    end.
    
get_rows(telecom, Datas) ->
    get_rows(Datas, [], [$\t]);
get_rows(mobile, Datas) ->
    get_rows(Datas, [], [$\s]).

get_rows([], Values, _Splite) ->
    {ok, lists:reverse(Values)};
get_rows([";"], Values, _Splite) ->
    {ok, lists:reverse(Values)};
get_rows([">"], Values, _Splite) ->
    {ok, lists:reverse(Values)};
get_rows(["---" ++ _|_], Values, _Splite) ->
    {ok, lists:reverse(Values)};
get_rows([Line|Response], Values, Splite) ->
    Row = string:tokens(Line, Splite),
    get_rows(Response, [Row | Values], Splite).


to_tuple_records(_Fields, []) ->
    [[]];
to_tuple_records(Fields, Records) ->
    [to_tuple_record(Fields, Record) || Record <- Records].
    
to_tuple_record(Fields, Record) when length(Fields) =< length(Record) ->
    to_tuple_record(Fields, Record, []);
to_tuple_record(Fields, Record) ->
    ?WARNING("fields > record : ~p, ~n,~p", [Fields, Record]),
    [].

to_tuple_record([], [], Acc) ->
    Acc;
to_tuple_record([_F|FT], [undefined|VT], Acc) ->
    to_tuple_record(FT, VT, Acc);
to_tuple_record([], [_V|VT], Acc) ->
    to_tuple_record([], VT, Acc);
to_tuple_record([F|FT], [V|VT], Acc) ->
	to_tuple_record(FT, VT, [{to_atom(F), V} | Acc]).

get_field([]) -> [];
get_field(Records) ->
    lists:reverse([Name ||{Name, _Value} <- lists:nth(1, Records)]).

%%-----------------------------------------------------------------
%% Generate a message
%%-----------------------------------------------------------------
generate_msg(ReqId, CmdInit) ->
    Cmd = to_list(CmdInit),
    case re:replace(Cmd, "CTAG", to_list(ReqId), [global,{return, list}]) of
        Cmd -> {discarded, no_ctag};
        NewString -> {ok, NewString}
    end.

add_record_field(Data, DefectData) ->
    Fields = get_field(Data),
    to_tuple_records(Fields, DefectData).

