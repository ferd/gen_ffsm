-module(example_ffsm).
-export([start_link/0, lock/0, unlock/0, peek/0]).
-export([init/1, handle_call/4, handle_cast/3,
         handle_info/3, code_change/4, terminate/3]).

-record(data, {}).

start_link() ->
    gen_ffsm:start_link({local, ?MODULE}, ?MODULE, [], [{debug, [trace]}]).

lock() ->
    gen_ffsm:cast(?MODULE, {lock, self()}).

unlock() ->
    gen_ffsm:cast(?MODULE, {unlock, self()}).

peek() ->
    gen_ffsm:call(?MODULE, peek).

%%% Callbacks %%%

init([]) ->
    {ok, unlocked, #data{}}.

handle_call(peek, _From, State, Data) ->
    {reply, State, State, Data}.

handle_cast({lock, _}, {locked, _} = State, Data) ->
    {noreply, State, Data};
handle_cast({lock, Pid}, unlocked, Data) ->
    {noreply, {locked, Pid}, Data};
handle_cast({unlock, Pid}, {locked, Pid}, Data) ->
    {noreply, unlocked, Data};
handle_cast({unlock, _}, State, Data) ->
    {noreply, State, Data}.

handle_info(_Ignore, State, Data) ->
    {noreply, State, Data}.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

terminate(_Reason, _State, _Data) ->
    ok.
