%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <andrew@pixid.com>
%%% @copyright 2014, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  09 Dec 2014 by Andrew Bennett <andrew@pixid.com>
%%%-------------------------------------------------------------------
-module(lftpc_server).
-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([add_sock/1]).
-export([get_transfer_mode/1]).
-export([set_transfer_mode/2]).

%% gen_server callbacks
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

%% Records
-type monitors() :: [{{reference(), pid()}, any()}].
-record(state, {
	monitors = [] :: monitors()
}).

%% Macros
-define(SERVER, ?MODULE).
-define(TAB, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================

start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

add_sock(Pid) ->
	gen_server:call(?SERVER, {add_sock, Pid}).

get_transfer_mode(Pid) ->
	ets:lookup_element(?TAB, {transfer_mode, Pid}, 2).

set_transfer_mode(Pid, Mode)
		when Mode =:= passive
		orelse Mode =:= active
		orelse Mode =:= extended_passive
		orelse Mode =:= extended_active ->
	gen_server:call(?SERVER, {set_transfer_mode, Pid, Mode}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
init([]) ->
	Monitors = [{{erlang:monitor(process, Pid), Pid}, Ref} ||
		[Ref, Pid] <- ets:match(?TAB, {{sock, '$1'}, '$2'})],
	{ok, #state{monitors=Monitors}}.

%% @private
handle_call({add_sock, Pid}, _From, State=#state{monitors=Monitors}) ->
	case ets:insert_new(?TAB, {{sock, Pid}, Pid}) of
		true ->
			true = ets:insert(?TAB, {{transfer_mode, Pid}, passive}),
			MonitorRef = erlang:monitor(process, Pid),
			Monitors2 = [{{MonitorRef, Pid}, Pid} | Monitors],
			{reply, true, State#state{monitors=Monitors2}};
		false ->
			{reply, false, State}
	end;
handle_call({set_transfer_mode, Pid, Mode}, _From, State) ->
	true = ets:insert(?TAB, {{transfer_mode, Pid}, Mode}),
	{reply, ok, State};
handle_call(_Request, _From, State) ->
	{reply, ignore, State}.

%% @private
handle_cast(_Request, State) ->
	{noreply, State}.

%% @private
handle_info({'DOWN', MonitorRef, process, Pid, _}, State=#state{monitors=Monitors}) ->
	{_, Ref} = lists:keyfind({MonitorRef, Pid}, 1, Monitors),
	true = ets:delete(?TAB, {sock, Ref}),
	true = ets:delete(?TAB, {transfer_mode, Ref}),
	Monitors2 = lists:keydelete({MonitorRef, Pid}, 1, Monitors),
	{noreply, State#state{monitors=Monitors2}};
handle_info(_Info, State) ->
	{noreply, State}.

%% @private
terminate(_Reason, _State) ->
	ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

% handle_call({set_session_opts, Ref, })

% handle_call({set_new_listener_opts, Ref, MaxConns, Opts}, _, State) ->
% 	ets:insert(?TAB, {{max_conns, Ref}, MaxConns}),
% 	ets:insert(?TAB, {{opts, Ref}, Opts}),
% 	{reply, ok, State};
% handle_call({set_connections_sup, Ref, Pid}, _,
% 		State=#state{monitors=Monitors}) ->
% 	case ets:insert_new(?TAB, {{conns_sup, Ref}, Pid}) of
% 		true ->
% 			MonitorRef = erlang:monitor(process, Pid),
% 			{reply, true,
% 				State#state{monitors=[{{MonitorRef, Pid}, Ref}|Monitors]}};
% 		false ->
% 			{reply, false, State}
% 	end;
% handle_call({set_port, Ref, Port}, _, State) ->
% 	true = ets:insert(?TAB, {{port, Ref}, Port}),
% 	{reply, ok, State};
% handle_call({set_max_conns, Ref, MaxConns}, _, State) ->
% 	ets:insert(?TAB, {{max_conns, Ref}, MaxConns}),
% 	ConnsSup = get_connections_sup(Ref),
% 	ConnsSup ! {set_max_conns, MaxConns},
% 	{reply, ok, State};
% handle_call({set_opts, Ref, Opts}, _, State) ->
% 	ets:insert(?TAB, {{opts, Ref}, Opts}),
% 	ConnsSup = get_connections_sup(Ref),
% 	ConnsSup ! {set_opts, Opts},
% 	{reply, ok, State};
% handle_call(_Request, _From, State) ->
% 	{reply, ignore, State}.
