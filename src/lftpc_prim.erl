%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <andrew@pixid.com>
%%% @copyright 2014, Andrew Bennett
%%% @doc user-FTP process
%%%
%%% @end
%%% Created :  31 Oct 2014 by Andrew Bennett <andrew@pixid.com>
%%%-------------------------------------------------------------------
-module(lftpc_prim).

-include("lftpc_prim.hrl").

%% API
-export([call/2]).
-export([call/3]).
-export([close/1]).
-export([connect/3]).
-export([connect/4]).
-export([controlling_process/2]).
-export([done/1]).
-export([getopts/2]).
-export([peername/1]).
-export([send/2]).
-export([sendfile/2]).
-export([sendfile/4]).
-export([sendfile/5]).
-export([setopts/2]).
-export([sockname/1]).

%% Internal API
-export([start_link/5]).
-export([init/5]).

%% Internal States
-export([connecting/1]).
-export([ready_wait/1]).
-export([idle/1]).
-export([idle_opening/1]).
-export([idle_transfer/1]).
-export([reply_wait/1]).
-export([reply_wait_opening/1]).
-export([reply_wait_transfer/1]).
-export([opening/1]).
-export([transfer/1]).
-export([closed/1]).

%% sys callbacks
-export([system_continue/3]).
-export([system_terminate/4]).
-export([system_code_change/4]).
-export([system_get_state/1]).
-export([system_replace_state/2]).

-record(state_data, {
	owner   = undefined :: undefined | pid(),
	host    = undefined :: undefined | inet:hostname()| inet:ip_address(),
	port    = undefined :: undefined | inet:port_number(),
	options = undefined :: undefined | [{atom(), term()}],
	timeout = undefined :: undefined | infinity | timeout(),
	% Control
	ctrl       = undefined :: undefined | pid(),
	cbuffer    = <<>>      :: binary(),
	cdecode    = undefined :: undefined | lftpc_protocol:decoder(),
	cmessages  = undefined :: undefined | {atom(), atom(), atom()},
	cref       = undefined :: undefined | reference(),
	creq       = undefined :: undefined | iodata(),
	csocket    = undefined :: undefined | inet:socket(),
	ctls       = false     :: false | explicit | implicit,
	ctransport = undefined :: undefined | module(),
	cwait      = undefined :: undefined | queue:queue({{pid(), reference()}, {ctrl, iodata()}}),
	% Data
	data       = undefined :: undefined | pid(),
	dbuffer    = <<>>      :: binary(),
	ddecode    = undefined :: undefined | any(),
	ddone      = undefined :: undefined | immediate,
	dmessages  = undefined :: undefined | {atom(), atom(), atom()},
	dopen      = undefined :: undefined | term(),
	dref       = undefined :: undefined | reference(),
	dsocket    = undefined :: undefined | inet:socket(),
	dtls       = false     :: false | explicit,
	dtransport = undefined :: undefined | module(),
	% Options
	active = undefined :: undefined | false | once | true,
	rcvbuf = undefined :: undefined | queue:queue(term()),
	sndbuf = undefined :: undefined | queue:queue(iodata())
}).

%% Types
-type socket() :: pid().
-export_type([socket/0]).

%% Macros
-define(PAUSE, 250).

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

-spec call(Socket, Command) -> {ok, CallRef} | {error, Reason}
	when
		Socket  :: socket(),
		Command :: binary(),
		CallRef :: reference(),
		Reason  :: now_owner | einval.
call(Socket, Command) ->
	?CALL(Socket, {ctrl, [Command]}).

-spec call(Socket, Command, Argument) -> {ok, CallRef} | {error, Reason}
	when
		Socket   :: socket(),
		Command  :: binary(),
		Argument :: iodata(),
		CallRef  :: reference(),
		Reason   :: now_owner | einval.
call(Socket, Command, Argument) ->
	?CALL(Socket, {ctrl, [Command, Argument]}).

-spec close(Socket) -> ok
	when Socket :: socket().
close(Socket) ->
	ok = ?CALL(Socket, close, ok),
	receive
		{ftp_closed, Socket} ->
			ok
	after
		0 ->
			ok
	end.

connect(Host, Port, Options) ->
	connect(Host, Port, Options, infinity).

connect(Host, Port, Options, Timeout) ->
	start_link(self(), Host, Port, Options, Timeout).

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

peername(Socket) ->
	?CALL(Socket, peername).

send(Socket, Packet) ->
	?CALL(Socket, {send, Packet}).

sendfile(Socket, Filename) ->
	sendfile(Socket, Filename, 0, 0, []).

sendfile(Socket, Filename, Offset, Bytes) ->
	sendfile(Socket, Filename, Offset, Bytes, []).

sendfile(Socket, Filename, Offset, Bytes, Opts)
		when is_list(Filename) orelse is_atom(Filename)
		orelse is_binary(Filename) ->
	?CALL(Socket, {sendfile, Filename, Offset, Bytes, Opts}).

setopts(Socket, Options) ->
	?CALL(Socket, {setopts, Options}).

sockname(Socket) ->
	?CALL(Socket, sockname).

%%%===================================================================
%%% Internal API functions
%%%===================================================================

%% @private
start_link(Owner, Host, Port, Options, Timeout) ->
	proc_lib:start_link(?MODULE, init, [Owner, Host, Port, Options, Timeout]).

%% @private
init(Owner, Host, Port, Options, Timeout) ->
	process_flag(trap_exit, true),
	ok = proc_lib:init_ack(Owner, {ok, self()}),
	true = erlang:link(Owner),
	CDecode = lftpc_protocol:new_decoder(),
	CWait = queue:new(),
	Active = get_value(active, Options, false),
	CTLS = get_value(tls, Options, false),
	Rcvbuf = queue:new(),
	Sndbuf = queue:new(),
	SD = #state_data{owner=Owner, host=Host, port=Port,
		options=Options, timeout=Timeout, cdecode=CDecode,
		ctls=CTLS, cwait=CWait, active=Active, rcvbuf=Rcvbuf,
		sndbuf=Sndbuf},
	ctrl_start(SD).

%% @private
before_loop(SD0=#state_data{dref=OldDRef}, SN)
		when is_reference(OldDRef) ->
	catch erlang:cancel_timer(OldDRef),
	ok = receive
		{timeout, OldDRef, data} ->
			ok
	after
		0 ->
			ok
	end,
	SD1 = SD0#state_data{dref=undefined},
	before_loop(SD1, SN);
before_loop(SD0=#state_data{cwait=CWait0}, SN)
		when SN =:= idle
		orelse SN =:= idle_opening
		orelse SN =:= idle_transfer ->
	case queue:out(CWait0) of
		{{value, {From, Request}}, CWait1} ->
			SD1 = SD0#state_data{cwait=CWait1},
			handle(SD1, SN, From, Request);
		{empty, CWait0} ->
			?MODULE:SN(SD0)
	end;
before_loop(SD0, SN)
		when SN =:= opening
		orelse SN =:= transfer ->
	DRef = erlang:start_timer(?PAUSE, self(), data),
	SD1 = SD0#state_data{dref=DRef},
	?MODULE:SN(SD1);
before_loop(SD, SN) ->
	?MODULE:SN(SD).

%% @private
handle(SD0, SN, {To, Tag}, {send, Packet})
		when SN =:= reply_wait_transfer
		orelse SN =:= transfer ->
	SD1 = data_send(SD0, Packet),
	To ! {Tag, ok},
	?MODULE:SN(SD1);
handle(SD0, SN, {To, Tag}, {send, Packet})
		when SN =:= reply_wait_opening
		orelse SN =:= opening ->
	SD1 = data_send(SD0, Packet),
	To ! {Tag, ok},
	?MODULE:SN(SD1);
handle(SD, SN, {To, Tag}, {send, _})
		when SN =/= closed ->
	To ! {Tag, {error, nodata}},
	?MODULE:SN(SD);
handle(SD0, SN, {To, Tag}, {sendfile, Filename, Offset, Bytes, Opts})
		when SN =:= reply_wait_transfer
		orelse SN =:= transfer ->
	SD1 = data_sendfile(SD0, Filename, Offset, Bytes, Opts),
	To ! {Tag, ok},
	?MODULE:SN(SD1);
handle(SD0, SN, {To, Tag}, {sendfile, Filename, Offset, Bytes, Opts})
		when SN =:= reply_wait_opening
		orelse SN =:= opening ->
	SD1 = data_sendfile(SD0, Filename, Offset, Bytes, Opts),
	To ! {Tag, ok},
	?MODULE:SN(SD1);
handle(SD, SN, {To, Tag}, {sendfile, _, _, _, _}) ->
	To ! {Tag, {error, nodata}},
	?MODULE:SN(SD);
handle(SD0, reply_wait_transfer, {To, Tag}, done) ->
	SD1 = data_send_flush(SD0),
	SD2 = data_clean(SD1),
	To ! {Tag, ok},
	before_loop(SD2, reply_wait);
handle(SD0, transfer, {To, Tag}, done) ->
	SD1 = data_send_flush(SD0),
	SD2 = data_clean(SD1),
	To ! {Tag, ok},
	before_loop(SD2, idle);
handle(SD0, SN, {To, Tag}, done)
		when SN =:= reply_wait_opening
		orelse SN =:= opening ->
	SD1 = SD0#state_data{ddone=immediate},
	To ! {Tag, ok},
	?MODULE:SN(SD1);
handle(SD, SN, {To, Tag}, done)
		when SN =/= closed ->
	To ! {Tag, {error, nodata}},
	?MODULE:SN(SD);
handle(SD0, SN0, {To, Tag}, {ctrl, [Command | Argument]})
		when SN0 =:= idle
		orelse SN0 =:= idle_opening
		orelse SN0 =:= idle_transfer ->
	Head = ?INLINE_UPPERCASE_BC(Command),
	{SD1, SN1, Tail} = ctrl_prep(SD0, SN0, Head, Argument),
	SD2 = ctrl_send(SD1, [Head | Tail]),
	CRef = make_ref(),
	To ! {Tag, {ok, CRef}},
	SD3 = SD2#state_data{cref=CRef},
	case SN1 of
		idle ->
			?MODULE:reply_wait(SD3);
		idle_opening ->
			?MODULE:reply_wait_opening(SD3);
		idle_transfer ->
			?MODULE:reply_wait_transfer(SD3)
	end;
handle(SD0=#state_data{cwait=CWait0}, SN, From, R={ctrl, _})
		when SN =/= closed ->
	CWait1 = queue:in({From, R}, CWait0),
	SD1 = SD0#state_data{cwait=CWait1},
	?MODULE:SN(SD1);
handle(SD0, SN, From, {getopts, Options}) ->
	SD1 = options_get(SD0, From, Options),
	?MODULE:SN(SD1);
handle(SD0, SN, From, {setopts, Options}) ->
	SD1 = options_set(SD0, From, Options),
	?MODULE:SN(SD1);
handle(SD0=#state_data{cwait=CWait0}, connecting, From, R)
		when R =:= peername
		orelse R =:= sockname ->
	CWait1 = queue:in({From, R}, CWait0),
	SD1 = SD0#state_data{cwait=CWait1},
	?MODULE:connecting(SD1);
handle(SD=#state_data{csocket=CSocket, ctransport=CTransport}, SN, {To, Tag}, peername)
		when SN =/= closed ->
	Reply = CTransport:peername(CSocket),
	To ! {Tag, Reply},
	before_loop(SD, SN);
handle(SD=#state_data{csocket=CSocket, ctransport=CTransport}, SN, {To, Tag}, sockname)
		when SN =/= closed ->
	Reply = CTransport:sockname(CSocket),
	To ! {Tag, Reply},
	before_loop(SD, SN);
handle(SD0, SN, {To, Tag}, close) ->
	SD1 = data_clean(SD0),
	SD2 = ctrl_close(SD1),
	To ! {Tag, ok},
	terminate(SD2, SN, normal);
handle(SD, closed, {To, Tag}, _) ->
	Reply = {error, closed},
	To ! {Tag, Reply},
	?MODULE:closed(SD).

%% @private
shutdown(SD0, SN, Reason) ->
	SD1 = SD0#state_data{active=false},
	SD2 = data_clean(SD1),
	SD3 = ctrl_close(SD2),
	terminate(SD3, SN, Reason).

%% @private
terminate(_SD, _SN, Reason) ->
	exit(Reason).

%%%===================================================================
%%% Internal States functions
%%%===================================================================

%% @private
connecting(SD0=#state_data{owner=Owner, ctrl=Ctrl}) ->
	% io:format("connecting~n"),
	receive
		{socket, Ctrl, CTransport, CSocket, CRef} ->
			Ctrl ! CRef,
			ok = receive
				{'EXIT', Ctrl, _} ->
					ok
			end,
			CMessages = CTransport:messages(),
			SD1 = SD0#state_data{ctrl=undefined, cmessages=CMessages,
				csocket=CSocket, ctransport=CTransport},
			SD2 = ctrl_active(SD1),
			before_loop(SD2, ready_wait);
		{socket_error, Ctrl, CReason, CRef} ->
			Ctrl ! CRef,
			ok = receive
				{'EXIT', Ctrl, _} ->
					ok
			end,
			SD1 = owner_send(SD0, {ftp_error, self(), {SD0#state_data.cref, CReason}}),
			SD2 = ctrl_close(SD1),
			before_loop(SD2, closed);
			% terminate(SD2, connecting, normal);
		{'$gen_call', From={Owner, _}, Request} ->
			handle(SD0, connecting, From, Request);
		{'$gen_call', {To, Tag}, _} ->
			To ! {Tag, {error, not_owner}},
			connecting(SD0);
		{'EXIT', Owner, _Reason} ->
			shutdown(SD0, connecting, normal);
		{system, From, Request} ->
			sys:handle_system_msg(Request, From, Owner, ?MODULE, [], {connecting, SD0});
		Info ->
			error_logger:error_msg(
				"FTP client ~p received unexpected message ~p in state ~p~n",
				[self(), Info, connecting])
	end.

%% @private
ready_wait(SD0=#state_data{owner=Owner, cmessages={COK, CClosed, CError}, csocket=CSocket}) ->
	% io:format("ready_wait~n"),
	receive
		{COK, CSocket, CData} ->
			ctrl_parse(SD0, ready_wait, CData);
		{CClosed, CSocket} ->
			SD1 = ctrl_close(SD0),
			before_loop(SD1, closed);
			% terminate(SD1, ready_wait, normal);
		{CError, CSocket, CReason} ->
			SD1 = owner_send(SD0, {ftp_error, self(), {SD0#state_data.cref, CReason}}),
			SD2 = ctrl_close(SD1),
			before_loop(SD2, closed);
			% terminate(SD2, ready_wait, normal);
		{'$gen_call', From={Owner, _}, Request} ->
			handle(SD0, ready_wait, From, Request);
		{'$gen_call', {To, Tag}, _} ->
			To ! {Tag, {error, not_owner}},
			ready_wait(SD0);
		{'EXIT', Owner, _Reason} ->
			shutdown(SD0, ready_wait, normal);
		{system, From, Request} ->
			sys:handle_system_msg(Request, From, Owner, ?MODULE, [], {ready_wait, SD0});
		Info ->
			error_logger:error_msg(
				"FTP client ~p received unexpected message ~p in state ~p~n",
				[self(), Info, ready_wait])
	end.

%% @private
idle(SD0=#state_data{owner=Owner, cmessages={COK, CClosed, CError}, csocket=CSocket}) ->
	% io:format("idle~n"),
	receive
		{COK, CSocket, CData} ->
			ctrl_parse(SD0, idle, CData);
		{CClosed, CSocket} ->
			SD1 = ctrl_close(SD0),
			before_loop(SD1, closed);
			% terminate(SD1, idle, normal);
		{CError, CSocket, CReason} ->
			SD1 = owner_send(SD0, {ftp_error, self(), {SD0#state_data.cref, CReason}}),
			SD2 = ctrl_close(SD1),
			before_loop(SD2, closed);
			% terminate(SD2, idle, normal);
		{'$gen_call', From={Owner, _}, Request} ->
			handle(SD0, idle, From, Request);
		{'$gen_call', {To, Tag}, _} ->
			To ! {Tag, {error, not_owner}},
			idle(SD0);
		{'EXIT', Owner, _Reason} ->
			shutdown(SD0, idle, normal);
		{system, From, Request} ->
			sys:handle_system_msg(Request, From, Owner, ?MODULE, [], {idle, SD0});
		Info ->
			error_logger:error_msg(
				"FTP client ~p received unexpected message ~p in state ~p~n",
				[self(), Info, idle])
	end.

%% @private
idle_opening(SD0=#state_data{owner=Owner, cmessages={COK, CClosed, CError}, csocket=CSocket, data=Data}) ->
	% io:format("idle_opening~n"),
	receive
		{COK, CSocket, CData} ->
			ctrl_parse(SD0, idle_opening, CData);
		{CClosed, CSocket} ->
			SD1 = ctrl_close(SD0),
			before_loop(SD1, closed);
			% terminate(SD1, idle_opening, normal);
		{CError, CSocket, CReason} ->
			SD1 = owner_send(SD0, {ftp_error, self(), {SD0#state_data.cref, CReason}}),
			SD2 = ctrl_close(SD1),
			before_loop(SD2, closed);
			% terminate(SD2, idle_opening, normal);
		{socket, Data, DTransport, DSocket, DSocketRef} ->
			Data ! DSocketRef,
			ok = receive
				{'EXIT', Data, _} ->
					ok
			end,
			DMessages = DTransport:messages(),
			SD1 = SD0#state_data{data=undefined, dmessages=DMessages,
				dsocket=DSocket, dtransport=DTransport},
			before_loop(SD1, idle_transfer);
		{socket_closed, Data, DSocketRef} ->
			Data ! DSocketRef,
			ok = receive
				{'EXIT', Data, _} ->
					ok
			end,
			SD1 = data_clean(SD0),
			before_loop(SD1, idle);
		{socket_error, Data, DReason, DSocketRef} ->
			Data ! DSocketRef,
			ok = receive
				{'EXIT', Data, _} ->
					ok
			end,
			SD1 = owner_send(SD0, {ftp_error, self(), {SD0#state_data.cref, DReason}}),
			SD2 = data_clean(SD1),
			SD3 = ctrl_close(SD2),
			before_loop(SD3, closed);
			% terminate(SD3, idle_opening, normal);
		{'$gen_call', From={Owner, _}, Request} ->
			handle(SD0, idle_opening, From, Request);
		{'$gen_call', {To, Tag}, _} ->
			To ! {Tag, {error, not_owner}},
			idle_opening(SD0);
		{'EXIT', Owner, _Reason} ->
			shutdown(SD0, idle_opening, normal);
		{system, From, Request} ->
			sys:handle_system_msg(Request, From, Owner, ?MODULE, [], {idle_opening, SD0});
		Info ->
			error_logger:error_msg(
				"FTP client ~p received unexpected message ~p in state ~p~n",
				[self(), Info, idle_opening])
	end.

%% @private
idle_transfer(SD0=#state_data{owner=Owner, cmessages={COK, CClosed, CError}, csocket=CSocket, dmessages={DOK, DClosed, DError}, dsocket=DSocket}) ->
	% io:format("idle_transfer~n"),
	receive
		{COK, CSocket, CData} ->
			ctrl_parse(SD0, idle_transfer, CData);
		{CClosed, CSocket} ->
			SD1 = ctrl_close(SD0),
			before_loop(SD1, closed);
			% terminate(SD1, idle_transfer, normal);
		{CError, CSocket, CReason} ->
			SD1 = owner_send(SD0, {ftp_error, self(), {SD0#state_data.cref, CReason}}),
			SD2 = ctrl_close(SD1),
			before_loop(SD2, closed);
			% terminate(SD2, idle_transfer, normal);
		{DOK, DSocket, DData} ->
			data_parse(SD0, idle_transfer, DData);
		{DClosed, DSocket} ->
			SD1 = data_clean(SD0),
			before_loop(SD1, idle);
		{DError, DSocket, DReason} ->
			SD1 = owner_send(SD0, {ftp_error, self(), {SD0#state_data.cref, DReason}}),
			SD2 = data_clean(SD1),
			SD3 = ctrl_close(SD2),
			before_loop(SD3, closed);
			% terminate(SD3, idle_transfer, normal);
		{'$gen_call', From={Owner, _}, Request} ->
			handle(SD0, idle_transfer, From, Request);
		{'$gen_call', {To, Tag}, _} ->
			To ! {Tag, {error, not_owner}},
			idle_transfer(SD0);
		{'EXIT', Owner, _Reason} ->
			shutdown(SD0, idle_transfer, normal);
		{system, From, Request} ->
			sys:handle_system_msg(Request, From, Owner, ?MODULE, [], {idle_transfer, SD0});
		Info ->
			error_logger:error_msg(
				"FTP client ~p received unexpected message ~p in state ~p~n",
				[self(), Info, idle_transfer])
	end.

%% @private
reply_wait(SD0=#state_data{owner=Owner, cmessages={COK, CClosed, CError}, csocket=CSocket, ctransport=CTransport}) ->
	% io:format("reply_wait~n"),
	receive
		{COK, CSocket, CData} ->
			ctrl_parse(SD0, reply_wait, CData);
		{CClosed, CSocket} ->
			SD1 = ctrl_close(SD0),
			before_loop(SD1, closed);
			% terminate(SD1, reply_wait, normal);
		{CError, CSocket, CReason} ->
			SD1 = owner_send(SD0, {ftp_error, self(), {SD0#state_data.cref, CReason}}),
			SD2 = ctrl_close(SD1),
			before_loop(SD2, closed);
			% terminate(SD2, reply_wait, normal);
		{'$gen_call', From={Owner, _}, Request} ->
			handle(SD0, reply_wait, From, Request);
		{force, Packet} ->
			Owner ! CTransport:send(CSocket, Packet),
			Owner ! CTransport:setopts(CSocket, [{active, true}]),
			reply_wait(SD0);
		{'$gen_call', {To, Tag}, _} ->
			To ! {Tag, {error, not_owner}},
			reply_wait(SD0);
		{'EXIT', Owner, _Reason} ->
			shutdown(SD0, reply_wait, normal);
		{system, From, Request} ->
			sys:handle_system_msg(Request, From, Owner, ?MODULE, [], {reply_wait, SD0});
		Info ->
			error_logger:error_msg(
				"FTP client ~p received unexpected message ~p in state ~p~n",
				[self(), Info, reply_wait])
	end.

%% @private
reply_wait_opening(SD0=#state_data{owner=Owner, cmessages={COK, CClosed, CError}, csocket=CSocket, data=Data, ddone=DDone}) ->
	% io:format("reply_wait_opening~n"),
	receive
		{COK, CSocket, CData} ->
			ctrl_parse(SD0, reply_wait_opening, CData);
		{CClosed, CSocket} ->
			SD1 = ctrl_close(SD0),
			before_loop(SD1, closed);
			% terminate(SD1, reply_wait_opening, normal);
		{CError, CSocket, CReason} ->
			SD1 = owner_send(SD0, {ftp_error, self(), {SD0#state_data.cref, CReason}}),
			SD2 = ctrl_close(SD1),
			before_loop(SD2, closed);
			% terminate(SD2, reply_wait_opening, normal);
		{socket, Data, DTransport, DSocket, DSocketRef} ->
			Data ! DSocketRef,
			ok = receive
				{'EXIT', Data, _} ->
					ok
			end,
			DMessages = DTransport:messages(),
			SD1 = SD0#state_data{data=undefined, dmessages=DMessages,
				dsocket=DSocket, dtransport=DTransport},
			SD2 = data_active(SD1),
			SD3 = data_send_flush(SD2),
			case DDone of
				immediate ->
					SD4 = SD3#state_data{ddone=undefined},
					SD5 = data_clean(SD4),
					before_loop(SD5, reply_wait);
				_ ->
					before_loop(SD3, reply_wait_transfer)
			end;
		{socket_closed, Data, DSocketRef} ->
			Data ! DSocketRef,
			ok = receive
				{'EXIT', Data, _} ->
					ok
			end,
			SD1 = data_clean(SD0),
			before_loop(SD1, reply_wait);
		{socket_error, Data, DReason, DSocketRef} ->
			Data ! DSocketRef,
			ok = receive
				{'EXIT', Data, _} ->
					ok
			end,
			SD1 = owner_send(SD0, {ftp_error, self(), {SD0#state_data.cref, DReason}}),
			SD2 = data_clean(SD1),
			SD3 = ctrl_close(SD2),
			before_loop(SD3, closed);
			% terminate(SD3, reply_wait_opening, normal);
		{'$gen_call', From={Owner, _}, Request} ->
			handle(SD0, reply_wait_opening, From, Request);
		{'$gen_call', {To, Tag}, _} ->
			To ! {Tag, {error, not_owner}},
			reply_wait_opening(SD0);
		{'EXIT', Owner, _Reason} ->
			shutdown(SD0, reply_wait_opening, normal);
		{system, From, Request} ->
			sys:handle_system_msg(Request, From, Owner, ?MODULE, [], {reply_wait_opening, SD0});
		Info ->
			error_logger:error_msg(
				"FTP client ~p received unexpected message ~p in state ~p~n",
				[self(), Info, reply_wait_opening])
	end.

%% @private
reply_wait_transfer(SD0=#state_data{owner=Owner, cmessages={COK, CClosed, CError}, csocket=CSocket, dmessages={DOK, DClosed, DError}, dsocket=DSocket}) ->
	% io:format("reply_wait_transfer~n"),
	receive
		{COK, CSocket, CData} ->
			ctrl_parse(SD0, reply_wait_transfer, CData);
		{CClosed, CSocket} ->
			SD1 = ctrl_close(SD0),
			before_loop(SD1, closed);
			% terminate(SD1, reply_wait_transfer, normal);
		{CError, CSocket, CReason} ->
			SD1 = owner_send(SD0, {ftp_error, self(), {SD0#state_data.cref, CReason}}),
			SD2 = ctrl_close(SD1),
			before_loop(SD2, closed);
			% terminate(SD2, reply_wait_transfer, normal);
		{DOK, DSocket, DData} ->
			data_parse(SD0, reply_wait_transfer, DData);
		{DClosed, DSocket} ->
			SD1 = data_clean(SD0),
			before_loop(SD1, reply_wait);
		{DError, DSocket, DReason} ->
			SD1 = owner_send(SD0, {ftp_error, self(), {SD0#state_data.cref, DReason}}),
			SD2 = data_clean(SD1),
			SD3 = ctrl_close(SD2),
			before_loop(SD3, closed);
			% terminate(SD3, reply_wait_transfer, normal);
		{'$gen_call', From={Owner, _}, Request} ->
			handle(SD0, reply_wait_transfer, From, Request);
		{'$gen_call', {To, Tag}, _} ->
			To ! {Tag, {error, not_owner}},
			reply_wait_transfer(SD0);
		{'EXIT', Owner, _Reason} ->
			shutdown(SD0, reply_wait_transfer, normal);
		{system, From, Request} ->
			sys:handle_system_msg(Request, From, Owner, ?MODULE, [], {reply_wait_transfer, SD0});
		Info ->
			error_logger:error_msg(
				"FTP client ~p received unexpected message ~p in state ~p~n",
				[self(), Info, reply_wait_transfer])
	end.

%% @private
opening(SD0=#state_data{owner=Owner, cmessages={COK, CClosed, CError}, csocket=CSocket, data=Data, ddone=DDone, dref=DRef}) ->
	% io:format("opening~n"),
	receive
		{COK, CSocket, CData} ->
			ctrl_parse(SD0, opening, CData);
		{CClosed, CSocket} ->
			SD1 = ctrl_close(SD0),
			before_loop(SD1, closed);
			% terminate(SD1, opening, normal);
		{CError, CSocket, CReason} ->
			SD1 = owner_send(SD0, {ftp_error, self(), {SD0#state_data.cref, CReason}}),
			SD2 = ctrl_close(SD1),
			before_loop(SD2, closed);
			% terminate(SD2, opening, normal);
		{socket, Data, DTransport, DSocket, DSocketRef} ->
			Data ! DSocketRef,
			ok = receive
				{'EXIT', Data, _} ->
					ok
			end,
			DMessages = DTransport:messages(),
			SD1 = SD0#state_data{data=undefined, dmessages=DMessages,
				dsocket=DSocket, dtransport=DTransport},
			SD2 = data_active(SD1),
			SD3 = data_send_flush(SD2),
			case DDone of
				immediate ->
					SD4 = SD3#state_data{ddone=undefined},
					SD5 = data_clean(SD4),
					before_loop(SD5, idle);
				_ ->
					before_loop(SD3, transfer)
			end;
		{socket_closed, Data, DSocketRef} ->
			Data ! DSocketRef,
			ok = receive
				{'EXIT', Data, _} ->
					ok
			end,
			SD1 = data_clean(SD0),
			SD2 = ctrl_done(SD1),
			before_loop(SD2, idle);
		{socket_error, Data, DReason, DSocketRef} ->
			Data ! DSocketRef,
			ok = receive
				{'EXIT', Data, _} ->
					ok
			end,
			SD1 = owner_send(SD0, {ftp_error, self(), {SD0#state_data.cref, DReason}}),
			SD2 = data_clean(SD1),
			SD3 = ctrl_close(SD2),
			before_loop(SD3, closed);
			% terminate(SD3, opening, normal);
		{'$gen_call', From={Owner, _}, Request} ->
			handle(SD0, opening, From, Request);
		{'$gen_call', {To, Tag}, _} ->
			To ! {Tag, {error, not_owner}},
			opening(SD0);
		{timeout, DRef, data} ->
			SD1 = SD0#state_data{dref=undefined},
			SD2 = data_inactive(SD1),
			SD3 = ctrl_done(SD2),
			before_loop(SD3, idle_opening);
		{'EXIT', Owner, _Reason} ->
			shutdown(SD0, opening, normal);
		{system, From, Request} ->
			sys:handle_system_msg(Request, From, Owner, ?MODULE, [], {opening, SD0});
		Info ->
			error_logger:error_msg(
				"FTP client ~p received unexpected message ~p in state ~p~n",
				[self(), Info, opening])
	end.

%% @private
transfer(SD0=#state_data{owner=Owner, cmessages={COK, CClosed, CError}, csocket=CSocket, dmessages={DOK, DClosed, DError}, dref=DRef, dsocket=DSocket}) ->
	% io:format("transfer~n"),
	receive
		{COK, CSocket, CData} ->
			ctrl_parse(SD0, transfer, CData);
		{CClosed, CSocket} ->
			SD1 = ctrl_close(SD0),
			before_loop(SD1, closed);
			% terminate(SD1, transfer, normal);
		{CError, CSocket, CReason} ->
			SD1 = owner_send(SD0, {ftp_error, self(), {SD0#state_data.cref, CReason}}),
			SD2 = ctrl_close(SD1),
			before_loop(SD2, closed);
			% terminate(SD2, transfer, normal);
		{DOK, DSocket, DData} ->
			data_parse(SD0, transfer, DData);
		{DClosed, DSocket} ->
			SD1 = data_clean(SD0),
			SD2 = ctrl_done(SD1),
			before_loop(SD2, idle);
		{DError, DSocket, DReason} ->
			SD1 = owner_send(SD0, {ftp_error, self(), {SD0#state_data.cref, DReason}}),
			SD2 = data_clean(SD1),
			SD3 = ctrl_close(SD2),
			before_loop(SD3, closed);
			% terminate(SD3, transfer, normal);
		{'$gen_call', From={Owner, _}, Request} ->
			handle(SD0, transfer, From, Request);
		{'$gen_call', {To, Tag}, _} ->
			To ! {Tag, {error, not_owner}},
			transfer(SD0);
		{timeout, DRef, data} ->
			SD1 = SD0#state_data{dref=undefined},
			SD2 = data_inactive(SD1),
			SD3 = ctrl_done(SD2),
			before_loop(SD3, idle_transfer);
		{'EXIT', Owner, _Reason} ->
			shutdown(SD0, transfer, normal);
		{system, From, Request} ->
			sys:handle_system_msg(Request, From, Owner, ?MODULE, [], {transfer, SD0});
		Info ->
			error_logger:error_msg(
				"FTP client ~p received unexpected message ~p in state ~p~n",
				[self(), Info, transfer])
	end.

%% @private
closed(SD0=#state_data{rcvbuf={[],[]}}) ->
	terminate(SD0, closed, normal);
closed(SD0=#state_data{owner=Owner}) ->
	receive
		{'$gen_call', From={Owner, _}, Request} ->
			handle(SD0, closed, From, Request);
		{'$gen_call', {To, Tag}, _} ->
			To ! {Tag, {error, now_owner}},
			closed(SD0);
		{'EXIT', Owner, _Reason} ->
			shutdown(SD0, closed, normal);
		{system, From, Request} ->
			sys:handle_system_msg(Request, From, Owner, ?MODULE, [], {closed, SD0});
		Info ->
			error_logger:error_msg(
				"FTP client ~p received unexpected message ~p in state ~p~n",
				[self(), Info, closed])
	end.

%%%===================================================================
%%% sys callbacks
%%%===================================================================

system_continue(_, _, {SN, SD}) ->
	?MODULE:SN(SD).

system_terminate(Reason, _, _, {SN, SD}) ->
	terminate(SD, SN, Reason).

system_code_change(Misc, _, _, _) ->
	{ok, Misc}.

system_get_state({SN, SD}) ->
	{ok, {SN, SD}}.

system_replace_state(StateFun, {SN0, SD0}) ->
	Result = {SN1, SD1} = StateFun({SN0, SD0}),
	{ok, Result, {SN1, SD1}}.

%%%-------------------------------------------------------------------
%%% Control functions
%%%-------------------------------------------------------------------

%% @private
ctrl_active(SD=#state_data{csocket=CSocket, ctransport=CTransport}) ->
	CTransport:setopts(CSocket, [{active, once}]),
	SD.

%% @private
ctrl_close(SD0=#state_data{ctrl=undefined, csocket=undefined, ctransport=undefined}) ->
	SD1 = owner_send(SD0, {ftp_closed, self()}),
	Buf = <<>>,
	CDecode = lftpc_protocol:new_decoder(),
	CWait = queue:new(),
	SD2 = SD1#state_data{cbuffer=Buf, cdecode=CDecode,
		cmessages=undefined, cref=undefined, creq=undefined,
		cwait=CWait},
	SD2;
ctrl_close(SD0=#state_data{ctrl=Ctrl, csocket=undefined, ctransport=undefined}) ->
	monitor(process, Ctrl),
	unlink(Ctrl),
	exit(Ctrl, normal),
	ok = receive
		{'DOWN', _, process, Ctrl, _} ->
			ok
	after
		?PAUSE ->
			exit(Ctrl, kill),
			receive
				{'DOWN', _, process, Ctrl, _} ->
					ok
			end
	end,
	SD1 = SD0#state_data{ctrl=undefined},
	ctrl_close(SD1);
ctrl_close(SD0=#state_data{ctrl=undefined, csocket=CSocket, ctransport=CTransport}) ->
	catch CTransport:close(CSocket),
	SD1 = SD0#state_data{csocket=undefined, ctransport=undefined},
	ctrl_close(SD1).

%% @private
ctrl_done(SD0=#state_data{cref=CRef}) ->
	SD1 = owner_send(SD0, {ftp, self(), {CRef, done}}),
	SD2 = SD1#state_data{cref=undefined, creq=undefined},
	SD2.

%% @private
ctrl_handle(SD0, SN, [<<"PASV">> | _], {227, Text})
		when SN =:= idle
		orelse SN =:= idle_opening
		orelse SN =:= idle_transfer ->
	case lftpc_protocol:parse_pasv(iolist_to_binary(Text)) of
		{true, Peername, _} ->
			SD1 = data_open(SD0, {passive, Peername}),
			ctrl_parse(SD1, idle_opening, <<>>);
		false ->
			ctrl_parse(SD0, SN, <<>>)
	end;
ctrl_handle(SD0, opening, [<<"PORT">> | _], {C, _}) when C >= 200 ->
	SD1 = ctrl_done(SD0),
	ctrl_parse(SD1, idle_opening, <<>>);
ctrl_handle(SD0, transfer, [<<"PORT">> | _], {C, _}) when C >= 200 ->
	SD1 = ctrl_done(SD0),
	ctrl_parse(SD1, idle_transfer, <<>>);
ctrl_handle(SD0, SN, [<<"EPSV">> | _], {229, Text})
		when SN =:= idle
		orelse SN =:= idle_opening
		orelse SN =:= idle_transfer ->
	case lftpc_protocol:parse_epsv(iolist_to_binary(Text)) of
		{true, Port, _} ->
			SD1 = data_open(SD0, {extended_passive, Port}),
			ctrl_parse(SD1, idle_opening, <<>>);
		false ->
			ctrl_parse(SD0, SN, <<>>)
	end;
ctrl_handle(SD0, opening, [<<"EPRT">> | _], {C, _}) when C >= 200 ->
	SD1 = ctrl_done(SD0),
	ctrl_parse(SD1, idle_opening, <<>>);
ctrl_handle(SD0, transfer, [<<"EPRT">> | _], {C, _}) when C >= 200 ->
	SD1 = ctrl_done(SD0),
	ctrl_parse(SD1, idle_transfer, <<>>);
ctrl_handle(SD, SN, [<<"AUTH">> | Tail], {234, _}) ->
	case ctrl_is_tls(?INLINE_UPPERCASE_BC(iolist_to_binary(Tail))) of
		true ->
			ctrl_tls(SD, SN);
		false ->
			ctrl_parse(SD, SN, <<>>)
	end;
ctrl_handle(SD0, SN, [<<"PROT">> | Tail], {Code, _}) when Code >= 200 ->
	SD1 = case ctrl_is_prot(?INLINE_UPPERCASE_BC(iolist_to_binary(Tail))) of
		clear ->
			SD0#state_data{dtls=false};
		private ->
			SD0#state_data{dtls=explicit};
		false ->
			SD0#state_data{dtls=false}
	end,
	ctrl_parse(SD1, SN, <<>>);
ctrl_handle(SD, SN, _CReq, _CRep) ->
	ctrl_parse(SD, SN, <<>>).

%% @private
ctrl_is_tls(<< "TLS", _/binary >>) ->
	true;
ctrl_is_tls(<< _, Rest/binary >>) ->
	ctrl_is_tls(Rest);
ctrl_is_tls(<<>>) ->
	false.

%% @private
ctrl_is_prot(<< $C, _/binary >>) ->
	clear;
ctrl_is_prot(<< $P, _/binary >>) ->
	private;
ctrl_is_prot(<< _, Rest/binary >>) ->
	ctrl_is_prot(Rest);
ctrl_is_prot(<<>>) ->
	false.

%% @private
ctrl_parse(SD0=#state_data{cbuffer=CBuffer, cdecode=CDecode}, SN, CData) ->
	case lftpc_protocol:decode(<< CBuffer/binary, CData/binary >>, CDecode) of
		{true, Reply, NewCBuffer, NewCDecode} ->
			SD1 = SD0#state_data{cbuffer=NewCBuffer, cdecode=NewCDecode},
			ctrl_process(SD1, SN, Reply);
		{false, NewCBuffer, NewCDecode} ->
			SD1 = SD0#state_data{cbuffer=NewCBuffer, cdecode=NewCDecode},
			SD2 = ctrl_active(SD1),
			before_loop(SD2, SN)
	end.

%% @private
ctrl_prep(SD0, _SN, <<"PORT">>, []) ->
	SD1 = data_open(SD0, active),
	Argument = data_port(SD1),
	{SD1, idle_opening, [$\s, Argument, $\r, $\n]};
ctrl_prep(SD0, _SN, <<"EPRT">>, []) ->
	SD1 = data_open(SD0, extended_active),
	Argument = data_eprt(SD1),
	{SD1, idle_opening, [$\s, Argument, $\r, $\n]};
ctrl_prep(SD, SN, _, []) ->
	{SD, SN, [$\r, $\n]};
ctrl_prep(SD, SN, _, Argument) ->
	{SD, SN, [$\s, Argument, $\r, $\n]}.

%% @private
ctrl_process(SD0, _SN, R={421, _}) ->
	SD1 = data_clean(SD0),
	SD2 = ctrl_recv(SD1, R),
	SD3 = ctrl_done(SD2),
	SD4 = ctrl_close(SD3),
	before_loop(SD4, closed);
	% terminate(SD3, SN, normal);
ctrl_process(SD0, SN=reply_wait_transfer, R={C, _})
		when C =:= 125
		orelse C =:= 150 ->
	SD1 = ctrl_recv(SD0, R),
	SD2 = data_active(SD1),
	ctrl_handle(SD2, SN, SD0#state_data.creq, R);
ctrl_process(SD0, SN, R={C, _})
		when C >= 100
		andalso C < 200 ->
	SD1 = ctrl_recv(SD0, R),
	ctrl_handle(SD1, SN, SD0#state_data.creq, R);
ctrl_process(SD0, SN, R)
		when SN =:= ready_wait
		orelse SN =:= reply_wait ->
	SD1 = ctrl_recv(SD0, R),
	SD2 = ctrl_done(SD1),
	ctrl_handle(SD2, idle, SD0#state_data.creq, R);
ctrl_process(SD0, reply_wait_opening, R) ->
	SD1 = ctrl_recv(SD0, R),
	ctrl_handle(SD1, opening, SD0#state_data.creq, R);
ctrl_process(SD0, reply_wait_transfer, R) ->
	SD1 = ctrl_recv(SD0, R),
	ctrl_handle(SD1, transfer, SD0#state_data.creq, R);
ctrl_process(SD0, SN, R) ->
	SD1 = ctrl_recv(SD0, R),
	ctrl_handle(SD1, SN, SD0#state_data.creq, R).

%% @private
ctrl_recv(SD0=#state_data{cref=CRef}, R) ->
	SD1 = owner_send(SD0, {ftp, self(), {CRef, R}}),
	SD1.

%% @private
ctrl_send(SD0=#state_data{csocket=CSocket, ctransport=CTransport}, CReq) ->
	CTransport:send(CSocket, CReq),
	SD1 = SD0#state_data{creq=CReq},
	SD2 = ctrl_active(SD1),
	SD2.

%% @private
ctrl_start(SD=#state_data{host=Host, port=Port, options=Options,
		timeout=Timeout, ctls=CTLS}) ->
	Pid = self(),
	Connect = fun() ->
		Transport = case CTLS of
			false ->
				get_value(transport, Options, ranch_tcp);
			implicit ->
				get_value(tls_transport, Options, ranch_ssl)
		end,
		TLSOpts = case CTLS of
			false ->
				[];
			implicit ->
				get_value(tls_opts, Options, [])
		end,
		TransOpts = get_value(transport_opts, Options, []) ++ TLSOpts,
		case Transport:connect(Host, Port, TransOpts, Timeout) of
			{ok, Socket} ->
				Ref = make_ref(),
				Pid ! {socket, self(), Transport, Socket, Ref},
				Transport:controlling_process(Socket, Pid),
				receive
					Ref ->
						exit(normal)
				end;
			{error, Reason} ->
				Ref = make_ref(),
				Pid ! {socket_error, self(), Reason, Ref},
				receive
					Ref ->
						exit(normal)
				end
		end
	end,
	Ctrl = spawn_link(Connect),
	?MODULE:connecting(SD#state_data{ctrl=Ctrl}).

%% @private
ctrl_tls(SD0=#state_data{options=Options, timeout=Timeout, csocket=CSocket, ctls=false}, SN) ->
	TLSOpts = get_value(tls_opts, Options, []),
	case ssl:connect(CSocket, TLSOpts, Timeout) of
		{ok, TLSSocket} ->
			TLSTransport = get_value(tls_transport, Options, ranch_ssl),
			TLSMessages = TLSTransport:messages(),
			SD1 = SD0#state_data{cmessages=TLSMessages, csocket=TLSSocket, ctls=explicit, ctransport=TLSTransport},
			ctrl_parse(SD1, SN, <<>>)
	end;
ctrl_tls(SD, SN) ->
	ctrl_parse(SD, SN, <<>>).

%%%-------------------------------------------------------------------
%%% Data functions
%%%-------------------------------------------------------------------

%% @private
data_active(SD=#state_data{creq=[<<"PORT">> | _], dopen={active, _}}) ->
	SD;
data_active(SD=#state_data{creq=[<<"EPRT">> | _], dopen={extended_active, _}}) ->
	SD;
data_active(SD=#state_data{dsocket=DSocket, dtransport=DTransport}) ->
	DTransport:setopts(DSocket, [{active, once}]),
	SD.

%% @private
data_clean(SD0=#state_data{data=undefined, dsocket=undefined, dtransport=undefined}) ->
	Buf = <<>>,
	SD1 = SD0#state_data{data=undefined, dbuffer=Buf,
		ddecode=undefined, dopen=undefined, dsocket=undefined,
		dtransport=undefined},
	SD1;
data_clean(SD0=#state_data{data=undefined, dsocket=DSocket, dtransport=DTransport}) ->
	catch DTransport:close(DSocket),
	SD1 = SD0#state_data{dsocket=undefined, dtransport=undefined},
	data_clean(SD1);
data_clean(SD0=#state_data{data=Data, dsocket=undefined, dtransport=undefined}) ->
	monitor(process, Data),
	unlink(Data),
	exit(Data, normal),
	ok = receive
		{'DOWN', _, process, Data, _} ->
			ok
	after
		100 ->
			exit(Data, kill),
			receive
				{'DOWN', _, process, Data, _} ->
					ok
			end
	end,
	SD1 = SD0#state_data{data=undefined},
	data_clean(SD1).

%% @private
data_eprt(#state_data{dopen={extended_active, {{A0,A1,A2,A3}, Port}}}) ->
	io_lib:format("|1|~w.~w.~w.~w|~w|", [A0,A1,A2,A3,Port]);
data_eprt(#state_data{dopen={extended_active, {{A0,A1,A2,A3,A4,A5,A6,A7}, Port}}}) ->
	io_lib:format("|2|~w:~w:~w:~w:~w:~w:~w:~w|~w|", [A0,A1,A2,A3,A4,A5,A6,A7,Port]).

%% @private
data_inactive(SD=#state_data{dsocket=undefined, dtransport=undefined}) ->
	SD;
data_inactive(SD0=#state_data{dsocket=DSocket, dtransport=DTransport}) ->
	DTransport:setopts(DSocket, [{active, false}]),
	SD1 = data_inactive_flush(SD0),
	SD1.

%% @private
data_inactive_flush(SD0=#state_data{dmessages={DOK, DClosed, DError}, dsocket=DSocket}) ->
	receive
		{DOK, _DData} ->
			data_inactive_flush(SD0);
		{DClosed, DSocket} ->
			SD1 = data_inactive_flush(SD0),
			SD2 = data_clean(SD1),
			SD2;
		{DError, DSocket, DReason} ->
			error_logger:error_msg(
				"FTP client ~p data connection error ~p~n",
				[self(), DReason]),
			SD1 = data_inactive_flush(SD0),
			SD2 = data_clean(SD1),
			SD2
	after
		0 ->
			SD0
	end.

%% @private
data_open(SD0=#state_data{options=Options, timeout=Timeout, ctransport=CTransport, data=undefined, dsocket=undefined}, DOpen={passive, {Host, Port}}) ->
	DTransport = CTransport,
	DTransOpts = get_value(transport_opts, Options, []),
	Pid = self(),
	Open = fun() ->
		case DTransport:connect(Host, Port, DTransOpts, Timeout) of
			{ok, Socket} ->
				Ref = make_ref(),
				Pid ! {socket, self(), DTransport, Socket, Ref},
				DTransport:controlling_process(Socket, Pid),
				receive
					Ref ->
						exit(normal)
				end;
			{error, closed} ->
				Ref = make_ref(),
				Pid ! {socket_closed, self(), Ref},
				receive
					Ref ->
						exit(normal)
				end;
			{error, Reason} ->
				Ref = make_ref(),
				Pid ! {socket_error, self(), Reason, Ref},
				receive
					Ref ->
						exit(normal)
				end
		end
	end,
	Data = spawn_link(Open),
	SD1 = SD0#state_data{data=Data, dopen=DOpen},
	SD1;
data_open(SD0=#state_data{options=Options, timeout=Timeout, csocket=CSocket, ctransport=CTransport, data=undefined, dsocket=undefined, dtls=DTLS}, active) ->
	{ok, {LHost, _}} = CTransport:sockname(CSocket),
	DTransport = case DTLS of
		implicit ->
			CTransport;
		_ ->
			get_value(transport, Options, ranch_tcp)
	end,
	DTransOpts = [
		{ip, LHost}
		| get_value(transport_opts, Options, [])
	],
	{ok, LSocket} = DTransport:listen(DTransOpts),
	{ok, Sockname} = DTransport:sockname(LSocket),
	Pid = self(),
	Open = case DTLS of
		explicit ->
			fun() ->
				receive
					{socket, Pid, Transport, LSocket, LRef} ->
						Pid ! LRef,
						case Transport:accept(LSocket, Timeout) of
							{ok, Socket} ->
								TLSOpts = get_value(tls_opts, Options, []),
								case ssl:connect(Socket, TLSOpts, Timeout) of
									{ok, TLSSocket} ->
										TLSTransport = get_value(tls_transport, Options, ranch_ssl),
										Ref = make_ref(),
										Pid ! {socket, self(), TLSTransport, TLSSocket, Ref},
										TLSTransport:controlling_process(TLSSocket, Pid),
										receive
											Ref ->
												Transport:close(LSocket),
												exit(normal)
										end;
									{error, closed} ->
										Ref = make_ref(),
										Pid ! {socket_closed, self(), Ref},
										receive
											Ref ->
												Transport:close(LSocket),
												exit(normal)
										end;
									{error, ConnectReason} ->
										Ref = make_ref(),
										Pid ! {socket_error, self(), ConnectReason, Ref},
										receive
											Ref ->
												Transport:close(LSocket),
												exit(normal)
										end
								end;
							{error, closed} ->
								Ref = make_ref(),
								Pid ! {socket_closed, self(), Ref},
								receive
									Ref ->
										Transport:close(LSocket),
										exit(normal)
								end;
							{error, AcceptReason} ->
								Ref = make_ref(),
								Pid ! {socket_error, self(), AcceptReason, Ref},
								receive
									Ref ->
										Transport:close(LSocket),
										exit(normal)
								end
						end
				end
			end;
		_ ->
			fun() ->
				receive
					{socket, Pid, Transport, LSocket, LRef} ->
						Pid ! LRef,
						case Transport:accept(LSocket, Timeout) of
							{ok, Socket} ->
								Ref = make_ref(),
								Pid ! {socket, self(), Transport, Socket, Ref},
								Transport:controlling_process(Socket, Pid),
								receive
									Ref ->
										Transport:close(LSocket),
										exit(normal)
								end;
							{error, closed} ->
								Ref = make_ref(),
								Pid ! {socket_closed, self(), Ref},
								receive
									Ref ->
										Transport:close(LSocket),
										exit(normal)
								end;
							{error, Reason} ->
								Ref = make_ref(),
								Pid ! {socket_error, self(), Reason, Ref},
								receive
									Ref ->
										Transport:close(LSocket),
										exit(normal)
								end
						end
				end
			end
	end,
	Data = spawn_link(Open),
	DTransport:controlling_process(LSocket, Data),
	Ref = make_ref(),
	Data ! {socket, Pid, DTransport, LSocket, Ref},
	ok = receive
		Ref ->
			ok
	end,
	SD1 = SD0#state_data{data=Data, dopen={active, Sockname}},
	SD1;
data_open(SD0=#state_data{options=Options, timeout=Timeout, csocket=CSocket, ctransport=CTransport, data=undefined, dsocket=undefined}, DOpen={extended_passive, Port}) ->
	{ok, {Host, _}} = CTransport:peername(CSocket),
	DTransport = CTransport,
	DTransOpts = get_value(transport_opts, Options, []),
	Pid = self(),
	Open = fun() ->
		case DTransport:connect(Host, Port, DTransOpts, Timeout) of
			{ok, Socket} ->
				Ref = make_ref(),
				Pid ! {socket, self(), DTransport, Socket, Ref},
				DTransport:controlling_process(Socket, Pid),
				receive
					Ref ->
						exit(normal)
				end;
			{error, closed} ->
				Ref = make_ref(),
				Pid ! {socket_closed, self(), Ref},
				receive
					Ref ->
						exit(normal)
				end;
			{error, Reason} ->
				Ref = make_ref(),
				Pid ! {socket_error, self(), Reason, Ref},
				receive
					Ref ->
						exit(normal)
				end
		end
	end,
	Data = spawn_link(Open),
	SD1 = SD0#state_data{data=Data, dopen=DOpen},
	SD1;
data_open(SD0=#state_data{options=Options, timeout=Timeout, csocket=CSocket, ctransport=CTransport, data=undefined, dsocket=undefined, dtls=DTLS}, extended_active) ->
	{ok, {LHost, _}} = CTransport:sockname(CSocket),
	DTransport = case DTLS of
		implicit ->
			CTransport;
		_ ->
			get_value(transport, Options, ranch_tcp)
	end,
	DTransOpts = [
		{ip, LHost}
		| get_value(transport_opts, Options, [])
	],
	{ok, LSocket} = DTransport:listen(DTransOpts),
	{ok, Sockname} = DTransport:sockname(LSocket),
	Pid = self(),
	Open = case DTLS of
		explicit ->
			fun() ->
				receive
					{socket, Pid, Transport, LSocket, LRef} ->
						Pid ! LRef,
						case Transport:accept(LSocket, Timeout) of
							{ok, Socket} ->
								TLSOpts = get_value(tls_opts, Options, []),
								case ssl:connect(Socket, TLSOpts, Timeout) of
									{ok, TLSSocket} ->
										TLSTransport = get_value(tls_transport, Options, ranch_ssl),
										Ref = make_ref(),
										Pid ! {socket, self(), TLSTransport, TLSSocket, Ref},
										TLSTransport:controlling_process(TLSSocket, Pid),
										receive
											Ref ->
												Transport:close(LSocket),
												exit(normal)
										end;
									{error, closed} ->
										Ref = make_ref(),
										Pid ! {socket_closed, self(), Ref},
										receive
											Ref ->
												Transport:close(LSocket),
												exit(normal)
										end;
									{error, ConnectReason} ->
										Ref = make_ref(),
										Pid ! {socket_error, self(), ConnectReason, Ref},
										receive
											Ref ->
												Transport:close(LSocket),
												exit(normal)
										end
								end;
							{error, closed} ->
								Ref = make_ref(),
								Pid ! {socket_closed, self(), Ref},
								receive
									Ref ->
										Transport:close(LSocket),
										exit(normal)
								end;
							{error, AcceptReason} ->
								Ref = make_ref(),
								Pid ! {socket_error, self(), AcceptReason, Ref},
								receive
									Ref ->
										Transport:close(LSocket),
										exit(normal)
								end
						end
				end
			end;
		_ ->
			fun() ->
				receive
					{socket, Pid, Transport, LSocket, LRef} ->
						Pid ! LRef,
						case Transport:accept(LSocket, Timeout) of
							{ok, Socket} ->
								Ref = make_ref(),
								Pid ! {socket, self(), Transport, Socket, Ref},
								Transport:controlling_process(Socket, Pid),
								receive
									Ref ->
										Transport:close(LSocket),
										exit(normal)
								end;
							{error, closed} ->
								Ref = make_ref(),
								Pid ! {socket_closed, self(), Ref},
								receive
									Ref ->
										Transport:close(LSocket),
										exit(normal)
								end;
							{error, Reason} ->
								Ref = make_ref(),
								Pid ! {socket_error, self(), Reason, Ref},
								receive
									Ref ->
										Transport:close(LSocket),
										exit(normal)
								end
						end
				end
			end
	end,
	Data = spawn_link(Open),
	DTransport:controlling_process(LSocket, Data),
	Ref = make_ref(),
	Data ! {socket, Pid, DTransport, LSocket, Ref},
	ok = receive
		Ref ->
			ok
	end,
	SD1 = SD0#state_data{data=Data, dopen={extended_active, Sockname}},
	SD1;
data_open(SD0, DOpen) ->
	SD1 = data_clean(SD0),
	data_open(SD1, DOpen).

%% @private
data_parse(SD0=#state_data{dbuffer=_DBuffer, ddecode=_DDecode}, SN, DData) ->
	SD1 = ctrl_recv(SD0, DData),
	SD2 = data_active(SD1),
	?MODULE:SN(SD2).

%% @private
data_port(#state_data{dopen={active, {{A0,A1,A2,A3}, Port}}}) ->
	% {P0,P1} = {Port bsr 8, Port band 255},
	<< P0,P1 >> = << Port:16/big-unsigned-integer >>,
	io_lib:format("~w,~w,~w,~w,~w,~w", [A0,A1,A2,A3,P0,P1]).

%% @private
data_send(SD=#state_data{data=undefined, dsocket=undefined, dtransport=undefined}, _Packet) ->
	SD;
data_send(SD0=#state_data{sndbuf=Sndbuf0, dref=undefined, dsocket=undefined, dtransport=undefined}, Packet) ->
	Sndbuf1 = queue:in(Packet, Sndbuf0),
	SD1 = SD0#state_data{sndbuf=Sndbuf1},
	SD1;
data_send(SD=#state_data{sndbuf={[],[]}, dref=undefined, dsocket=DSocket, dtransport=DTransport}, Packet) ->
	DTransport:send(DSocket, Packet),
	SD;
data_send(SD0=#state_data{sndbuf=Sndbuf0, dref=undefined}, Packet) ->
	Sndbuf1 = queue:in(Packet, Sndbuf0),
	SD1 = SD0#state_data{sndbuf=Sndbuf1},
	data_send_flush(SD1);
data_send(SD0=#state_data{dref=OldDRef}, Packet) ->
	catch erlang:cancel_timer(OldDRef),
	ok = receive
		{timeout, OldDRef, data} ->
			ok
	after
		0 ->
			ok
	end,
	SD1 = SD0#state_data{dref=undefined},
	data_send(SD1, Packet).

%% @private
data_sendfile(SD=#state_data{data=undefined, dsocket=undefined, dtransport=undefined}, _, _, _, _) ->
	SD;
data_sendfile(SD0=#state_data{sndbuf=Sndbuf0, dsocket=undefined, dtransport=undefined}, Filename, Offset, Bytes, Opts) ->
	Sndbuf1 = queue:in({sendfile, Filename, Offset, Bytes, Opts}, Sndbuf0),
	SD1 = SD0#state_data{sndbuf=Sndbuf1},
	SD1;
data_sendfile(SD=#state_data{sndbuf={[],[]}, dref=undefined, dsocket=DSocket, dtransport=DTransport}, Filename, Offset, Bytes, Opts) ->
	DTransport:sendfile(DSocket, Filename, Offset, Bytes, Opts),
	SD;
data_sendfile(SD0, Filename, Offset, Bytes, Opts) ->
	SD1 = data_send_flush(SD0),
	data_sendfile(SD1, Filename, Offset, Bytes, Opts).

%% @private
data_send_flush(SD=#state_data{sndbuf={[],[]}}) ->
	SD;
data_send_flush(SD=#state_data{dsocket=undefined, dtransport=undefined}) ->
	SD;
data_send_flush(SD0=#state_data{sndbuf=Sndbuf0, data=undefined}) ->
	case data_send_dequeue(Sndbuf0, []) of
		{more, Packet, {sendfile, Filename, Offset, Bytes, Opts}, Sndbuf1} ->
			SD1 = SD0#state_data{sndbuf=queue:new()},
			SD2 = data_send(SD1, Packet),
			SD3 = data_sendfile(SD2, Filename, Offset, Bytes, Opts),
			SD4 = SD3#state_data{sndbuf=Sndbuf1},
			data_send_flush(SD4);
		{true, Packet, Sndbuf1} ->
			SD1 = SD0#state_data{sndbuf=Sndbuf1},
			data_send(SD1, Packet);
		false ->
			SD0
	end;
data_send_flush(SD) ->
	SD.

%% @private
data_send_dequeue({[],[]}, []) ->
	false;
data_send_dequeue(Sndbuf0, Acc) ->
	case queue:out(Sndbuf0) of
		{{value, F={sendfile, _, _, _, _}}, Sndbuf1} ->
			{more, lists:reverse(Acc), F, Sndbuf1};
		{{value, Packet}, Sndbuf1} ->
			data_send_dequeue(Sndbuf1, [Packet | Acc]);
		{empty, Sndbuf0} ->
			{true, lists:reverse(Acc), Sndbuf0}
	end.

%%%-------------------------------------------------------------------
%%% Options functions
%%%-------------------------------------------------------------------

%% @private
options_get(SD, From, Options) ->
	options_get(SD, From, Options, []).

%% @private
options_get(SD=#state_data{active=Active}, From, [active | Options], Acc) ->
	options_get(SD, From, Options, [{active, Active} | Acc]);
options_get(SD=#state_data{owner=Owner}, From, [owner | Options], Acc) ->
	options_get(SD, From, Options, [{owner, Owner} | Acc]);
options_get(SD, {To, Tag}, [], Acc) ->
	To ! {Tag, {ok, lists:reverse(Acc)}},
	SD;
options_get(SD, {To, Tag}, _Options, _Acc) ->
	To ! {Tag, {error, einval}},
	SD.

%% @private
options_set(SD0, From, [{active, Active} | Options])
		when Active =:= false
		orelse Active =:= once
		orelse Active =:= true ->
	SD1 = options_set_active(SD0, Active),
	options_set(SD1, From, Options);
options_set(SD0=#state_data{owner=OldOwner}, From, [{owner, NewOwner} | Options]) ->
	erlang:unlink(OldOwner),
	erlang:link(NewOwner),
	SD1 = SD0#state_data{owner=NewOwner},
	options_set(SD1, From, Options);
options_set(SD, {To, Tag}, []) ->
	To ! {Tag, ok},
	SD;
options_set(SD, {To, Tag}, _) ->
	To ! {Tag, {error, einval}},
	SD.

%% @private
options_set_active(SD=#state_data{active=Active}, Active) ->
	SD;
options_set_active(SD0=#state_data{active=false}, Active) ->
	SD1 = SD0#state_data{active=Active},
	owner_flush(SD1);
options_set_active(SD0, Active) ->
	SD1 = SD0#state_data{active=Active},
	SD1.

%%%-------------------------------------------------------------------
%%% Owner functions
%%%-------------------------------------------------------------------

%% @private
owner_flush(SD0=#state_data{active=once, owner=Owner, rcvbuf=Rcvbuf}) ->
	case queue:out(Rcvbuf) of
		{{value, Message}, NewRcvbuf} ->
			Owner ! Message,
			SD1 = SD0#state_data{active=true, rcvbuf=NewRcvbuf},
			SD2 = owner_flush(SD1),
			SD3 = SD2#state_data{active=false},
			SD3;
		{empty, Rcvbuf} ->
			SD0
	end;
owner_flush(SD0=#state_data{active=true, owner=Owner, rcvbuf=Rcvbuf}) ->
	case queue:out(Rcvbuf) of
		{{value, Message}, NewRcvbuf} ->
			Owner ! Message,
			SD1 = SD0#state_data{rcvbuf=NewRcvbuf},
			owner_flush(SD1);
		{empty, Rcvbuf} ->
			SD0
	end;
owner_flush(SD) ->
	SD.

%% @private
owner_send(SD0=#state_data{active=once, owner=Owner}, Message) ->
	Owner ! Message,
	SD1 = SD0#state_data{active=false},
	SD1;
owner_send(SD=#state_data{active=true, owner=Owner}, Message) ->
	Owner ! Message,
	SD;
owner_send(SD0=#state_data{active=false, rcvbuf=Rcvbuf}, Message) ->
	SD1 = SD0#state_data{rcvbuf=queue:in(Message, Rcvbuf)},
	SD1.

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
sync_input(Pid, Owner, Flag) ->
	receive
		M={ftp, Pid, _Message} ->
			Owner ! M,
			sync_input(Pid, Owner, Flag);
		M={ftp_closed, Pid} ->
			Owner ! M,
			sync_input(Pid, Owner, true);
		M={ftp_error, Pid, _Reason} ->
			Owner ! M,
			sync_input(Pid, Owner, Flag)
	after
		0 ->
			Flag
	end.
