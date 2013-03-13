-module(statsd_dummy_server).
-behaviour(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start/0,
         start/1,
         stop/1,
         messages/1,
         wait/2,
         clear/1
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

-record(state, {socket, messages=[], waiting=[]}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start() ->
    start(8125).

start(Port) ->
    gen_server:start(?MODULE, [Port], []).

stop(Pid) ->
    gen_server:call(Pid, stop).

messages(Pid) ->
    gen_server:call(Pid, messages).

wait(Pid, N) ->
    gen_server:call(Pid, {wait, N}).

clear(Pid) ->
    gen_server:call(Pid, clear).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([Port]) ->
    case gen_udp:open(Port) of
        {ok, Socket} ->
            {ok, #state{socket=Socket}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};

handle_call(messages, _From, State) ->
    {reply, State#state.messages, State};

handle_call({wait, N}, From, State) ->
    case length(State#state.messages) >= N of
        true ->
            {reply, ok, State};
        false ->
            Waiting = [{From, N}|State#state.waiting],
            {noreply, State#state{waiting=Waiting}}
    end;

handle_call(clear, _From, State) ->
    {reply, ok, State#state{messages=[]}}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({udp, _Socket, _IP, _InPortNo, Msg}, State) ->
    Msgs = [Msg|State#state.messages],
    FoldFun = fun({From, N}, Acc) ->
            case length(Msgs) >= N of
                true ->
                    gen_server:reply(From, ok),
                    Acc;
                false ->
                    [{From, N}|Acc]
            end
    end,
    Waiting = lists:foldl(FoldFun, [], State#state.waiting),
    {noreply, State#state{messages=Msgs, waiting=Waiting}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    gen_udp:close(State#state.socket).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
