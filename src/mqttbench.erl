-module(mqttbench).

%% API exports
-export([main/1]).

%%====================================================================
%% API functions
%%====================================================================

%% escript Entry point
main([_NumOfConn, _MillisBtwSend, Host, UserName, Password, DataDir]) ->
    NumOfConn = list_to_integer(_NumOfConn),
    MillisBtwSend = list_to_integer(_MillisBtwSend),
    process_flag(trap_exit, true),
    register(caculator, self()),
    % data to send
    prepareData(DataDir),
    % build N connection
    [begin
        spawn_link(fun() -> worker(Host, UserName, Password, MillisBtwSend) end),
	case (N rem 100) of 0 -> timer:sleep(100); _ -> ok end
     end
    || N <- lists:seq(1, NumOfConn)], 
    % timer
    timer:send_interval(3000, report),
    % loop
    StartTime = erlang:system_time(microsecond),
    loop(0, 0, 0, StartTime, MillisBtwSend, Host, UserName, Password);  
main(_) ->
    io:format("Args: NumOfConn MillisBtwSend Host UserName Password DataDir\n", []).


%%====================================================================
%% Internal functions
%%====================================================================
loop(NumOfConn, NumOfSent, TotalRespTime, StartTime, MillisBtwSend, Host, UserName, Password) ->
    receive
        connected ->
            loop(NumOfConn+1, NumOfSent, TotalRespTime, StartTime, MillisBtwSend, Host, UserName, Password);
        {responseTime, RespTime} ->
            loop(NumOfConn, NumOfSent+1, TotalRespTime+RespTime, StartTime, MillisBtwSend, Host, UserName, Password);
        report ->
            TimePastMicro = erlang:system_time(microsecond) - StartTime,
            TotalRate = NumOfSent / (TimePastMicro / 1000000),
            SentPerConn = NumOfSent / (case NumOfConn of 0 -> 1; _ -> NumOfConn end),
            ConnRate = SentPerConn / (TimePastMicro / 1000000),
            AvgResponseTimeMilli = TotalRespTime / (case NumOfSent of 0 -> 1; _ -> NumOfSent end),
            TotalResponseMilli = AvgResponseTimeMilli * SentPerConn,
            io:format("~p:\n", [erlang:localtime()]),
            io:format("\tConnections: ~p\n", [NumOfConn]),
            io:format("\tTotal Sent: ~p\n", [NumOfSent]),
            io:format("\tAvg Connection Sent: ~.2f\n", [SentPerConn]),
            io:format("\tTotal Send Rate: ~.2f per second\n", [TotalRate]),
            io:format("\tAvg Connection Rate: ~.2f per second\n", [ConnRate]),
            io:format("\tTotal Used Time: ~p\n", [trunc(TimePastMicro / 1000000)]),
            io:format("\tTotal Response Time: ~.2f\n", [TotalResponseMilli / 1000]),
            io:format("\tAvg Response Time: ~.2f millisecond\n", [AvgResponseTimeMilli]),
            io:format("\n"),
            loop(NumOfConn, NumOfSent+1, TotalRespTime, StartTime, MillisBtwSend, Host, UserName, Password);
        {'EXIT', From, Reason} ->
            io:format("~p down, reason: ~p\n", [From, Reason]),
            spawn_link(fun() -> worker(Host, UserName, Password, MillisBtwSend) end),
            loop(NumOfConn-1, NumOfSent, TotalRespTime, StartTime, MillisBtwSend, Host, UserName, Password);
        _ ->
            loop(NumOfConn, NumOfSent, TotalRespTime, StartTime, MillisBtwSend, Host, UserName, Password)
    end. 

prepareData(Dir) ->
    ets:new(buffers, [duplicate_bag, protected, named_table]),
    {ok, FileNames} = file:list_dir(Dir),
    [loadFiles(Dir,SubDir) || SubDir <- FileNames, filelib:is_dir(Dir++"/"++SubDir)].    
loadFiles(Dir,SubDir) ->
    {ok, FileNames} = file:list_dir(Dir++"/"++SubDir),
    [loadFile(Dir,SubDir,Name) || Name <- FileNames, filelib:is_file(Dir++"/"++SubDir++"/"++Name)].
loadFile(Dir,SubDir,Name) ->
    {ok, Bin} = file:read_file(Dir++"/"++SubDir++"/"++Name),
    ets:insert(buffers, {"MQTT/"++Name, Bin}).

worker(Host, UserName, Password, MillisBtwSend) ->
    {ok, Conn} = erlmqtt:open_clean({Host, 1883}, [{username, UserName}, {password, Password}]), 
    caculator ! connected,
    workerLoop(Conn, ets:first(buffers), MillisBtwSend).
workerLoop(Conn, Key1, MillisBtwSend) ->
    % send
    Data = ets:lookup(buffers, Key1),
    [begin
        T1 = erlang:system_time(microsecond),
        erlmqtt:publish_sync(Conn, Topic, Buffer, at_least_once),
        T2 = erlang:system_time(microsecond),
        caculator ! {responseTime, (T2-T1)/1000}, 
        timer:sleep(MillisBtwSend)
    end
    || {Topic, Buffer} <- Data ],
    % next
    case ets:next(buffers, Key1) of
        '$end_of_table' -> 
            workerLoop(Conn, ets:first(buffers), MillisBtwSend);
        Key2 ->
            workerLoop(Conn, Key2, MillisBtwSend)
    end. 

