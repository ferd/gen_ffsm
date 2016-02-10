-module(gen_ffsm).

%% API exports
-export([start/3, start/4,
         start_link/3, start_link/4,
         stop/1, stop/3,
         call/2, call/3,
         cast/2, reply/2]).

%% System exports
-export([system_continue/3,
         system_terminate/4,
         system_code_change/4,
         system_get_state/1,
         system_replace_state/2,
         format_status/2]).

%% Internal exports
-export([init_it/6]).

-import(error_logger, [format/2]).

%%====================================================================
%% API functions
%%====================================================================
start(Mod, Args, Options) ->
    gen:start(?MODULE, nolink, Mod, Args, Options).

start(Name, Mod, Args, Options) ->
    gen:start(?MODULE, nolink, Name, Mod, Args, Options).

start_link(Mod, Args, Options) ->
    gen:start(?MODULE, link, Mod, Args, Options).

start_link(Name, Mod, Args, Options) ->
    gen:start(?MODULE, link, Name, Mod, Args, Options).

stop(Name) ->
    gen:stop(Name).

stop(Name, Reason, Timeout) ->
    gen:stop(Name, Reason, Timeout).

call(Name, Request) ->
    case catch gen:call(Name, '$gen_call', Request) of
        {ok,Res} ->
            Res;
        {'EXIT',Reason} ->
            exit({Reason, {?MODULE, call, [Name, Request]}})
    end.

call(Name, Request, Timeout) ->
    case catch gen:call(Name, '$gen_call', Request, Timeout) of
        {ok,Res} ->
            Res;
        {'EXIT',Reason} ->
            exit({Reason, {?MODULE, call, [Name, Request, Timeout]}})
    end.

cast({global,Name}, Request) ->
        catch global:send(Name, cast_msg(Request)),
            ok;
cast({via, Mod, Name}, Request) ->
        catch Mod:send(Name, cast_msg(Request)),
            ok;
cast({Name,Node}=Dest, Request) when is_atom(Name), is_atom(Node) -> 
        do_cast(Dest, Request);
cast(Dest, Request) when is_atom(Dest) ->
        do_cast(Dest, Request);
cast(Dest, Request) when is_pid(Dest) ->
        do_cast(Dest, Request).

do_cast(Dest, Request) ->
        do_send(Dest, cast_msg(Request)),
            ok.
cast_msg(Request) -> {'$gen_cast',Request}.

reply({To, Tag}, Reply) ->
        catch To ! {Tag, Reply}.

%%====================================================================
%% Internal functions
%%====================================================================
init_it(Starter, self, Name, Mod, Args, Options) ->
    init_it(Starter, self(), Name, Mod, Args, Options);
init_it(Starter, Parent, Name0, Mod, Args, Options) ->
    io:format("~p~n", [?LINE]),
    Name = name(Name0),
    Debug = debug_options(Name, Options),
    case catch Mod:init(Args) of
        {ok, State, Data} ->
            proc_lib:init_ack(Starter, {ok, self()}),
            loop(Parent, Name, State, Data, Mod, infinity, Debug, []);
        {ok, State, Data, Timeout} ->
            proc_lib:init_ack(Starter, {ok, self()}),
            loop(Parent, Name, State, Data, Mod, Timeout, Debug, []);
        {stop, Reason} ->
            %% For consistency, we must make sure that the
            %% registered name (if any) is unregistered before
            %% the parent process is notified about the failure.
            %% (Otherwise, the parent process could get
            %% an 'already_started' error if it immediately
            %% tried starting the process again.)
            unregister_name(Name0),
            proc_lib:init_ack(Starter, {error, Reason}),
            exit(Reason);
        ignore ->
            unregister_name(Name0),
            proc_lib:init_ack(Starter, ignore),
            exit(normal);
        {'EXIT', Reason} ->
            unregister_name(Name0),
            proc_lib:init_ack(Starter, {error, Reason}),
            exit(Reason);
        Else ->
            Error = {bad_return_value, Else},
            proc_lib:init_ack(Starter, {error, Error}),
            exit(Error)
    end.

name({local,Name}) -> Name;
name({global,Name}) -> Name;
name({via,_, Name}) -> Name;
name(Pid) when is_pid(Pid) -> Pid.

unregister_name({local,Name}) ->
    _ = (catch unregister(Name));
unregister_name({global,Name}) ->
    _ = global:unregister_name(Name);
unregister_name({via, Mod, Name}) ->
    _ = Mod:unregister_name(Name);
unregister_name(Pid) when is_pid(Pid) ->
    Pid.

loop(Parent, Name, State, Data, Mod, hibernate, Debug, Next) ->
    proc_lib:hibernate(?MODULE,wake_hib,[Parent, Name, State, Data, Mod, Debug, Next]);
loop(Parent, Name, State, Data, Mod, Time, Debug, [Next|Enqueued]) ->
    decode_msg(Next, Parent, Name, State, Data, Mod, Time, Debug, false, Enqueued);
loop(Parent, Name, State, Data, Mod, Time, Debug, []) ->
    Msg = receive
              Input ->
                    Input
          after Time ->
                  timeout
          end,
    decode_msg(Msg, Parent, Name, State, Data, Mod, Time, Debug, false, []).

decode_msg(Msg, Parent, Name, State, Data, Mod, Time, Debug, Hib, Next) ->
    case Msg of
        {system, From, Req} ->
            sys:handle_system_msg(Req, From, Parent, ?MODULE, Debug,
                                  [Name, State, Data, Mod, Time, Next], Hib);
        {'EXIT', Parent, Reason} ->
            terminate(Reason, Name, Msg, Mod, State, Data, Debug);
        _Msg when Debug =:= [] ->
            handle_msg(Msg, Parent, Name, State, Data, Mod, Next);
        _Msg ->
            Debug1 = sys:handle_debug(Debug, fun print_event/3,
                                      Name, {in, Msg}),
            handle_msg(Msg, Parent, Name, State, Data, Mod, Debug1, Next)
    end.

do_send(Dest, Msg) ->
    case catch erlang:send(Dest, Msg, [noconnect]) of
        noconnect ->
            spawn(erlang, send, [Dest,Msg]);
        Other ->
            Other
    end.


%% ---------------------------------------------------
%% Helper functions for try-catch of callbacks.
%% Returns the return value of the callback, or
%% {'EXIT', ExitReason, ReportReason} (if an exception occurs)
%%
%% ExitReason is the reason that shall be used when the process
%% terminates.
%%
%% ReportReason is the reason that shall be printed in the error
%% report.
%%
%% These functions are introduced in order to add the stack trace in
%% the error report produced when a callback is terminated with
%% erlang:exit/1 (OTP-12263).
%% ---------------------------------------------------

try_dispatch({'$gen_cast', Msg}, Mod, State, Data) ->
    try_dispatch(Mod, handle_cast, Msg, State, Data);
try_dispatch(Info, Mod, State, Data) ->
    try_dispatch(Mod, handle_info, Info, State, Data).

try_dispatch(Mod, Func, Msg, State, Data) ->
    try
        {ok, Mod:Func(Msg, State, Data)}
    catch
        throw:R ->
            {ok, R};
        error:R ->
            Stacktrace = erlang:get_stacktrace(),
            {'EXIT', {R, Stacktrace}, {R, Stacktrace}};
        exit:R ->
            Stacktrace = erlang:get_stacktrace(),
            {'EXIT', R, {R, Stacktrace}}
    end.

try_handle_call(Mod, Msg, From, State, Data) ->
    try
        {ok, Mod:handle_call(Msg, From, State, Data)}
    catch
        throw:R ->
            {ok, R};
        error:R ->
            Stacktrace = erlang:get_stacktrace(),
            {'EXIT', {R, Stacktrace}, {R, Stacktrace}};
        exit:R ->
            Stacktrace = erlang:get_stacktrace(),
            {'EXIT', R, {R, Stacktrace}}
    end.

try_terminate(Mod, Reason, State, Data) ->
    try
        {ok, Mod:terminate(Reason, State, Data)}
    catch
        throw:R ->
            {ok, R};
        error:R ->
            Stacktrace = erlang:get_stacktrace(),
            {'EXIT', {R, Stacktrace}, {R, Stacktrace}};
        exit:R ->
            Stacktrace = erlang:get_stacktrace(),
            {'EXIT', R, {R, Stacktrace}}
    end.


%%% ---------------------------------------------------
%%% Message handling functions
%%% ---------------------------------------------------

handle_msg({'$gen_call', From, Msg}, Parent, Name, State, Data, Mod, Next) ->
    Result = try_handle_call(Mod, Msg, From, State, Data),
    case Result of
        {ok, {reply, Reply, NState, NData}} ->
            reply(From, Reply),
            loop(Parent, Name, NState, NData, Mod, infinity, [], Next);
        {ok, {reply, Reply, NState, NData, Time1}} ->
            reply(From, Reply),
            loop(Parent, Name, NState, NData, Mod, Time1, [], Next);
        {ok, {reply, Reply, NState, NData, Time1, {next, NextList}}} ->
            reply(From, Reply),
            loop(Parent, Name, NState, NData, Mod, Time1, [], Next ++ translate(NextList));
        {ok, {noreply, NState, NData}} ->
            loop(Parent, Name, NState, NData, Mod, infinity, [], Next);
        {ok, {noreply, NState, NData, Time1}} ->
            loop(Parent, Name, NState, NData, Mod, Time1, [], Next);
        {ok, {noreply, NState, NData, Time1, {next, NextList}}} ->
            loop(Parent, Name, NState, NData, Mod, Time1, [], Next ++ translate(NextList));
        {ok, {stop, Reason, Reply, NState, NData}} ->
            {'EXIT', R} = 
                (catch terminate(Reason, Name, Msg, Mod, NState, NData, [])),
            reply(From, Reply),
            exit(R);
        Other -> handle_common_reply(Other, Parent, Name, Msg, Mod, State, Data, Next)
    end;
handle_msg(Msg, Parent, Name, State, Data, Mod, Next) ->
    Reply = try_dispatch(Msg, Mod, State, Data),
    handle_common_reply(Reply, Parent, Name, Msg, Mod, State, Data, Next).

handle_msg({'$gen_call', From, Msg}, Parent, Name, State, Data, Mod, Debug, Next) ->
    Result = try_handle_call(Mod, Msg, From, State, Data),
    case Result of
        {ok, {reply, Reply, NState, NData}} ->
            Debug1 = reply(Name, From, Reply, NState, NData, Debug),
            loop(Parent, Name, NState, NData, Mod, infinity, Debug1, Next);
        {ok, {reply, Reply, NState, NData, Time1}} ->
            Debug1 = reply(Name, From, Reply, NState, NData, Debug),
            loop(Parent, Name, NState, NData, Mod, Time1, Debug1, Next);
        {ok, {reply, Reply, NState, NData, Time1, {next, NextList}}} ->
            Debug1 = reply(Name, From, Reply, NState, NData, Debug),
            loop(Parent, Name, NState, NData, Mod, Time1, Debug1, Next ++ translate(NextList));
        {ok, {noreply, NState, NData}} ->
            Debug1 = sys:handle_debug(Debug, fun print_event/3, Name,
                                      {noreply, NState, NData}),
            loop(Parent, Name, NState, NData, Mod, infinity, Debug1, Next);
        {ok, {noreply, NState, NData, Time1, {next, NextList}}} ->
            Debug1 = sys:handle_debug(Debug, fun print_event/3, Name,
                                      {noreply, NState, NData}),
            loop(Parent, Name, NState, NData, Mod, Time1, Debug1, Next ++ translate(NextList));
        {ok, {stop, Reason, Reply, NState, NData}} ->
            {'EXIT', R} = 
                (catch terminate(Reason, Name, Msg, Mod, NState, NData, Debug)),
            _ = reply(Name, From, Reply, NState, NData, Debug),
            exit(R);
        Other ->
            handle_common_reply(Other, Parent, Name, Msg, Mod, State, Data, Debug, Next)
    end;
handle_msg(Msg, Parent, Name, State, Data, Mod, Debug, Next) ->
    Reply = try_dispatch(Msg, Mod, State, Data),
    handle_common_reply(Reply, Parent, Name, Msg, Mod, State, Data, Debug, Next).

handle_common_reply(Reply, Parent, Name, Msg, Mod, State, Data, Next) ->
    case Reply of
        {ok, {noreply, NState, NData}} ->
            loop(Parent, Name, NState, NData, Mod, infinity, [], Next);
        {ok, {noreply, NState, NData, Time1}} ->
            loop(Parent, Name, NState, NData, Mod, Time1, [], Next);
        {ok, {noreply, NState, NData, Time1, {next, NextList}}} ->
            loop(Parent, Name, NState, NData, Mod, Time1, [], Next ++ translate(NextList));
        {ok, {stop, Reason, NState, NData}} ->
            terminate(Reason, Name, Msg, Mod, NState, NData, [], Next);
        {'EXIT', ExitReason, ReportReason} ->
            terminate(ExitReason, ReportReason, Name, Msg, Mod, State, Data, []);
        {ok, BadReply} ->
            terminate({bad_return_value, BadReply}, Name, Msg, Mod, State, Data, [])
    end.

handle_common_reply(Reply, Parent, Name, Msg, Mod, State, Data, Debug, Next) ->
    case Reply of
        {ok, {noreply, NState, NData}} ->
            Debug1 = sys:handle_debug(Debug, fun print_event/3, Name,
                                      {noreply, NState, NData}),
            loop(Parent, Name, NState, NData, Mod, infinity, Debug1, Next);
        {ok, {noreply, NState, NData, Time1}} ->
            Debug1 = sys:handle_debug(Debug, fun print_event/3, Name,
                                      {noreply, NState, NData}),
            loop(Parent, Name, NState, NData, Mod, Time1, Debug1, Next);
        {ok, {noreply, NState, NData, Time1, {next, NextList}}} ->
            Debug1 = sys:handle_debug(Debug, fun print_event/3, Name,
                                      {noreply, NState, NData}),
            loop(Parent, Name, NState, NData, Mod, Time1, Debug1, Next ++ translate(NextList));
        {ok, {stop, Reason, NState, NData}} ->
            terminate(Reason, Name, Msg, Mod, NState, NData, Debug);
        {'EXIT', ExitReason, ReportReason} ->
            terminate(ExitReason, ReportReason, Name, Msg, Mod, State, Data, Debug);
        {ok, BadReply} ->
            terminate({bad_return_value, BadReply}, Name, Msg, Mod, State, Data, Debug)
    end.

reply(Name, {To, Tag}, Reply, State, Data, Debug) ->
    reply({To, Tag}, Reply),
    sys:handle_debug(Debug, fun print_event/3, Name,
                     {out, Reply, To, State, Data} ).


translate([]) -> [];
translate([{call, Call, From} | T]) -> [{'$gen_call', From, Call} | translate(T)];
translate([{cast, Cast} | T]) -> [{'$gen_cast', Cast} | translate(T)];
translate([{info, Msg} | T]) -> [Msg | translate(T)].

%%-----------------------------------------------------------------
%% Callback functions for system messages handling.
%%-----------------------------------------------------------------
system_continue(Parent, Debug, [Name, State, Data, Mod, Time, Next]) ->
    loop(Parent, Name, State, Data, Mod, Time, Debug, Next).

-spec system_terminate(_, _, _, [_]) -> no_return().

system_terminate(Reason, _Parent, Debug, [Name, State, Data, Mod, _Time]) ->
    terminate(Reason, Name, [], Mod, State, Data, Debug).

system_code_change([Name, State, Data, Mod, Time], _Module, OldVsn, Extra) ->
    case catch Mod:code_change(OldVsn, State, Data, Extra) of
        {ok, NewState, NewData} -> {ok, [Name, NewState, NewData, Mod, Time]};
        Else -> Else
    end.

system_get_state([_Name, State, Data, _Mod, _Time]) ->
    {ok, {State, Data}}.

system_replace_state(StateFun, [Name, StateName, StateData, Mod, Time]) ->
    Result = {NStateName, NStateData} = StateFun({StateName, StateData}),
    {ok, Result, [Name, NStateName, NStateData, Mod, Time]}.

%%-----------------------------------------------------------------
%% Format debug messages.  Print them as the call-back module sees
%% them, not as the real erlang messages.  Use trace for that.
%%-----------------------------------------------------------------
print_event(Dev, {in, Msg}, Name) ->
    case Msg of
        {'$gen_call', {From, _Tag}, Call} ->
            io:format(Dev, "*DBG* ~p got call ~p from ~w~n",
                      [Name, Call, From]);
        {'$gen_cast', Cast} ->
            io:format(Dev, "*DBG* ~p got cast ~p~n",
                      [Name, Cast]);
        _ ->
            io:format(Dev, "*DBG* ~p got ~p~n", [Name, Msg])
    end;
print_event(Dev, {out, Msg, To, State, Data}, Name) ->
    io:format(Dev, "*DBG* ~p sent ~p to ~w, new state ~w, new data ~w~n", 
              [Name, Msg, To, State, Data]);
print_event(Dev, {noreply, State, Data}, Name) ->
    io:format(Dev, "*DBG* ~p new state ~w, new data ~w~n", [Name, State, Data]);
print_event(Dev, Event, Name) ->
    io:format(Dev, "*DBG* ~p dbg  ~p~n", [Name, Event]).


%%% ---------------------------------------------------
%%% Terminate the server.
%%% ---------------------------------------------------

-spec terminate(_, _, _, _, _, _, _) -> no_return().
terminate(Reason, Name, Msg, Mod, State, Data, Debug) ->
    terminate(Reason, Reason, Name, Msg, Mod, State, Data, Debug).

-spec terminate(_, _, _, _, _, _, _, _) -> no_return().
terminate(ExitReason, ReportReason, Name, Msg, Mod, State, Data, Debug) ->
    Reply = try_terminate(Mod, ExitReason, State, Data),
    case Reply of
        {'EXIT', ExitReason1, ReportReason1} ->
            FmtState = format_status(terminate, Mod, get(), State, Data),
            error_info(ReportReason1, Name, Msg, FmtState, Debug),
            exit(ExitReason1);
        _ ->
            case ExitReason of
                normal ->
                    exit(normal);
                shutdown ->
                    exit(shutdown);
                {shutdown,_}=Shutdown ->
                    exit(Shutdown);
                _ ->
                    FmtState = format_status(terminate, Mod, get(), State, Data),
                    error_info(ReportReason, Name, Msg, FmtState, Debug),
                    exit(ExitReason)
            end
    end.

error_info(_Reason, application_controller, _Msg, _State, _Debug) ->
    %% OTP-5811 Don't send an error report if it's the system process
    %% application_controller which is terminating - let init take care
    %% of it instead
    ok;
error_info(Reason, Name, Msg, State, Debug) ->
    Reason1 = 
        case Reason of
            {undef,[{M,F,A,L}|MFAs]} ->
                case code:is_loaded(M) of
                    false ->
                        {'module could not be loaded',[{M,F,A,L}|MFAs]};
                    _ ->
                        case erlang:function_exported(M, F, length(A)) of
                            true ->
                                Reason;
                            false ->
                                {'function not exported',[{M,F,A,L}|MFAs]}
                        end
                end;
            _ ->
                Reason
        end,    
    format("** Generic server ~p terminating \n"
           "** Last message in was ~p~n"
           "** When Server state == ~p~n"
           "** Reason for termination == ~n** ~p~n",
           [Name, Msg, State, Reason1]),
    sys:print_log(Debug),
    ok.

%%% ---------------------------------------------------
%%% Misc. functions.
%%% ---------------------------------------------------

opt(Op, [{Op, Value}|_]) ->
    {ok, Value};
opt(Op, [_|Options]) ->
    opt(Op, Options);
opt(_, []) ->
    false.

debug_options(Name, Opts) ->
    case opt(debug, Opts) of
        {ok, Options} -> dbg_opts(Name, Options);
        _ -> []
    end.

dbg_opts(Name, Opts) ->
    case catch sys:debug_options(Opts) of
        {'EXIT',_} ->
            format("~p: ignoring erroneous debug options - ~p~n",
                   [Name, Opts]),
            [];
        Dbg ->
            Dbg
    end.

%%-----------------------------------------------------------------
%% Status information
%%-----------------------------------------------------------------
format_status(Opt, StatusData) ->
    [PDict, SysState, Parent, Debug, [Name, State, Data, Mod, _Time]] = StatusData,
    Header = gen:format_status_header("Status for generic server", Name),
    Log = sys:get_debug(log, Debug, []),
    Specfic = case format_status(Opt, Mod, PDict, State, Data) of
                  S when is_list(S) -> S;
                  S -> [S]
              end,
    [{header, Header},
     {data, [{"Status", SysState},
             {"Parent", Parent},
             {"Logged events", Log}]} |
     Specfic].

format_status(Opt, Mod, PDict, State, Data) ->
    DefStatus = case Opt of
                    terminate -> State;
                    _ -> [{data, [{"State", State, Data}]}]
                end,
    case erlang:function_exported(Mod, format_status, 2) of
        true ->
            case catch Mod:format_status(Opt, [PDict, State, Data]) of
                {'EXIT', _} -> DefStatus;
                Else -> Else
            end;
        _ ->
            DefStatus
    end.
