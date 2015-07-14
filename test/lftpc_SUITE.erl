%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
-module(lftpc_SUITE).

-include_lib("common_test/include/ct.hrl").

%% ct.
-export([all/0]).
-export([groups/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([init_per_group/2]).
-export([end_per_group/2]).

%% Tests.
-export([ftp/1]).
-export([ftp_explicit/1]).
-export([ftp_implicit/1]).

all() ->
	[
		{group, mozilla}%,
		% {group, rebex}
	].

groups() ->
	[
		{mozilla, [parallel], [
			ftp
		]}%,
		% {rebex, [parallel], [
		% 	ftp,
		% 	ftp_explicit,
		% 	ftp_implicit
		% ]}
	].

init_per_suite(Config) ->
	ok = lftpc:start(),
	Config.

end_per_suite(_Config) ->
	application:stop(lftpc),
	ok.

init_per_group(mozilla, Config) ->
	[
		{ftp_host, "ftp.mozilla.org"},
		{ftp_credentials, anonymous},
		{ftp_directory, <<"pub">>}
		| Config
	];
init_per_group(rebex, Config) ->
	[
		{ftp_host, "test.rebex.net"},
		{ftp_credentials, [
			{username, <<"demo">>},
			{password, <<"password">>}
		]},
		{ftp_directory, <<"pub">>}
		| Config
	].

end_per_group(_Group, _Config) ->
	ok.

%%====================================================================
%% Tests
%%====================================================================

ftp(Config) ->
	ftp_smoke(21, [], Config).

ftp_explicit(Config) ->
	ftp_smoke(21, [{tls, explicit}], Config).

ftp_implicit(Config) ->
	ftp_smoke(990, [{tls, implicit}], Config).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

-define(FTP_TIMEOUT, 10000).

%% @private
ftp_smoke(Port, Options, Config) ->
	Host = ?config(ftp_host, Config),
	Credentials = ?config(ftp_credentials, Config),
	Directory = ?config(ftp_directory, Config),
	ftp_smoke(Host, Port, Credentials, Options, Directory).

%% @private
ftp_smoke(Host, Port, Credentials, Options, Directory) ->
	{ok, {_, _, Socket}} = lftpc:connect(Host, Port, Options),
	{ok, _} = case Credentials of
		anonymous ->
			lftpc:login_anonymous(Socket, ?FTP_TIMEOUT, []);
		_ ->
			lftpc:login(Socket, Credentials, ?FTP_TIMEOUT, [])
	end,
	{ok, _} = lftpc:cd(Socket, Directory, ?FTP_TIMEOUT, []),
	{ok, _R} = lftpc:nlist(Socket, ?FTP_TIMEOUT, []),
	{ok, _} = lftpc:disconnect(Socket, ?FTP_TIMEOUT, []),
	ok = lftpc:close(Socket),
	erlang:monitor(process, Socket),
	ok = receive
		{'DOWN', _, process, Socket, _} ->
			ok
	end,
	ok.
