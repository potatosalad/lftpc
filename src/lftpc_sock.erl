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
-module(lftpc_sock).
-behaviour(gen_fsm).

-include("lftpc_inline.hrl").

%% API exports
-export([close/1]).
-export([connect/3]).
-export([connect/4]).
-export([controlling_process/2]).
-export([getopts/2]).
-export([quote/2]).
-export([quote/3]).
-export([send_data_part/2]).
-export([send_data_part/3]).
-export([setopts/2]).

%% gen_fsm callbacks
-export([init/1]).
-export([handle_sync_event/4]).
-export([handle_event/3]).
-export([handle_info/3]).
-export([terminate/3]).
-export([code_change/4]).

%% gen_fsm states
-export([started/2]).
-export([connecting/2]).
-export([idle/2]).
-export([reply_wait/2]).
-export([transfer_wait/2]).
-export([securing/2]).
-export([closing/2]).

%% Records
-record(ctrl, {
	buffer    = <<>>      :: binary(),
	decode    = undefined :: undefined | lftpc_protocol:decoder(),
	messages  = undefined :: undefined | {atom(), atom(), atom()},
	socket    = undefined :: undefined | inet:socket(),
	transport = undefined :: undefined | module()
}).

-record(data, {
	messages  = undefined :: undefined | {atom(), atom(), atom()},
	socket    = undefined :: undefined | inet:socket(),
	transport = undefined :: undefined | module()
}).

-record(dtp, {
	connect   = undefined :: undefined | active | extended_active | extended_passive | passive,
	peername  = undefined :: undefined | {inet:ip_address(), inet:port_number()},
	socket    = undefined :: undefined | inet:socket(),
	sockname  = undefined :: undefined | {inet:ip_address(), inet:port_number()},
	transport = undefined :: undefined | module()
}).

-type call() :: {{pid(), reference()}, term(), block | nonblock}.

-record(state_data, {
	owner = undefined :: undefined | pid(),
	% host  = undefined :: undefined | inet:hostname()| inet:ip_address(),
	% port  = undefined :: undefined | inet:port_number(),
	queue = undefined :: undefined | queue:queue(term()),
	% Control
	ctrl    = undefined :: undefined | pid() | #ctrl{},
	secure  = undefined :: undefined | pid(),
	closed  = false     :: boolean(),
	calls   = undefined :: undefined | queue:queue(call()),
	current = undefined :: undefined | call(),
	reply   = undefined :: undefined | term(),
	% Data
	data = undefined :: undefined | pid() | #data{},
	dtp  = undefined :: undefined | #dtp{},
	send = []        :: iodata(),
	eod  = false     :: boolean(),
	wait = false     :: boolean(),
	% Options
	active = undefined :: undefined | boolean() | once,
	block  = undefined :: undefined | boolean(),
	prot   = undefined :: undefined | clear | false | private,
	tls    = undefined :: undefined | explicit | false | implicit
}).

%% Macros
-define(CALL(Socket, Request, Error, Timeout),
	try
		gen_fsm:sync_send_all_state_event(Socket, Request, Timeout)
	catch
		exit:{noproc, _} ->
			Error
	end).

-define(CALL(Socket, Request, Error),
	?CALL(Socket, Request, Error, infinity)).

-define(CALL(Socket, Request),
	?CALL(Socket, Request, {error, einval})).

%%%===================================================================
%%% API functions
%%%===================================================================

close(Socket) ->
	case erlang:is_process_alive(Socket) of
		false ->
			ok;
		true ->
			erlang:monitor(process, Socket),
			erlang:unlink(Socket),
			ok = gen_fsm:send_all_state_event(Socket, close),
			receive
				{'DOWN', _, process, Socket, _} ->
					ok
			after
				5000 ->
					erlang:exit(Socket, kill),
					receive
						{'DOWN', _, process, Socket, _} ->
							ok
					end
			end
	end.

connect(Host, Port, Options) ->
	connect(Host, Port, Options, infinity).

connect(Host, Port, Options, Timeout) ->
	ok = verify_connect_options(Options, []),
	_ = Timeout,
	case gen_fsm:start_link(?MODULE, {self(), Options}, []) of
		{ok, Socket} ->
			Tag = make_ref(),
			From = {self(), Tag},
			ok = gen_fsm:send_event(Socket, {From, {connect, Host, Port}}),
			receive
				{Tag, ok} ->
					{ok, Socket};
				{Tag, Error} ->
					ok = close(Socket),
					Error
			after
				Timeout ->
					ok = close(Socket),
					{error, timeout}
			end;
		StartError ->
			StartError
	end.

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
							setopts(Socket, [{active, OldActive}, {owner, NewOwner}])
					end;
				Error ->
					Error
			end
	end.

getopts(Socket, Options) ->
	ok = verify_getopts_options(Options, []),
	?CALL(Socket, {getopts, Options}).

quote(Socket, Command) ->
	?CALL(Socket, {ctrl, [Command]}).

quote(Socket, Command, Argument) ->
	?CALL(Socket, {ctrl, [Command, Argument]}).

send_data_part(Socket, Data) ->
	send_data_part(Socket, Data, infinity).

send_data_part(Socket, Data, Timeout) ->
	?CALL(Socket, {data_part, self(), Data}, {error, einval}, Timeout).

setopts(Socket, Options) ->
	ok = verify_setopts_options(Options, []),
	?CALL(Socket, {setopts, Options}).

%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================

%% @private
init({Owner, Options}) ->
	true = lftpc_server:add_sock(self()),
	Active = get_value(active, Options, false),
	Block = get_value(block, Options, true),
	Debug = get_value(debug, Options, false),
	TLS = get_value(tls, Options, false),
	case Debug of
		false ->
			ok;
		trace ->
			dbg:tracer(),
			dbg:p(all, [call]),
			dbg:tpl(?MODULE, [{'_', [], [{return_trace}]}]);
		true ->
			dbg:tracer(),
			dbg:p(all, [call]),
			dbg:tp(?MODULE, [{'_', [], [{return_trace}]}])
	end,
	Calls = queue:new(),
	Queue = queue:new(),
	SD = #state_data{owner=Owner, calls=Calls, active=Active,
		block=Block, tls=TLS, queue=Queue},
	{ok, started, SD}.

%% @private
handle_sync_event({getopts, Options}, _From, SN, SD0) ->
	{SD1, Values} = options_get(SD0, Options, []),
	case SN of
		closing ->
			{reply, {ok, Values}, closing, SD1, 0};
		_ ->
			{reply, {ok, Values}, SN, SD1}
	end;
handle_sync_event({setopts, Options}, _From, SN, SD0) ->
	SD1 = options_set(SD0, Options),
	case SN of
		closing ->
			{reply, ok, closing, SD1, 0};
		_ ->
			{reply, ok, SN, SD1}
	end;
handle_sync_event(_Event, _From, closing, SD) ->
	{reply, {error, closed}, closing, SD, 0};
handle_sync_event({data_part, Pid, Data}, _From, reply_wait, SD=#state_data{current={{Pid, _}, _, _}}) ->
	data_send(SD, Data);
handle_sync_event({ctrl, [Command | Argument]}, From={To, Tag}, idle, SD0=#state_data{current=undefined, block=Block}) ->
	BlockFlag = case Block of
		false ->
			To ! {Tag, {ok, Tag}},
			nonblock;
		true ->
			block
	end,
	{ok, Call, SD1} = ctrl_build(SD0, From, ?INLINE_UPPERCASE_BC(Command), Argument, BlockFlag),
	ctrl_call(SD1, Call);
handle_sync_event(Event={ctrl, _}, From, SN, SD0=#state_data{calls=Calls0, block=true}) ->
	Calls1 = queue:in({From, Event, block}, Calls0),
	SD1 = SD0#state_data{calls=Calls1},
	{next_state, SN, SD1};
handle_sync_event(Event={ctrl, _}, From={_, Tag}, SN, SD0=#state_data{calls=Calls0, block=false}) ->
	Calls1 = queue:in({From, Event, nonblock}, Calls0),
	SD1 = SD0#state_data{calls=Calls1},
	{reply, {ok, Tag}, SN, SD1}.

%% @private
handle_event(flush, idle, SD0=#state_data{current=undefined, calls=Calls0}) ->
	case queue:out(Calls0) of
		{{value, {From, {ctrl, [Command | Argument]}, BlockFlag}}, Calls1} ->
			{ok, Call, SD1} = ctrl_build(SD0, From, ?INLINE_UPPERCASE_BC(Command), Argument, BlockFlag),
			SD2 = SD1#state_data{calls=Calls1},
			ctrl_call(SD2, Call);
		{empty, Calls0} ->
			{next_state, idle, SD0}
	end;
handle_event(close, _SN, SD0) ->
	SD1 = data_disconnect(SD0),
	SD2 = ctrl_disconnect(SD1),
	{stop, normal, SD2};
handle_event(flush, SN, SD) ->
	{next_state, SN, SD}.

%% @private
handle_info({OK, Socket, Data}, SN, SD=#state_data{ctrl=#ctrl{messages={OK, _, _}, socket=Socket}}) ->
	ctrl_ok(SD, SN, Data);
handle_info({OK, Socket, Data}, SN, SD=#state_data{data=#data{messages={OK, _, _}, socket=Socket}}) ->
	data_ok(SD, SN, Data);
handle_info({Closed, Socket}, SN, SD=#state_data{ctrl=#ctrl{messages={_, Closed, _}, socket=Socket}}) ->
	ctrl_closed(SD, SN);
handle_info({Closed, Socket}, SN, SD=#state_data{data=#data{messages={_, Closed, _}, socket=Socket}}) ->
	data_closed(SD, SN);
handle_info({Error, Socket, Reason}, SN, SD=#state_data{ctrl=#ctrl{messages={_, _, Error}, socket=Socket}}) ->
	ctrl_error(SD, SN, Reason);
handle_info({Error, Socket, Reason}, SN, SD=#state_data{data=#data{messages={_, _, Error}, socket=Socket}}) ->
	data_error(SD, SN, Reason);
handle_info(Info, SN, SD) ->
	error_logger:error_msg(
		"** ~p ~p unhandled info in ~p/~p in state ~p~n"
		"   Info was: ~p~n",
		[?MODULE, self(), handle_info, 3, SN, Info]),
	{next_state, SN, SD}.

%% @private
terminate(_Reason, _SN, _SD) ->
	ok.

%% @private
code_change(_OldVsn, SN, SD, _Extra) ->
	{ok, SN, SD}.

%%%===================================================================
%%% gen_fsm states
%%%===================================================================

%% @private
started({From={Owner, _Tag}, {connect, Host, Port}}, SD=#state_data{owner=Owner}) ->
	ctrl_connect(Host, Port, From, SD).

%% @private
connecting({exit, Pid, Reason, {To, Tag}}, SD=#state_data{ctrl=Pid}) ->
	To ! {Tag, {error, Reason}},
	{stop, normal, SD};
connecting({shoot, Pid, Transport, Socket, {To, Tag}}, SD=#state_data{ctrl=Pid, owner=Owner}) ->
	Pid ! {ack, self()},
	To ! {Tag, ok},
	Decode = lftpc_protocol:new_decoder(),
	Messages = Transport:messages(),
	Ctrl = #ctrl{decode=Decode, messages=Messages, socket=Socket,
		transport=Transport},
	ok = ctrl_active(Ctrl),
	Call = {{Owner, undefined}, undefined, nonblock},
	{next_state, reply_wait, SD#state_data{ctrl=Ctrl, current=Call}}.

%% @private
idle({exit, Pid, Reason, data}, SD=#state_data{data=Pid}) ->
	data_error(SD, idle, Reason);
idle({shoot, Pid, Transport, Socket, data}, SD0=#state_data{data=Pid}) ->
	SD1 = data_ack(SD0, Pid, Transport, Socket),
	{next_state, idle, SD1}.

%% @private
reply_wait({exit, Pid, Reason, data}, SD=#state_data{data=Pid}) ->
	data_error(SD, reply_wait, Reason);
reply_wait({shoot, Pid, Transport, Socket, data}, SD0=#state_data{data=Pid}) ->
	SD1 = data_ack(SD0, Pid, Transport, Socket),
	{next_state, reply_wait, SD1}.

%% @private
transfer_wait({exit, Pid, Reason, data}, SD=#state_data{data=Pid}) ->
	data_error(SD, transfer_wait, Reason);
transfer_wait({shoot, Pid, Transport, Socket, data}, SD0=#state_data{data=Pid}) ->
	SD1 = data_ack(SD0, Pid, Transport, Socket),
	case SD1#state_data.data of
		#data{} ->
			{next_state, transfer_wait, SD1};
		undefined ->
			SD2 = ctrl_done(SD1),
			{next_state, idle, SD2}
	end.

%% @private
securing({exit, Pid, Reason, data}, SD=#state_data{data=Pid}) ->
	data_error(SD, securing, Reason);
securing({shoot, Pid, Transport, Socket, data}, SD0=#state_data{data=Pid}) ->
	SD1 = data_ack(SD0, Pid, Transport, Socket),
	{next_state, securing, SD1};
securing({exit, Pid, Reason, tls}, SD=#state_data{secure=Pid}) ->
	ctrl_error(SD, securing, Reason);
securing({shoot, Pid, Transport, Socket, tls}, SD0=#state_data{ctrl=Ctrl0=#ctrl{}, secure=Pid}) ->
	Messages = Transport:messages(),
	Ctrl1 = Ctrl0#ctrl{messages=Messages, socket=Socket,
		transport=Transport},
	SD1 = SD0#state_data{ctrl=Ctrl1, secure=undefined, tls=explicit},
	ok = gen_fsm:send_all_state_event(self(), flush),
	ctrl_ok(SD1, idle, <<>>).

%% @private
closing({exit, Pid, Reason, data}, SD=#state_data{data=Pid}) ->
	data_error(SD, closing, Reason);
closing({shoot, Pid, Transport, Socket, data}, SD0=#state_data{data=Pid}) ->
	SD1 = data_ack(SD0, Pid, Transport, Socket),
	{next_state, closing, SD1, 0};
closing(timeout, SD=#state_data{queue={[],[]}}) ->
	{stop, normal, SD};
closing(timeout, SD) ->
	{next_state, closing, SD}.

%%%-------------------------------------------------------------------
%%% Control functions
%%%-------------------------------------------------------------------

%% @private
ctrl_active(#ctrl{socket=Socket, transport=Transport}) ->
	Transport:setopts(Socket, [{active, once}]),
	ok.

%% @private
ctrl_build(SD0, From, Command = <<"PORT">>, [], BlockFlag) ->
	SD1 = data_connect(SD0, active),
	Argument = data_argument(SD1),
	ctrl_build(SD1, From, Command, Argument, BlockFlag);
ctrl_build(SD0, From, Command = <<"EPRT">>, [], BlockFlag) ->
	SD1 = data_connect(SD0, extended_active),
	Argument = data_argument(SD1),
	ctrl_build(SD1, From, Command, Argument, BlockFlag);
ctrl_build(SD, From, Command, [], BlockFlag) ->
	{ok, {From, [Command, $\r, $\n], BlockFlag}, SD};
ctrl_build(SD, From, Command, Argument, BlockFlag) ->
	{ok, {From, [Command, $\s, Argument, $\r, $\n], BlockFlag}, SD}.

%% @private
ctrl_call(SD0=#state_data{ctrl=Ctrl=#ctrl{socket=Socket, transport=Transport}}, Call={{To, Tag}, Request, BlockFlag}) ->
	Transport:send(Socket, Request),
	SD1 = SD0#state_data{current=Call},
	ok = ctrl_active(Ctrl),
	ok = case BlockFlag of
		block ->
			To ! {Tag, {ok, Tag}},
			ok;
		nonblock ->
			ok
	end,
	{next_state, reply_wait, SD1}.

%% @private
ctrl_connect(Host, Port, From, SD=#state_data{tls=TLS}) ->
	FSM = self(),
	Connect = fun() ->
		Transport = case TLS of
			false ->
				ranch_tcp;
			implicit ->
				ranch_ssl
		end,
		case Transport:connect(Host, Port, []) of
			{ok, Socket} ->
				Event = {shoot, self(), Transport, Socket, From},
				ok = gen_fsm:send_event(FSM, Event),
				Transport:controlling_process(Socket, FSM),
				receive
					{ack, FSM} ->
						exit(normal)
				end;
			{error, Reason} ->
				Event = {exit, self(), Reason, From},
				ok = gen_fsm:send_event(FSM, Event),
				exit(normal)
		end
	end,
	Pid = spawn_link(Connect),
	{next_state, connecting, SD#state_data{ctrl=Pid}}.

%% @private
ctrl_disconnect(SD=#state_data{closed=true}) ->
	SD;
ctrl_disconnect(SD=#state_data{ctrl=undefined}) ->
	SD#state_data{closed=true};
ctrl_disconnect(SD=#state_data{ctrl=Pid}) when is_pid(Pid) ->
	erlang:monitor(process, Pid),
	unlink(Pid),
	exit(Pid, kill),
	receive
		{'DOWN', _, process, Pid, _} ->
			ok
	end,
	SD#state_data{ctrl=undefined, closed=true};
ctrl_disconnect(SD=#state_data{ctrl=#ctrl{socket=Socket,
		transport=Transport}}) ->
	Transport:close(Socket),
	SD#state_data{closed=true}.

%% @private
ctrl_done(SD=#state_data{current={{To, Tag}, _, _}, reply=Reply}) ->
	To ! {ftp_eod, self(), Tag, Reply},
	SD;
ctrl_done(SD=#state_data{reply=Reply}) ->
	owner_send(SD, {ftp_eod, self(), undefined, Reply}).

%% @private
ctrl_handle_reply(SD0, SN, R={421, _}) ->
	SD1 = ctrl_done(SD0#state_data{reply=R}),
	SD2 = SD1#state_data{current=undefined, reply=undefined},
	ctrl_closed(SD2, SN);
ctrl_handle_reply(SD0, reply_wait, R={C, _})
		when C =:= 125
		orelse C =:= 150 ->
	SD1 = ctrl_recv(SD0, R),
	SD2 = data_wait(SD1),
	ctrl_ok(SD2, reply_wait, <<>>);
ctrl_handle_reply(SD0, reply_wait, R={C, _})
		when C >= 100
		andalso C < 200 ->
	SD1 = ctrl_recv(SD0, R),
	ctrl_ok(SD1, reply_wait, <<>>);
ctrl_handle_reply(SD0=#state_data{current=Call, wait=false}, reply_wait, R) ->
	SD1 = ctrl_done(SD0#state_data{reply=R}),
	SD2 = SD1#state_data{current=undefined, reply=undefined},
	ok = gen_fsm:send_all_state_event(self(), flush),
	ctrl_handle_reply_done(SD2, Call, R);
ctrl_handle_reply(SD0=#state_data{wait=true}, reply_wait, R) ->
	SD1 = SD0#state_data{reply=R},
	{next_state, transfer_wait, SD1}.

%% @private
ctrl_handle_reply_done(SD0, {_, [<<"PASV">> | _], _}, {227, Text}) ->
	case lftpc_protocol:parse_pasv(iolist_to_binary(Text)) of
		{true, Peername, _} ->
			SD1 = data_disconnect(SD0),
			DTP = #dtp{connect=passive, peername=Peername},
			SD2 = SD1#state_data{dtp=DTP},
			SD3 = data_connect(SD2),
			ctrl_ok(SD3, idle, <<>>);
		false ->
			ctrl_ok(SD0, idle, <<>>)
	end;
ctrl_handle_reply_done(SD0, {_, [<<"EPSV">> | _], _}, {229, Text}) ->
	case lftpc_protocol:parse_pasv(iolist_to_binary(Text)) of
		{true, Port, _} ->
			{ok, {Host, _}} = ctrl_peername(SD0),
			Peername = {Host, Port},
			SD1 = data_disconnect(SD0),
			DTP = #dtp{connect=extended_passive, peername=Peername},
			SD2 = SD1#state_data{dtp=DTP},
			SD3 = data_connect(SD2),
			ctrl_ok(SD3, idle, <<>>);
		false ->
			ctrl_ok(SD0, idle, <<>>)
	end;
ctrl_handle_reply_done(SD, {_, [<<"AUTH">> | Tail], _}, {234, _}) ->
	case lftpc_protocol:parse_auth(?INLINE_UPPERCASE_BC(iolist_to_binary(Tail))) of
		{true, <<"TLS">>, _} ->
			ctrl_secure(SD);
		false ->
			ctrl_ok(SD, idle, <<>>)
	end;
ctrl_handle_reply_done(SD0, {_, [<<"PROT">> | Tail], _}, {Code, _})
		when Code >= 200 ->
	SD1 = case lftpc_protocol:parse_prot(?INLINE_UPPERCASE_BC(iolist_to_binary(Tail))) of
		{true, Prot, _} ->
			SD0#state_data{prot=Prot};
		false ->
			SD0#state_data{prot=false}
	end,
	ctrl_ok(SD1, idle, <<>>);
ctrl_handle_reply_done(SD, _Call, _Reply) ->
	ctrl_ok(SD, idle, <<>>).

%% @private
ctrl_peername(#state_data{ctrl=#ctrl{socket=Socket, transport=Transport}}) ->
	Transport:peername(Socket).

%% @private
ctrl_recv(SD=#state_data{current={{To, Tag}, _, _}}, R) ->
	To ! {ftp, self(), Tag, R},
	SD.

%% @private
ctrl_secure(SD=#state_data{ctrl=#ctrl{socket=S, transport=T}, tls=false}) ->
	FSM = self(),
	Secure = fun() ->
		receive
			{shoot, FSM, Transport, Socket} ->
				FSM ! {ack, self()},
				case ssl:connect(Socket, []) of
					{ok, TLSSocket} ->
						Event = {shoot, self(), Transport, TLSSocket, tls},
						ok = gen_fsm:send_event(FSM, Event),
						Transport:controlling_process(TLSSocket, FSM),
						receive
							{ack, FSM} ->
								exit(normal)
						end;
					{error, Reason} ->
						Event = {exit, self(), Reason, tls},
						ok = gen_fsm:send_event(FSM, Event),
						exit(normal)
				end
		end
	end,
	Pid = spawn_link(Secure),
	T:controlling_process(S, Pid),
	Pid ! {shoot, self(), ranch_ssl, S},
	receive
		{ack, Pid} ->
			ok
	end,
	{next_state, securing, SD#state_data{secure=Pid}}.

%% @private
ctrl_sockname(#state_data{ctrl=#ctrl{socket=Socket, transport=Transport}}) ->
	Transport:sockname(Socket).

%%%-------------------------------------------------------------------
%%% Data functions
%%%-------------------------------------------------------------------

%% @private
data_ack(SD0=#state_data{send=Send, eod=EOD, wait=Wait}, Pid,
		Transport, Socket) ->
	Pid ! {ack, self()},
	Messages = Transport:messages(),
	Data = #data{messages=Messages, socket=Socket,
		transport=Transport},
	SD1 = SD0#state_data{data=Data, send=[]},
	SD2 = data_clean(SD1),
	case Send of
		[] ->
			ok;
		_ ->
			Transport:send(Socket, Send)
	end,
	case EOD of
		false ->
			case Wait of
				false ->
					ok;
				true ->
					data_active(SD2)
			end,
			SD2;
		true ->
			SD3 = data_disconnect(SD2),
			SD3
	end.

%% @private
data_active(#state_data{data=#data{socket=Socket, transport=Transport}}) ->
	Transport:setopts(Socket, [{active, once}]),
	ok.

%% @private
data_argument(#state_data{dtp=#dtp{connect=active, sockname={{A0,A1,A2,A3}, Port}}}) ->
	<< P0,P1 >> = << Port:16/big-unsigned-integer >>,
	io_lib:format("~w,~w,~w,~w,~w,~w", [A0,A1,A2,A3,P0,P1]);
data_argument(#state_data{dtp=#dtp{connect=extended_active, sockname={{A0,A1,A2,A3}, Port}}}) ->
	io_lib:format("|1|~w.~w.~w.~w|~w|", [A0,A1,A2,A3,Port]);
data_argument(#state_data{dtp=#dtp{connect=extended_active, sockname={{A0,A1,A2,A3,A4,A5,A6,A7}, Port}}}) ->
	io_lib:format("|2|~w:~w:~w:~w:~w:~w:~w:~w|~w|", [A0,A1,A2,A3,A4,A5,A6,A7,Port]).

%% @private
data_clean(SD=#state_data{dtp=undefined}) ->
	SD;
data_clean(SD=#state_data{dtp=#dtp{socket=undefined,
		transport=undefined}}) ->
	SD;
data_clean(SD0=#state_data{dtp=DTP=#dtp{connect=C, socket=Socket,
		transport=Transport}})
		when C =:= active
		orelse C =:= extended_active ->
	Transport:close(Socket),
	SD1 = SD0#state_data{dtp=DTP#dtp{socket=undefined,
		transport=undefined}},
	SD1;
data_clean(SD) ->
	SD.

%% @private
data_connect(SD=#state_data{tls=implicit}) ->
	data_connect(SD, ranch_ssl);
data_connect(SD=#state_data{dtp=#dtp{connect=Connect}, prot=private, tls=explicit})
		when Connect =:= active
		orelse Connect =:= extended_active ->
	data_connect(SD, {ranch_tcp, ranch_ssl});
data_connect(SD=#state_data{prot=private, tls=explicit}) ->
	data_connect(SD, ranch_ssl);
data_connect(SD) ->
	data_connect(SD, ranch_tcp).

%% @private
data_connect(SD=#state_data{dtp=DTP=#dtp{connect=C}}, Transport)
		when C =:= active
		orelse C =:= extended_active ->
	FSM = self(),
	{ok, {LHost, _}} = ctrl_sockname(SD),
	ListenOpts = [{ip, LHost}],
	{ok, LSocket} = Transport:listen(ListenOpts),
	{ok, Sockname} = Transport:sockname(LSocket),
	Connect = fun() ->
		case Transport:accept(LSocket, infinity) of
			{ok, Socket} ->
				Event = {shoot, self(), Transport, Socket, data},
				ok = gen_fsm:send_event(FSM, Event),
				Transport:controlling_process(Socket, FSM),
				receive
					{ack, FSM} ->
						exit(normal)
				end;
			{error, Reason} ->
				Event = {exit, self(), Reason, data},
				ok = gen_fsm:send_event(FSM, Event),
				exit(normal)
		end
	end,
	Pid = spawn_link(Connect),
	NewDTP = DTP#dtp{socket=LSocket, sockname=Sockname,
		transport=Transport},
	SD#state_data{data=Pid, dtp=NewDTP};
data_connect(SD=#state_data{dtp=#dtp{connect=C, peername={Host, Port}}}, Transport)
		when C =:= passive
		orelse C =:= extended_passive ->
	FSM = self(),
	Connect = fun() ->
		case Transport:connect(Host, Port, []) of
			{ok, Socket} ->
				Event = {shoot, self(), Transport, Socket, data},
				ok = gen_fsm:send_event(FSM, Event),
				Transport:controlling_process(Socket, FSM),
				receive
					{ack, FSM} ->
						exit(normal)
				end;
			{error, Reason} ->
				Event = {exit, self(), Reason, data},
				ok = gen_fsm:send_event(FSM, Event),
				exit(normal)
		end
	end,
	Pid = spawn_link(Connect),
	SD#state_data{data=Pid}.

%% @private
data_disconnect(SD=#state_data{data=undefined, dtp=undefined,
		eod=false, wait=false}) ->
	SD;
data_disconnect(SD0=#state_data{data=Pid, dtp=#dtp{connect=C,
		socket=Socket, transport=Transport}}) when is_pid(Pid) ->
	erlang:monitor(process, Pid),
	unlink(Pid),
	exit(Pid, kill),
	receive
		{'DOWN', _, process, Pid, _} ->
			ok
	end,
	case C of
		_ when C =:= active orelse C =:= extended_active ->
			Transport:close(Socket);
		_ ->
			ok
	end,
	SD1 = SD0#state_data{data=undefined, dtp=undefined, eod=false,
		wait=false},
	data_disconnect(SD1);
data_disconnect(SD0=#state_data{data=#data{socket=Socket,
		transport=Transport}}) ->
	Transport:close(Socket),
	SD1 = SD0#state_data{data=undefined, dtp=undefined, eod=false,
		wait=false},
	data_disconnect(SD1).

%% @private
data_recv(SD=#state_data{current={{To, Tag}, _, _}}, R) ->
	To ! {data_part, self(), Tag, R},
	SD.

%% @private
data_send(SD=#state_data{eod=true}, _) ->
	{reply, {error, enodata}, reply_wait, SD};
data_send(SD0=#state_data{data=#data{}}, ftp_eod) ->
	SD1 = data_disconnect(SD0),
	{reply, ok, reply_wait, SD1};
data_send(SD0=#state_data{dtp=#dtp{}}, ftp_eod) ->
	SD1 = SD0#state_data{eod=true},
	{reply, ok, reply_wait, SD1};
data_send(SD=#state_data{data=undefined, dtp=undefined}, _) ->
	{reply, {error, enotconn}, reply_wait, SD};
data_send(SD=#state_data{data=#data{socket=Socket, transport=Transport}}, Data) ->
	{reply, Transport:send(Socket, Data), reply_wait, SD};
data_send(SD0=#state_data{send=Send, dtp=#dtp{}}, Data) ->
	SD1 = SD0#state_data{send=[Send, Data]},
	{reply, ok, reply_wait, SD1}.

%% @private
data_wait(SD=#state_data{wait=true}) ->
	SD;
data_wait(SD0=#state_data{data=#data{}}) ->
	SD1 = SD0#state_data{wait=true},
	ok = data_active(SD1),
	SD1;
data_wait(SD0) ->
	SD1 = SD0#state_data{wait=true},
	SD1.

%%%-------------------------------------------------------------------
%%% Socket functions
%%%-------------------------------------------------------------------

%% @private
ctrl_ok(SD, closing, <<>>) ->
	maybe_terminate(SD, closing);
ctrl_ok(SD0=#state_data{ctrl=C0=#ctrl{buffer=Buf0, decode=Dec0}}, SN, Data) ->
	case lftpc_protocol:decode(<< Buf0/binary, Data/binary >>, Dec0) of
		{true, Reply, Buf1, Dec1} ->
			C1 = C0#ctrl{buffer=Buf1, decode=Dec1},
			SD1 = SD0#state_data{ctrl=C1},
			ctrl_handle_reply(SD1, SN, Reply);
		{false, Buf1, Dec1} ->
			C1 = C0#ctrl{buffer=Buf1, decode=Dec1},
			SD1 = SD0#state_data{ctrl=C1},
			ok = ctrl_active(C1),
			{next_state, SN, SD1}
	end.

%% @private
data_ok(SD0, SN, Data) ->
	SD1 = data_recv(SD0, Data),
	ok = data_active(SD1),
	SD2 = data_wait(SD1),
	case SN of
		closing ->
			{next_state, closing, SD2, 0};
		_ ->
			{next_state, SN, SD2}
	end.

%% @private
ctrl_closed(SD0=#state_data{current={{To, Tag}, _, _}}, SN) ->
	To ! {ftp_closed, self(), Tag},
	SD1 = owner_send(SD0, {ftp_closed, self()}),
	SD2 = ctrl_disconnect(SD1),
	maybe_terminate(SD2, SN);
ctrl_closed(SD0, SN) ->
	SD1 = owner_send(SD0, {ftp_closed, self()}),
	SD2 = ctrl_disconnect(SD1),
	maybe_terminate(SD2, SN).

%% @private
data_closed(SD0=#state_data{current=Call, reply=R}, transfer_wait) ->
	SD1 = ctrl_done(SD0),
	SD2 = SD1#state_data{current=undefined, reply=undefined,
		data=undefined, dtp=undefined, eod=false, wait=false},
	ok = gen_fsm:send_all_state_event(self(), flush),
	ctrl_handle_reply_done(SD2, Call, R);
data_closed(SD0, SN) ->
	SD1 = SD0#state_data{data=undefined, dtp=undefined, eod=false,
		wait=false},
	case SN of
		closing ->
			{next_state, closing, SD1, 0};
		_ ->
			{next_state, SN, SD1}
	end.

%% @private
ctrl_error(SD0=#state_data{current={{To, Tag}, _, _}}, SN, Reason) ->
	To ! {ftp_error, self(), Tag, Reason},
	SD1 = owner_send(SD0, {ftp_error, self(), Reason}),
	SD2 = ctrl_disconnect(SD1),
	maybe_terminate(SD2, SN);
ctrl_error(SD0, SN, Reason) ->
	SD1 = owner_send(SD0, {ftp_error, self(), Reason}),
	SD2 = ctrl_disconnect(SD1),
	maybe_terminate(SD2, SN).

%% @private
data_error(SD0=#state_data{current={{To, Tag}, _, _}}, SN, Reason)
		when SN =:= reply_wait
		orelse SN =:= transfer_wait ->
	To ! {data_error, self(), Tag, Reason},
	SD1 = data_disconnect(SD0),
	data_closed(SD1, SN);
data_error(SD0, SN, _Reason) ->
	SD1 = data_disconnect(SD0),
	data_closed(SD1, SN).

%%%-------------------------------------------------------------------
%%% Options functions
%%%-------------------------------------------------------------------

%% @private
-spec bad_options([term()]) -> no_return().
bad_options(Errors) ->
	erlang:error({bad_options, Errors}).

%% @private
options_get(SD=#state_data{active=Active}, [active | Options], Acc) ->
	options_get(SD, Options, [{active, Active} | Acc]);
options_get(SD=#state_data{block=Block}, [block | Options], Acc) ->
	options_get(SD, Options, [{block, Block} | Acc]);
options_get(SD=#state_data{owner=Owner}, [owner | Options], Acc) ->
	options_get(SD, Options, [{owner, Owner} | Acc]);
options_get(SD=#state_data{prot=Prot}, [prot | Options], Acc) ->
	options_get(SD, Options, [{prot, Prot} | Acc]);
options_get(SD=#state_data{tls=TLS}, [tls | Options], Acc) ->
	options_get(SD, Options, [{tls, TLS} | Acc]);
options_get(SD, [], Acc) ->
	{SD, lists:reverse(Acc)}.

%% @private
options_set(SD0, [{active, Active} | Options]) ->
	SD1 = options_set_active(SD0, Active),
	options_set(SD1, Options);
options_set(SD0, [{block, Block} | Options]) ->
	SD1 = SD0#state_data{block=Block},
	options_set(SD1, Options);
options_set(SD0=#state_data{owner=OldOwner}, [{owner, NewOwner} | Options]) ->
	erlang:unlink(OldOwner),
	erlang:link(NewOwner),
	SD1 = SD0#state_data{owner=NewOwner},
	options_set(SD1, Options);
options_set(SD, []) ->
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

%% @private
% -spec verify_options(options(), [term()]) -> ok | none().
verify_connect_options([{active, Active} | Options], Errors)
		when Active =:= false
		orelse Active =:= once
		orelse Active =:= true ->
	verify_connect_options(Options, Errors);
verify_connect_options([{block, Block} | Options], Errors)
		when is_boolean(Block) ->
	verify_connect_options(Options, Errors);
verify_connect_options([{debug, Debug} | Options], Errors)
		when Debug =:= false
		orelse Debug =:= trace
		orelse Debug =:= true ->
	verify_connect_options(Options, Errors);
verify_connect_options([{tls, TLS} | Options], Errors)
		when TLS =:= false
		orelse TLS =:= implicit ->
	verify_connect_options(Options, Errors);
verify_connect_options([Option | Options], Errors) ->
	verify_connect_options(Options, [Option | Errors]);
verify_connect_options([], []) ->
	ok;
verify_connect_options([], Errors) ->
	bad_options(Errors).

%% @private
verify_getopts_options([O | Options], Errors)
		when O =:= active
		orelse O =:= block
		orelse O =:= owner
		orelse O =:= prot
		orelse O =:= tls ->
	verify_getopts_options(Options, Errors);
verify_getopts_options([Option | Options], Errors) ->
	verify_getopts_options(Options, [Option | Errors]);
verify_getopts_options([], []) ->
	ok;
verify_getopts_options([], Errors) ->
	bad_options(Errors).

%% @private
verify_setopts_options([{active, Active} | Options], Errors)
		when Active =:= false
		orelse Active =:= once
		orelse Active =:= true ->
	verify_setopts_options(Options, Errors);
verify_setopts_options([{block, Block} | Options], Errors)
		when is_boolean(Block) ->
	verify_setopts_options(Options, Errors);
verify_setopts_options([{owner, Owner} | Options], Errors)
		when is_pid(Owner) ->
	verify_setopts_options(Options, Errors);
verify_setopts_options([Option | Options], Errors) ->
	verify_setopts_options(Options, [Option | Errors]);
verify_setopts_options([], []) ->
	ok;
verify_setopts_options([], Errors) ->
	bad_options(Errors).

%%%-------------------------------------------------------------------
%%% Owner functions
%%%-------------------------------------------------------------------

%% @private
owner_flush(SD0=#state_data{active=once, owner=Owner, queue=Queue}) ->
	case queue:out(Queue) of
		{{value, Message}, NewQueue} ->
			Owner ! Message,
			SD1 = SD0#state_data{active=true, queue=NewQueue},
			SD2 = owner_flush(SD1),
			SD3 = SD2#state_data{active=false},
			SD3;
		{empty, Queue} ->
			SD0
	end;
owner_flush(SD0=#state_data{active=true, owner=Owner, queue=Queue}) ->
	case queue:out(Queue) of
		{{value, Message}, NewQueue} ->
			Owner ! Message,
			SD1 = SD0#state_data{queue=NewQueue},
			owner_flush(SD1);
		{empty, Queue} ->
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
owner_send(SD0=#state_data{active=false, queue=Queue}, Message) ->
	SD1 = SD0#state_data{queue=queue:in(Message, Queue)},
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
maybe_terminate(SD=#state_data{closed=true}, _) ->
	{next_state, closing, SD, 0};
maybe_terminate(SD, SN) ->
	{next_state, SN, SD}.

%% @private
sync_input(Pid, Owner, Closed) ->
	receive
		M={ftp, Pid, undefined, _Message} ->
			Owner ! M,
			sync_input(Pid, Owner, Closed);
		M={ftp_closed, Pid} ->
			Owner ! M,
			sync_input(Pid, Owner, true);
		M={ftp_eod, Pid, undefined, _Message} ->
			Owner ! M,
			sync_input(Pid, Owner, Closed);
		M={ftp_error, Pid, _Reason} ->
			Owner ! M,
			sync_input(Pid, Owner, Closed)
	after
		0 ->
			Closed
	end.
