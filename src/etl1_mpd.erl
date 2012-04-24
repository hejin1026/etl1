-module(etl1_mpd).

-author("hejin 2011-03-24").

-export([process_msg/1, generate_msg/2]).

-export([get_status_value/2]).

-include_lib("elog/include/elog.hrl").
-include("tl1.hrl").

-import(extbif, [to_list/1, to_integer/1]).

-record(tl1_response, {en, endesc, fields, records}).

%   ZTE_192.168.41.10 2011-07-19 16:45:35
%   M  CTAG DENY
process_msg(MsgData) when is_binary(MsgData) ->
%    ?INFO("get respond :~p", [MsgData]),
    Lines = string:tokens(to_list(MsgData), "\r\n"),
    process_msg(Lines);

process_msg(Lines) ->
    ?INFO("get respond splite :~p", [Lines]),
    _Header = lists:nth(1, Lines),
    RespondId = lists:nth(2, Lines),
    {ReqLevel, ReqId, CompletionCode} = get_response_id(RespondId),
    RespondBlock = lists:nthtail(2, Lines),
    process_msg({CompletionCode, ReqId, ReqLevel}, RespondBlock, Lines).

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
    RespondData = case get_response_body(CompletionCode, Rest) of
        no_data ->
            {ok, [[{en, En}, {endesc, Endesc}]]};
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
               data =  RespondData
               },
    {ok, Pct}.


%%%% second function %%%%
get_response_id(RespondId) ->
    Data = string:tokens(RespondId, " "),
    ReqLevel = lists:nth(1, Data),
    ReqId = lists:nth(2, Data),
    CompletionCode = lists:last(Data),
    {ReqLevel, ReqId, CompletionCode}.

get_trap_body(TrapLevel, TrapBody) ->
    {ok, Datas} = get_rows(TrapBody),
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


get_response_status([Status|Data], _Lines) ->
    {En, Rest} = get_status("EN=", Status),
    case En of
        false ->
            {{false, false}, [Status|Data]};
        _ ->
            {Endesc, _Rest1} = get_status("ENDESC=", Rest),
            {{En, Endesc}, Data}
     end;
get_response_status(_, Lines) ->
    ?WARNING("get unex data :~p", [Lines]),
    {{null, null}, []}.

%DELAY, DENY, PRTL, RTRV
get_response_body("COMPLD", Data)->
    %\r\n\r\n -> error =[]
     get_response_data(Data);
get_response_body("PRTL", Data)->
     get_response_data(Data);
get_response_body(_CompCode, Data)->
     {error, string:join(Data, ",")}.


get_response_data(Block) ->
%    ?INFO("get Block:~p", [Block]),
    {TotalPackageNo, Block0} = get_response_data("total_blocks=", Block),
    {CurrPackageNo, Block1} = get_response_data("block_number=", Block0),
    {PackageRecordsNo, Block2} = get_response_data("block_records=", Block1),
    {Title, Block3} = get_response_data("list |List |LST ", Block2),
    {_SpliteLine, Block4} = get_response_data("---", Block3),
%    ?INFO("get response:~p", [{TotalPackageNo, CurrPackageNo, PackageRecordsNo, Title}]),
    case get_response_data(fields, Block4) of
			{fields, []} ->
                no_data;
			{Fields, Block5} ->
			    {ok, Rows} =  get_rows(Block5),
				{data, #tl1_response{endesc= "COMPLD", fields = Fields, records = Rows}}
		    end.


get_status(Name, String) ->
    case string:str(String, Name) of
        0 ->
            {false, ""};
        N ->
            Rest = string:substr(String, N + length(Name)),
            get_status_value(Rest, [])
    end.

get_status_value([], Acc) ->
    {lists:reverse(Acc), ""};
get_status_value([$\t|String], Acc) ->
    {lists:reverse(Acc), String};
get_status_value([$\s,$E,$N|String], Acc) -> %endesc
    {lists:reverse(Acc), [$E,$N|String]};
get_status_value([A|String], Acc) ->
    get_status_value(String, [A|Acc]).


get_rows(Datas) ->
    get_rows(Datas, []).

get_rows([], Values) ->
    {ok, lists:reverse(Values)};
get_rows([";"], Values) ->
    {ok, lists:reverse(Values)};
get_rows([">"], Values) ->
    {ok, lists:reverse(Values)};
get_rows(["---" ++ _|_], Values) ->
    {ok, lists:reverse(Values)};
get_rows([Line|Response], Values) ->
    Row = string:tokens(Line, "\t"),
    get_rows(Response, [Row | Values]).


get_response_data(Name, []) ->
    {Name, []};
get_response_data(fields, [Line|Response]) ->
     Fields = string:tokens(Line, "\t"),
    {Fields, Response};
get_response_data(Name, [Line|Response]) ->
    case re:run(Line, Name) of
        nomatch ->
            get_response_data(Name, Response);
        {match, _N} ->
            Value = string:strip(Line) -- Name,
            {Value, Response}
        end.


to_tuple_records(_Fields, []) ->
	[[]];
to_tuple_records(Fields, Records) ->
	[to_tuple_record(Fields, Record) || Record <- Records].
	
to_tuple_record(Fields, Record) when length(Fields) >= length(Record) ->
	to_tuple_record(Fields, Record, []);
to_tuple_record(Fields, Record) ->
    ?WARNING("fields > record : ~p, ~n,~p", [Fields, Record]),
	[[]].

to_tuple_record([], [], Acc) ->
	Acc;
to_tuple_record([_F|FT], [undefined|VT], Acc) ->
	to_tuple_record(FT, VT, Acc);
to_tuple_record([F|FT], [], Acc) ->
	to_tuple_record(FT, [], [{list_to_atom(F), []} | Acc]);
to_tuple_record([F|FT], [V|VT], Acc) ->
	to_tuple_record(FT, VT, [{list_to_atom(F), V} | Acc]).



%%-----------------------------------------------------------------
%% Generate a message
%%-----------------------------------------------------------------
generate_msg(ReqId, CmdInit) ->
    Cmd = to_list(CmdInit),
    case re:replace(Cmd, "CTAG", to_list(ReqId), [global,{return, list}]) of
        Cmd -> {discarded, no_ctag};
        NewString -> {ok, NewString}
    end.

