%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2013 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(statsd_client).
-behaviour(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0,
         start_link/1,
         start_link/2,
         stop/1,
         increment/2,
         decrement/2,
         count/3,
         count/4,
         timing/3,
         timing/4,
         gauge/3,
         sets/3,
         metrics/2,
         flush/1,
         enable_buffer/1,
         disable_buffer/1,
         set_flush_after/2,
         should_sample/1
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

-record(state, {host,
                port,
                socket,
                buffer
               }).

-record(buffer, {enabled,
                 payload,
                 payload_size=0,
                 max_payload_size,
                 timer,
                 flush_after
                }).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    start_link([]).

start_link(Options) ->
    gen_server:start_link(?MODULE, Options, []).

start_link(Name, Options) ->
    gen_server:start_link(Name, ?MODULE, Options, []).

stop(Pid) ->
    gen_server:call(Pid, stop).

increment(Pid, Bucket) ->
    count(Pid, Bucket, 1).

decrement(Pid, Bucket) ->
    count(Pid, Bucket, -1).

count(Pid, Bucket, Delta) ->
    count(Pid, Bucket, Delta, 1.0).

count(Pid, Bucket, Delta, SampleRate) ->
    Metric = {count, Bucket, Delta, SampleRate},
    metrics(Pid, [Metric]).

timing(Pid, Bucket, Time) ->
    timing(Pid, Bucket, Time, 1.0).

timing(Pid, Bucket, Time, SampleRate) ->
    Metric = {time, Bucket, Time, SampleRate},
    metrics(Pid, [Metric]).

gauge(Pid, Bucket, Value) ->
    Metric = {gauge, Bucket, Value},
    metrics(Pid, [Metric]).

sets(Pid, Bucket, Value) ->
    Metric = {sets, Bucket, Value},
    metrics(Pid, [Metric]).

metrics(Pid, Metrics) ->
    Data = [metric_to_data(Metric) || Metric <- Metrics],
    gen_server:cast(Pid, {send_data, Data}).

flush(Pid) ->
    erlang:send(Pid, flush).

enable_buffer(Pid) ->
    gen_server:call(Pid, enable_buffer).

disable_buffer(Pid) ->
    gen_server:call(Pid, disable_buffer).

set_flush_after(Pid, FlushAfter) ->
    gen_server:call(Pid, {flush_after, FlushAfter}).

%% returns true|false indicating if a sample should be taken based on the given
%% sample rate
should_sample(SampleRate) ->
    random:seed(os:timestamp()),
    Random = random:uniform(),
    Random =< SampleRate.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(Options) ->
    %% TODO: udp options
    case gen_udp:open(0) of
        {ok, Socket} ->
            State = state(Options),
            {ok, State#state{socket=Socket}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};

handle_call(state, _From, State) ->
    {reply, State, State};

handle_call(enable_buffer, _From, State) ->
    Buffer = State#state.buffer,
    Buffer1 = Buffer#buffer{enabled=true},
    {reply, ok, State#state{buffer=Buffer1}};

handle_call(disable_buffer, _From, State) ->
    State1 = flush_buffer(State),
    Buffer = State1#state.buffer,
    Buffer1 = Buffer#buffer{enabled=false},
    {reply, ok, State1#state{buffer=Buffer1}};

handle_call({flush_after, FlushAfter}, _From, State) ->
    Buffer = State#state.buffer,
    Buffer1 = Buffer#buffer{flush_after=FlushAfter},
    {reply, ok, State#state{buffer=Buffer1}}.

handle_cast({send_data, Data}, State) ->
    State1 = lists:foldl(fun send_data/2, State, Data),
    {noreply, State1}.

handle_info(flush, State) ->
    State1 = flush_buffer(State),
    {noreply, State1}.

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
    Enabled = proplists:get_value(enabled, BufferOptions, true),
    MaxPayloadSize = proplists:get_value(max_payload_size, BufferOptions, 1432),
    FlushAfter = proplists:get_value(flush_after, BufferOptions, 100),
    #buffer{enabled=Enabled, max_payload_size=MaxPayloadSize, flush_after=FlushAfter}.

manage_timer(State) ->
    Buffer = State#state.buffer,
    case should_set_timer(Buffer) of
        true ->
            set_timer(State);
        false ->
            case should_cancel_timer(Buffer) of
                true ->
                    cancel_timer(State);
                false ->
                    State
            end
    end.

should_set_timer(Buffer) ->
    Buffer#buffer.payload_size > 0 andalso Buffer#buffer.timer == undefined.

should_cancel_timer(Buffer) ->
    Buffer#buffer.payload_size == 0 andalso is_reference(Buffer#buffer.timer).

set_timer(State) ->
    Buffer = State#state.buffer,
    Timer = erlang:send_after(Buffer#buffer.flush_after, self(), flush),
    Buffer1 = Buffer#buffer{timer=Timer},
    State#state{buffer=Buffer1}.

cancel_timer(State) ->
    Buffer = State#state.buffer,
    case is_reference(Buffer#buffer.timer) of
        true ->
            erlang:cancel_timer(Buffer#buffer.timer),
            Buffer1 = Buffer#buffer{timer=undefined},
            State#state{buffer=Buffer1};
        false ->
            State
    end.

flush_buffer(State) ->
    Buffer = State#state.buffer,
    case Buffer#buffer.enabled andalso Buffer#buffer.payload_size > 0 of
        true ->
            State1 = send_payload(Buffer#buffer.payload, State),
            Buffer1 = Buffer#buffer{payload=undefined, payload_size=0},
            manage_timer(State1#state{buffer=Buffer1});
        false ->
            State
    end.

metric_to_data({count, Bucket, Delta, SampleRate}) ->
    data(Bucket, Delta, <<"c">>, SampleRate);

metric_to_data({time, Bucket, Time, SampleRate}) ->
    data(Bucket, Time, <<"ms">>, SampleRate);

metric_to_data({gauge, Bucket, Value}) ->
    data(Bucket, Value, <<"g">>);

metric_to_data({sets, Bucket, Value}) ->
    data(Bucket, Value, <<"s">>).

data(Bucket, Value, Type) ->
    data(Bucket, Value, Type, 1.0).

data(Bucket, Value, Type, SampleRate) ->
    Data = [Bucket, <<":">>, io_lib:format("~p", [Value]), <<"|">>, Type],
    case is_float(SampleRate) andalso SampleRate < 1.0 of
        true ->
            [Data, <<"|@">>, io_lib:format("~p", [SampleRate])];
        false ->
            Data
    end.
        
send_data(Data, State) ->
    Buffer = State#state.buffer,
    case Buffer#buffer.enabled of
        true ->
            manage_timer(buffer_data(Data, State));
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
             fun test_buffer/1,
             fun test_flush_after/1,
             fun test_disable_buffer/1
            ],
    WrapTest = fun(T) -> fun(R) -> ?_test(T(R)) end end,
    {foreach,
     fun test_setup/0,
     fun test_cleanup/1,
     [WrapTest(Test) || Test <- Tests]}.

test_setup() ->
    try
        {ok, Server} = statsd_dummy_server:start(),
        {ok, Client} = start_link([{buffer, [{enabled, false}]}]),
        {Server, Client}
    catch
        Type:Reason ->
            error_logger:error_report([{type, Type},
                                       {reason, Reason},
                                       {stacktrace, erlang:get_stacktrace()}]),
            throw({Type, Reason})
    end.

test_cleanup({Server, Client}) ->
    stop(Client),
    statsd_dummy_server:stop(Server).

dummy_wait(Server, N) ->
    statsd_dummy_server:wait(Server, N).

dummy_messages(Server) ->
    statsd_dummy_server:messages(Server).

dummy_clear(Server) ->
    statsd_dummy_server:clear(Server).

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

test_flush_after({Server, Client}) ->
    enable_buffer(Client),
    set_flush_after(Client, 10),
    count(Client, "gorets", 1),
    timing(Client, "glork", 320),
    gauge(Client, "gaugor", 333),
    sets(Client, "uniques", 765),
    dummy_wait(Server, 1),
    ?assertEqual(["gorets:1|c\nglork:320|ms\ngaugor:333|g\nuniques:765|s"],
                  dummy_messages(Server)).

test_disable_buffer({Server, Client}) ->
    enable_buffer(Client),
    count(Client, "gorets", 1),
    timing(Client, "glork", 320),
    gauge(Client, "gaugor", 333),
    sets(Client, "uniques", 765),
    flush(Client),
    dummy_wait(Server, 1),
    ?assertEqual(["gorets:1|c\nglork:320|ms\ngaugor:333|g\nuniques:765|s"],
                  dummy_messages(Server)),
    dummy_clear(Server),
    disable_buffer(Client),
    count(Client, "gorets", 1),
    timing(Client, "glork", 320),
    gauge(Client, "gaugor", 333),
    sets(Client, "uniques", 765),
    dummy_wait(Server, 4),
    ?assertEqual(["gorets:1|c", "glork:320|ms", "gaugor:333|g", "uniques:765|s"],
                  dummy_messages(Server)).
