%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
-module(lftpc_SUITE).

-include_lib("common_test/include/ct.hrl").

%% ct.
-export([all/0]).
% -export([groups/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
% -export([init_per_group/2]).
% -export([end_per_group/2]).

%% Tests.
-export([smoke/1]).

all() ->
	[
		smoke
	].

init_per_suite(Config) ->
	ok = lftpc:start(),
	Config.

end_per_suite(_Config) ->
	application:stop(lftpc),
	ok.

%%====================================================================
%% Tests
%%====================================================================

-define(FTP_TIMEOUT, 10000).

smoke(_Config) ->
	{ok, {_, Socket}} = lftpc:connect("ftp.mozilla.org", 21, []),
	{ok, _} = lftpc:login_anonymous(Socket, ?FTP_TIMEOUT, []),
	{ok, _} = lftpc:cd(Socket, <<"pub">>, ?FTP_TIMEOUT, []),
	{ok, _R} = lftpc:nlist(Socket, ?FTP_TIMEOUT, []),
	{ok, _} = lftpc:disconnect(Socket, ?FTP_TIMEOUT, []),
	ok = lftpc:close(Socket),
	ok.
