-module(statsd_client).
-behaviour(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0,
         start_link/1,
         increment/2,
         decrement/2,
         count/3,
         count/4,
         timing/3,
         timing/4,
         gauge/3,
         sets/3,
         flush/1,
         enable_buffer/1
        ]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3
        ]).

-record(state, {host, port, socket, buffer}).
-record(buffer, {enabled=false, payload, payload_size=0, max_payload_size}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    start_link([]).

start_link(Options) ->
    gen_server:start_link(?MODULE, Options, []).

stop(Pid) ->
    gen_server:call(Pid, stop).

increment(Pid, Bucket) ->
    count(Pid, Bucket, 1).

decrement(Pid, Bucket) ->
    count(Pid, Bucket, -1).

count(Pid, Bucket, Delta) ->
    count(Pid, Bucket, Delta, 1.0).

count(Pid, Bucket, Delta, SampleRate) ->
    gen_server:cast(Pid, {count, Bucket, Delta, SampleRate}).

timing(Pid, Bucket, Time) ->
    timing(Pid, Bucket, Time, 1.0).

timing(Pid, Bucket, Time, SampleRate) ->
    gen_server:cast(Pid, {time, Bucket, Time, SampleRate}).

gauge(Pid, Bucket, Value) ->
    gen_server:cast(Pid, {gauge, Bucket, Value}).

sets(Pid, Bucket, Value) ->
    gen_server:cast(Pid, {sets, Bucket, Value}).

flush(Pid) ->
    gen_server:cast(Pid, flush).

enable_buffer(Pid) ->
    gen_server:call(Pid, enable_buffer).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(Options) ->
    case gen_udp:open(0) of
        {ok, Socket} ->
            State = state(Options),
            {ok, State#state{socket=Socket}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};

handle_call(enable_buffer, _From, State) ->
    Buffer = State#state.buffer,
    Buffer1 = Buffer#buffer{enabled=true},
    {reply, ok, State#state{buffer=Buffer1}}.

handle_cast({count, Bucket, Delta, SampleRate}, State) ->
    Data = data(Bucket, Delta, <<"c">>),
    State1 = send_sample(Data, SampleRate, State),
    {noreply, State1};

handle_cast({time, Bucket, Time, SampleRate}, State) ->
    Data = data(Bucket, Time, <<"ms">>),
    State1 = send_sample(Data, SampleRate, State),
    {noreply, State1};

handle_cast({gauge, Bucket, Value}, State) ->
    Data = data(Bucket, Value, <<"g">>),
    State1 = send_data(Data, State),
    {noreply, State1};

handle_cast({sets, Bucket, Value}, State) ->
    Data = data(Bucket, Value, <<"s">>),
    State1 = send_data(Data, State),
    {noreply, State1};

handle_cast(flush, State) ->
    Buffer = State#state.buffer,
    case Buffer#buffer.enabled andalso Buffer#buffer.payload_size > 0 of
        true ->
            State1 = send_payload(Buffer#buffer.payload, State),
            Buffer1 = Buffer#buffer{payload=undefined, payload_size=0},
            {noreply, State1#state{buffer=Buffer1}};
        false ->
            {noreply, State}
    end.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    gen_udp:close(State#state.socket).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

state(Options) ->
    BufferOptions = proplists:get_value(buffer, Options, []),
    Buffer = buffer(BufferOptions),
    Host = proplists:get_value(host, Options, "localhost"),
    Port = proplists:get_value(port, Options, 8125),
    #state{host=Host, port=Port, buffer=Buffer}.

buffer(BufferOptions) ->
    Enabled = proplists:get_value(enabled, BufferOptions, false),
    MaxPayloadSize = proplists:get_value(max_payload_size, BufferOptions, 1432),
    #buffer{enabled=Enabled, max_payload_size=MaxPayloadSize}.

data(Bucket, Value, Type) when is_integer(Value) ->
    data(Bucket, integer_to_list(Value), Type);

data(Bucket, Value, Type) ->
    [Bucket, <<":">>, Value, <<"|">>, Type].

send_sample(Data, SampleRate, State) ->
    Random = random:uniform(),
    if
        SampleRate == 1.0 ->
            send_data(Data, State);
        Random =< SampleRate ->
            send_data([Data, <<"|@">>, io_lib:format("~p", [SampleRate])], State);
        true ->
            State
    end.

send_data(Data, State) ->
    Buffer = State#state.buffer,
    case Buffer#buffer.enabled of
        true ->
            buffer_data(Data, State);
        false ->
            send_payload(Data, State)
    end.

buffer_data(Data, State) ->
    Buffer = State#state.buffer,
    DataSize = iolist_size(Data),
    TotalSize = Buffer#buffer.payload_size + DataSize + 1,
    case TotalSize > Buffer#buffer.max_payload_size of
        true when Buffer#buffer.payload == undefined ->
            %% Data would fill Buffer; send immediately
            send_payload(Data, State);
        true ->
            %% Data would exceed max_payload_size
            %% Send current payload and buffer Data
            State1 = send_payload(Buffer#buffer.payload, State),
            Buffer1 = Buffer#buffer{payload=Data, payload_size=DataSize},
            State1#state{buffer=Buffer1};
        false when Buffer#buffer.payload == undefined ->
            %% First bit of Data in Buffer
            Buffer1 = Buffer#buffer{payload=Data, payload_size=DataSize},
            State#state{buffer=Buffer1};
        false ->
            %% Add Data to Buffer
            Payload = [Buffer#buffer.payload, "\n", Data],
            Buffer1 = Buffer#buffer{payload=Payload, payload_size=TotalSize},
            State#state{buffer=Buffer1}
    end.

send_payload(Payload, State) ->
    Socket = State#state.socket,
    Host = State#state.host,
    Port = State#state.port,
    case gen_udp:send(Socket, Host, Port, Payload) of
        ok ->
            State;
        {error, Reason} ->
            % TODO: do we need to reopen the socket?
            error_logger:error_report([{reason, Reason},
                                       {payload, Payload},
                                       {state, State}]),
            State
    end.

-include_lib("eunit/include/eunit.hrl").

statsd_client_test_() ->
    Tests = [fun test_increment/1,
             fun test_decrement/1,
             fun test_count_with_sample/1,
             fun test_timing/1,
             fun test_timing_with_sample/1,
             fun test_gauge/1,
             fun test_sets/1,
             fun test_buffer/1
            ],
    WrapTest = fun(T) -> fun(R) -> ?_test(T(R)) end end,
    {foreach,
     fun test_setup/0,
     fun test_cleanup/1,
     [WrapTest(Test) || Test <- Tests]}.

test_setup() ->
    try
        {ok, Server} = statsd_dummy_server:start(),
        {ok, Client} = start_link(),
        {Server, Client}
    catch
        Type:Reason ->
            error_logger:error_report({Type, Reason, erlang:get_stacktrace()}),
            throw({Type, Reason})
    end.

test_cleanup({Server, Client}) ->
    stop(Client),
    statsd_dummy_server:stop(Server).

dummy_wait(Server, N) ->
    statsd_dummy_server:wait(Server, N).

dummy_messages(Server) ->
    statsd_dummy_server:messages(Server).

%% Tests

test_increment({Server, Client}) ->
    increment(Client, "gorets"),
    dummy_wait(Server, 1),
    ?assertEqual(["gorets:1|c"], dummy_messages(Server)).

test_decrement({Server, Client}) ->
    decrement(Client, "gorets"),
    dummy_wait(Server, 1),
    ?assertEqual(["gorets:-1|c"], dummy_messages(Server)).

test_count_with_sample({Server, Client}) ->
    [count(Client, "gorets", 10, 0.9) || _ <- lists:seq(1, 10)],
    dummy_wait(Server, 1),
    ?assertEqual("gorets:10|c|@0.9", hd(dummy_messages(Server))).

test_timing({Server, Client}) ->
    timing(Client, "glork", 10),
    dummy_wait(Server, 1),
    ?assertEqual(["glork:10|ms"], dummy_messages(Server)).

test_timing_with_sample({Server, Client}) ->
    [timing(Client, "glork", 10, 0.9) || _ <- lists:seq(1, 10)],
    dummy_wait(Server, 1),
    ?assertEqual("glork:10|ms|@0.9", hd(dummy_messages(Server))).

test_gauge({Server, Client}) ->
    gauge(Client, "gaugor", 333),
    dummy_wait(Server, 1),
    ?assertEqual(["gaugor:333|g"], dummy_messages(Server)).

test_sets({Server, Client}) ->
    sets(Client, "uniques", 765),
    dummy_wait(Server, 1),
    ?assertEqual(["uniques:765|s"], dummy_messages(Server)).

test_buffer({Server, Client}) ->
    enable_buffer(Client),
    count(Client, "gorets", 1),
    timing(Client, "glork", 320),
    gauge(Client, "gaugor", 333),
    sets(Client, "uniques", 765),
    flush(Client),
    dummy_wait(Server, 1),
    ?assertEqual(["gorets:1|c\nglork:320|ms\ngaugor:333|g\nuniques:765|s"],
                  dummy_messages(Server)).
