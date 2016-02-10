-module(example_ffsm).
-export([start_link/0, lock/0, unlock/0, peek/0, force_lock/0]).
-export([init/1, handle_call/4, handle_cast/3,
         handle_info/3, code_change/4, terminate/3]).

-record(data, {ref}).

start_link() ->
    gen_ffsm:start_link({local, ?MODULE}, ?MODULE, [], [{debug, [trace]}]).

lock() ->
    gen_ffsm:call(?MODULE, {lock, self()}).

unlock() ->
    gen_ffsm:cast(?MODULE, {unlock, self()}).

peek() ->
    gen_ffsm:call(?MODULE, peek).

force_lock() ->
    gen_ffsm:call(?MODULE, {force_lock, self()}).

%%% Callbacks %%%

init([]) ->
    {ok, unlocked, #data{}}.

%% cannot re-acquire a lock
handle_call({lock, _}, _, {locked, _} = State, Data) ->
    {reply, false, State, Data};
%% can lock when unlocked 
handle_call({lock, Pid}, _, unlocked, Data) ->
    Ref = erlang:monitor(process, Pid),
    {reply, true, {locked, Pid}, Data#data{ref=Ref}};
%% force_lock simulates an 'unlock' then a 'lock' event. Can be called by anyone
%% but demos using either of the two accepted formats to directly prioritize next actions:
%% - `{noreply, Msg, State, Data, TimeoutOrHibernate, {next, List}}'
%% - `{reply, reply, Msg, State, Data, TimeoutOrHibernate, {next, List}}'
handle_call({force_lock, Pid}, From, State={_, Current}, Data) ->
    {noreply, State, Data, infinity,
     {next, [{cast, {unlock, Current}},
             {call, {lock, Pid}, From}]}};
%% Relays current state
handle_call(peek, _From, State, Data) ->
    {reply, State, State, Data}.

%% unlocking is async, only the owner can unlock
handle_cast({unlock, Pid}, {locked, Pid}, Data=#data{ref=Ref}) ->
    erlang:demonitor(Ref, [flush]),
    {noreply, unlocked, Data#data{ref=undefined}};
%% All other unlocks are ignored
handle_cast({unlock, _}, State, Data) ->
    {noreply, State, Data}.

%% Auto-unlock.
handle_info({'DOWN', Ref, process, Pid, _}, {locked, Pid}, Data=#data{ref=Ref}) ->
    {noreply, unlocked, Data#data{ref=undefined}};
handle_info(_Ignore, State, Data) ->
    {noreply, State, Data}.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

terminate(_Reason, _State, _Data) ->
    ok.
