%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <potatosaladx@gmail.com>
%%% @copyright 2014, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  07 Nov 2014 by Andrew Bennett <potatosaladx@gmail.com>
%%%-------------------------------------------------------------------
-module(lftpc_sock).
-behaviour(gen_server).

%% API
-export([call/2]).
-export([call/3]).
-export([close/1]).
-export([connect/3]).
-export([connect/4]).
-export([controlling_process/2]).
-export([done/1]).
-export([getopts/2]).
-export([open/1]).
-export([peername/1]).
-export([send/2]).
-export([sendfile/2]).
-export([sendfile/4]).
-export([sendfile/5]).
-export([setopts/2]).
-export([sockname/1]).
-export([start_request/1]).

%% Internal API
-export([start_link/5]).

%% gen_server callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

%% Records
-record(state, {
	owner  = undefined :: undefined | pid(),
	socket = undefined :: undefined | lftpc_prim:socket(),
	req    = undefined :: undefined | {term(), pid()},
	die    = undefined :: undefined | term(),
	% Buffers
	rcvbuf = undefined :: undefined | queue:queue(term()),
	% Options
	active    = undefined :: undefined | false | once | true,
	keepalive = false     :: true | timeout(),
	kref      = undefined :: undefined | reference(),
	open      = passive   :: passive | active
}).

%% Types
-type socket() :: pid().
-export_type([socket/0]).

%% Macros
-define(KEEPALIVE, 30000). %% timer:seconds(30).

-define(CALL(Socket, Request, Error),
	try
		gen_server:call(Socket, Request, infinity)
	catch
		exit:{noproc, _} ->
			Error
	end).

-define(CALL(Socket, Request), ?CALL(Socket, Request, {error, einval})).

%%%===================================================================
%%% API functions
%%%===================================================================

call(Socket, Command) ->
	?CALL(Socket, {call, Command}).

call(Socket, Command, Argument) ->
	?CALL(Socket, {call, Command, Argument}).

-spec close(Socket) -> ok
	when
		Socket :: socket().
close(Socket) ->
	ok = ?CALL(Socket, close, ok),
	receive
		{ftp_closed, Socket} ->
			ok
	after
		0 ->
			ok
	end.

connect(Address, Port, Options) ->
	connect(Address, Port, Options, infinity).

connect(Address, Port, Options, Timeout) ->
	start_link(self(), Address, Port, Options, Timeout).

controlling_process(Socket, NewOwner) ->
	case erlang:is_process_alive(Socket) of
		false ->
			{error, einval};
		true ->
			case getopts(Socket, [active, owner]) of
				{ok, [_, {owner, NewOwner}]} ->
					ok;
				{ok, [_, {owner, Owner}]} when Owner =/= self() ->
					{error, not_owner};
				{ok, [{active, OldActive}, {owner, Owner}]} when Owner =:= self() ->
					ok = setopts(Socket, [{active, false}]),
					case sync_input(Socket, NewOwner, false) of
						true ->
							ok;
						false ->
							try setopts(Socket, [{active, OldActive}, {owner, NewOwner}]) of
								ok ->
									erlang:unlink(Socket),
									ok;
								{error, Reason} ->
									{error, Reason}
							catch
								error:Reason ->
									{error, Reason}
							end
					end;
				Error ->
					Error
			end
	end.

done(Socket) ->
	?CALL(Socket, done).

getopts(Socket, Options) ->
	?CALL(Socket, {getopts, Options}).

open(Socket) ->
	?CALL(Socket, open).

peername(Socket) ->
	?CALL(Socket, peername).

send(Socket, Packet) ->
	?CALL(Socket, {send, Packet}).

sendfile(Socket, Filename) ->
	?CALL(Socket, {sendfile, Filename}).

sendfile(Socket, Filename, Offset, Bytes) ->
	?CALL(Socket, {sendfile, Filename, Offset, Bytes}).

sendfile(Socket, Filename, Offset, Bytes, Opts) ->
	?CALL(Socket, {sendfile, Filename, Offset, Bytes, Opts}).

setopts(Socket, Options) ->
	?CALL(Socket, {setopts, Options}).

sockname(Socket) ->
	?CALL(Socket, sockname).

start_request(Socket) ->
	?CALL(Socket, start_request).

%%%===================================================================
%%% Internal API functions
%%%===================================================================

%% @private
start_link(Owner, Address, Port, Options, Timeout) ->
	proc_lib:start_link(?MODULE, init, [{Owner, Address, Port, Options, Timeout}]).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
init({Owner, Address, Port, Options, Timeout}) ->
	process_flag(trap_exit, true),
	true = erlang:link(Owner),
	Active = get_value(active, Options, false),
	Keepalive = get_value(keepalive, Options, false),
	Open = get_value(open, Options, passive),
	Rcvbuf = queue:new(),
	case lftpc_prim:connect(Address, Port, Options, Timeout) of
		{ok, Socket} ->
			ok = proc_lib:init_ack({ok, self()}),
			State = #state{owner=Owner, socket=Socket, active=Active,
				open=Open, keepalive=Keepalive, rcvbuf=Rcvbuf},
			gen_server:enter_loop(?MODULE, [], keepalive_start(State));
		ConnectError ->
			ok = proc_lib:init_ack(ConnectError),
			exit(normal)
	end.

%% @private
handle_call(start_request, {Owner, _}, State=#state{owner=Owner, req=undefined, socket=Socket}) ->
	catch lftpc_prim:setopts(Socket, [{active, false}]),
	case process_remaining(State) of
		{noreply, NewState} ->
			ReqId = erlang:now(),
			case lftpc_client:start_request(ReqId, Socket, Owner) of
				{ok, Pid} ->
					case lftpc_prim:controlling_process(Socket, Pid) of
						ok ->
							{reply, {ok, {ReqId, Pid}}, NewState#state{req={ReqId, Pid}}};
						ControlError ->
							erlang:monitor(process, Pid),
							erlang:unlink(Pid),
							erlang:kill(Pid, kill),
							ok = receive
								{'DOWN', _, process, Pid, _} ->
									ok
							end,
							{reply, ControlError, NewState}
					end;
				RequestError ->
					{reply, RequestError, NewState}
			end;
		Stop ->
			Stop
	end;
handle_call(_Request, {Owner, _}, State=#state{owner=Owner, req=Req})
		when Req =/= undefined ->
	{reply, {error, {request_in_progress}}, State};
handle_call({call, Command}, {Owner, _}, State=#state{owner=Owner, socket=Socket}) ->
	Reply = lftpc_prim:call(Socket, Command),
	{reply, Reply, keepalive_stop(State)};
handle_call({call, Command, Argument}, {Owner, _}, State=#state{owner=Owner, socket=Socket}) ->
	Reply = lftpc_prim:call(Socket, Command, Argument),
	{reply, Reply, keepalive_stop(State)};
handle_call(close, {Owner, _}, State=#state{owner=Owner, socket=Socket}) ->
	Reply = lftpc_prim:close(Socket),
	{reply, Reply, State};
handle_call(done, {Owner, _}, State=#state{owner=Owner, socket=Socket}) ->
	Reply = lftpc_prim:done(Socket),
	{reply, Reply, State};
handle_call({getopts, Options}, {Owner, _}, State=#state{owner=Owner}) ->
	{Reply, NewState} = options_get(Options, State),
	{reply, Reply, NewState};
handle_call(open, {Owner, _}, State=#state{owner=Owner, open=active}) ->
	Reply = {ok, <<"PORT">>},
	{reply, Reply, State};
handle_call(open, {Owner, _}, State=#state{owner=Owner, open=passive}) ->
	Reply = {ok, <<"PASV">>},
	{reply, Reply, State};
handle_call(open, {Owner, _}, State=#state{owner=Owner, open=extended_active}) ->
	Reply = {ok, <<"EPRT">>},
	{reply, Reply, State};
handle_call(open, {Owner, _}, State=#state{owner=Owner, open=extended_passive}) ->
	Reply = {ok, <<"EPSV">>},
	{reply, Reply, State};
handle_call(peername, {Owner, _}, State=#state{owner=Owner, socket=Socket}) ->
	Reply = lftpc_prim:peername(Socket),
	{reply, Reply, State};
handle_call({send, Packet}, {Owner, _}, State=#state{owner=Owner, socket=Socket}) ->
	Reply = lftpc_prim:send(Socket, Packet),
	{reply, Reply, State};
handle_call({sendfile, Filename}, {Owner, _}, State=#state{owner=Owner, socket=Socket}) ->
	Reply = lftpc_prim:sendfile(Socket, Filename),
	{reply, Reply, State};
handle_call({sendfile, Filename, Offset, Bytes}, {Owner, _}, State=#state{owner=Owner, socket=Socket}) ->
	Reply = lftpc_prim:sendfile(Socket, Filename, Offset, Bytes),
	{reply, Reply, State};
handle_call({sendfile, Filename, Offset, Bytes, Opts}, {Owner, _}, State=#state{owner=Owner, socket=Socket}) ->
	Reply = lftpc_prim:sendfile(Socket, Filename, Offset, Bytes, Opts),
	{reply, Reply, State};
handle_call({setopts, Options}, {Owner, _}, State=#state{owner=Owner}) ->
	{Reply, NewState} = options_set(Options, State),
	{reply, Reply, NewState};
handle_call(sockname, {Owner, _}, State=#state{owner=Owner, socket=Socket}) ->
	Reply = lftpc_prim:sockname(Socket),
	{reply, Reply, State};
handle_call(_Request, _From, State) ->
	{reply, {error, not_owner}, State}.

%% @private
handle_cast(_Request, State) ->
	{noreply, State}.

%% @private
handle_info({ftp, Socket, Message}, State=#state{socket=Socket}) ->
	NewState = owner_send(State, {ftp, self(), Message}),
	case Message of
		{_, done} ->
			{noreply, keepalive_start(NewState)};
		_ ->
			{noreply, NewState}
	end;
handle_info({ftp_closed, Socket}, State=#state{socket=Socket}) ->
	NewState = owner_send(State, {ftp_closed, self()}),
	{noreply, NewState};
handle_info({ftp_error, Socket, Reason}, State=#state{socket=Socket}) ->
	NewState = owner_send(State, {ftp_error, self(), Reason}),
	{noreply, NewState};
handle_info({'EXIT', Socket, Reason}, State=#state{socket=Socket, req=undefined}) ->
	{stop, Reason, State};
handle_info({'EXIT', Socket, Reason}, State=#state{socket=Socket}) ->
	{noreply, State#state{die=Reason}};
handle_info({'EXIT', Owner, _Reason}, State=#state{owner=Owner}) ->
	{stop, normal, State};
handle_info({response, ReqId, Pid, Socket}, State=#state{req={ReqId, Pid}, socket=Socket, active=Active}) ->
	erlang:monitor(process, Pid),
	erlang:unlink(Pid),
	ok = receive
		{'DOWN', _, process, Pid, _} ->
			ok
	end,
	catch lftpc_prim:setopts(Socket, [{active, Active}]),
	case State#state.die of
		undefined ->
			{noreply, keepalive_start(State#state{req=undefined})};
		Reason ->
			{stop, Reason, State}
	end;
handle_info({timeout, KRef, keepalive}, State=#state{kref=KRef, req=undefined, socket=Socket})
		when is_reference(KRef) ->
	case lftpc_prim:call(Socket, <<"NOOP">>) of
		{ok, CRef} ->
			{noreply, keepalive_check(CRef, State#state{kref=undefined})}
	end;
handle_info({timeout, KRef, keepalive}, State=#state{kref=KRef})
		when is_reference(KRef) ->
	{noreply, keepalive_stop(State)};
handle_info(Info, State) ->
	error_logger:error_msg(
		"** ~p ~p unhandled info in ~p/~p~n"
		"   Info was: ~p ~p~n",
		[?MODULE, self(), handle_info, 2, Info, State]),
	{noreply, State}.

%% @private
terminate(_Reason, _State) ->
	ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%%-------------------------------------------------------------------
%%% Owner functions
%%%-------------------------------------------------------------------

%% @private
owner_flush(State=#state{rcvbuf={[],[]}}) ->
	State;
owner_flush(State=#state{active=once, owner=Owner, rcvbuf=Rcvbuf}) ->
	{{value, Message}, NewRcvbuf} = queue:out(Rcvbuf),
	Owner ! Message,
	State#state{active=false, rcvbuf=NewRcvbuf};
owner_flush(State=#state{active=true, owner=Owner, rcvbuf=Rcvbuf}) ->
	{{value, Message}, NewRcvbuf} = queue:out(Rcvbuf),
	Owner ! Message,
	owner_flush(State#state{rcvbuf=NewRcvbuf});
owner_flush(State) ->
	State.

%% @private
owner_send(State=#state{active=once, owner=Owner}, Message) ->
	Owner ! Message,
	State#state{active=false};
owner_send(State=#state{active=true, owner=Owner}, Message) ->
	Owner ! Message,
	State;
owner_send(State=#state{active=false, rcvbuf=Rcvbuf}, Message) ->
	State#state{rcvbuf=queue:in(Message, Rcvbuf)}.

%%%-------------------------------------------------------------------
%%% Options functions
%%%-------------------------------------------------------------------

%% @private
options_get(Options, State) ->
	options_get(Options, [], State).

%% @private
options_get([active | Options], Acc, State=#state{active=Active}) ->
	options_get(Options, [{active, Active} | Acc], State);
options_get([keepalive | Options], Acc, State=#state{keepalive=Keepalive}) ->
	options_get(Options, [{keepalive, Keepalive} | Acc], State);
options_get([open | Options], Acc, State=#state{open=Open}) ->
	options_get(Options, [{open, Open} | Acc], State);
options_get([owner | Options], Acc, State=#state{owner=Owner}) ->
	options_get(Options, [{owner, Owner} | Acc], State);
options_get([Key | Options], Acc, State=#state{socket=Socket}) ->
	case lftpc_prim:getopts(Socket, [Key]) of
		{ok, [{Key, Val}]} ->
			options_get(Options, [{Key, Val} | Acc], State);
		Error ->
			{Error, State}
	end;
options_get([], Acc, State) ->
	{{ok, lists:reverse(Acc)}, State}.

%% @private
options_set([{active, Active} | Options], State=#state{socket=Socket})
		when Active =:= false
		orelse Active =:= once
		orelse Active =:= true ->
	case lftpc_prim:setopts(Socket, [{active, Active}]) of
		ok ->
			NewState = options_set_active(Active, State),
			options_set(Options, NewState);
		Error ->
			{Error, State}
	end;
options_set([{keepalive, Keepalive} | Options], State)
		when Keepalive =:= false
		orelse Keepalive =:= true
		orelse (is_integer(Keepalive) andalso Keepalive >= 0) ->
	options_set(Options, keepalive_start(State#state{keepalive=Keepalive}));
options_set([{open, Open} | Options], State)
		when Open =:= active
		orelse Open =:= passive
		orelse Open =:= extended_active
		orelse Open =:= extended_passive ->
	options_set(Options, State#state{open=Open});
options_set([{owner, NewOwner} | Options], State=#state{owner=OldOwner}) ->
	erlang:unlink(OldOwner),
	erlang:link(NewOwner),
	options_set(Options, State#state{owner=NewOwner});
options_set([{Key, Val} | Options], State=#state{socket=Socket}) ->
	case lftpc_prim:setopts(Socket, [{Key, Val}]) of
		ok ->
			options_set(Options, State);
		Error ->
			{Error, State}
	end;
options_set([], State) ->
	{ok, State}.

%% @private
options_set_active(Active, State=#state{active=Active}) ->
	State;
options_set_active(Active, State=#state{active=false}) ->
	owner_flush(State#state{active=Active});
options_set_active(Active, State) ->
	State#state{active=Active}.

%%%-------------------------------------------------------------------
%%% Keepalive functions
%%%-------------------------------------------------------------------

%% @private
keepalive_check(CRef, State=#state{keepalive=Keepalive, socket=Socket, active=Active}) ->
	lftpc_prim:setopts(Socket, [{active, once}]),
	receive
		{ftp, Socket, {CRef, {Code, _}}} when Code >= 100 andalso Code < 200 ->
			keepalive_check(CRef, State);
		{ftp, Socket, {CRef, {Code, _}}} when Code >= 200 ->
			keepalive_check(CRef, State);
		{ftp, Socket, {CRef, done}} ->
			lftpc_prim:setopts(Socket, [{active, Active}]),
			keepalive_start(State);
		M={ftp, Socket, _Message} ->
			{noreply, NewState} = handle_info(M, State#state{keepalive=undefined}),
			keepalive_check(CRef, NewState#state{keepalive=Keepalive});
		M={ftp_closed, Socket} ->
			lftpc_prim:setopts(Socket, [{active, Active}]),
			{noreply, NewState} = handle_info(M, State),
			NewState;
		M={ftp_error, Socket, _Reason} ->
			lftpc_prim:setopts(Socket, [{active, Active}]),
			{noreply, NewState} = handle_info(M, State),
			NewState
	end.

%% @private
keepalive_flush(KRef) ->
	receive
		{timeout, KRef, keepalive} ->
			keepalive_flush(KRef)
	after
		0 ->
			ok
	end.

%% @private
keepalive_start(State=#state{keepalive=Keepalive, kref=undefined}) when is_integer(Keepalive) ->
	KRef = erlang:start_timer(Keepalive, self(), keepalive),
	State#state{kref=KRef};
keepalive_start(State=#state{keepalive=true, kref=undefined}) ->
	KRef = erlang:start_timer(?KEEPALIVE, self(), keepalive),
	State#state{kref=KRef};
keepalive_start(State=#state{kref=undefined}) ->
	State;
keepalive_start(State) ->
	keepalive_start(keepalive_stop(State)).

%% @private
keepalive_stop(State=#state{kref=undefined}) ->
	State;
keepalive_stop(State=#state{kref=KRef}) ->
	catch erlang:cancel_timer(KRef),
	ok = keepalive_flush(KRef),
	State#state{kref=undefined}.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% Faster alternative to proplists:get_value/3.
%% @private
get_value(Key, Opts, Default) ->
	case lists:keyfind(Key, 1, Opts) of
		{_, Value} -> Value;
		_ -> Default
	end.

%% @private
process_remaining(State=#state{socket=Socket}) ->
	Result = receive
		M={ftp, Socket, _Message} ->
			handle_info(M, State);
		M={ftp_closed, Socket} ->
			handle_info(M, State);
		M={ftp_error, Socket, _Reason} ->
			handle_info(M, State);
		M={'EXIT', Socket, _Reason} ->
			handle_info(M, State)
	after
		0 ->
			State
	end,
	case Result of
		State ->
			{noreply, State};
		{noreply, NewState} ->
			process_remaining(NewState);
		{stop, Reason, NewState} ->
			{stop, Reason, {error, closed}, NewState}
	end.

%% @private
sync_input(Socket, Owner, Flag) ->
	receive
		M={ftp, Socket, _Message} ->
			Owner ! M,
			sync_input(Socket, Owner, Flag);
		M={ftp_closed, Socket} ->
			Owner ! M,
			sync_input(Socket, Owner, true);
		M={ftp_error, Socket, _Reason} ->
			Owner ! M,
			sync_input(Socket, Owner, Flag)
	after
		0 ->
			Flag
	end.
