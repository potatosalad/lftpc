%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <andrew@pixid.com>
%%% @copyright 2014, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  22 Nov 2014 by Andrew Bennett <andrew@pixid.com>
%%%-------------------------------------------------------------------
-module(lftpc).

-include("lftpc_types.hrl").

%% API exports
-export([request/3]).
-export([request/4]).
-export([request/5]).
-export([request/6]).
-export([send_data_part/2]).
-export([send_data_part/3]).

%% Socket API
-export([close/1]).
-export([getopts/2]).
-export([setopts/2]).

%% Utility API
-export([require/1]).
-export([start/0]).

%% High-level FTP API
-export([abort/3]).
-export([append/5]).
-export([auth_tls/2]).
-export([cd/4]).
-export([cdup/3]).
-export([connect/3]).
-export([connect/4]).
-export([delete/4]).
-export([disconnect/3]).
-export([features/3]).
-export([keep_alive/3]).
-export([login_anonymous/3]).
-export([login/4]).
-export([ls/3]).
-export([ls/4]).
-export([mkdir/4]).
-export([nlist/3]).
-export([nlist/4]).
-export([pwd/3]).
-export([rename/5]).
-export([restart/5]).
-export([retrieve/4]).
-export([rmdir/4]).
-export([start_transfer/3]).
-export([store/5]).
-export([system_type/3]).
-export([transfer_mode/2]).
-export([type/4]).

%% Low-level FTP API
-export([ftp_abor/3]).
-export([ftp_acct/4]).
-export([ftp_adat/4]).
-export([ftp_allo/4]).
-export([ftp_allo/5]).
-export([ftp_appe/5]).
-export([ftp_auth/4]).
-export([ftp_cdup/3]).
-export([ftp_cwd/4]).
-export([ftp_dele/4]).
-export([ftp_eprt/3]).
-export([ftp_eprt/4]).
-export([ftp_epsv/3]).
-export([ftp_feat/3]).
-export([ftp_help/3]).
-export([ftp_help/4]).
-export([ftp_list/3]).
-export([ftp_list/4]).
-export([ftp_mdtm/4]).
-export([ftp_mkd/4]).
-export([ftp_mlsd/3]).
-export([ftp_mlsd/4]).
-export([ftp_mlst/3]).
-export([ftp_mlst/4]).
-export([ftp_mode/4]).
-export([ftp_nlst/3]).
-export([ftp_nlst/4]).
-export([ftp_noop/3]).
-export([ftp_pass/4]).
-export([ftp_pasv/3]).
-export([ftp_pbsz/4]).
-export([ftp_port/3]).
-export([ftp_port/4]).
-export([ftp_prot/4]).
-export([ftp_pwd/3]).
-export([ftp_quit/3]).
-export([ftp_rein/3]).
-export([ftp_rest/4]).
-export([ftp_retr/4]).
-export([ftp_rmd/4]).
-export([ftp_rnfr/4]).
-export([ftp_rnto/4]).
-export([ftp_site/4]).
-export([ftp_size/4]).
-export([ftp_smnt/4]).
-export([ftp_stat/3]).
-export([ftp_stat/4]).
-export([ftp_stor/5]).
-export([ftp_stou/3]).
-export([ftp_syst/3]).
-export([ftp_type/4]).
-export([ftp_user/4]).

%%====================================================================
%% API functions
%%====================================================================

request(Socket, Command, Timeout) ->
	request(Socket, Command, undefined, undefined, Timeout, []).

request(Socket, Command, Argument, Timeout) ->
	request(Socket, Command, Argument, undefined, Timeout, []).

request(Socket, Command, Argument, Data, Timeout) ->
	request(Socket, Command, Argument, Data, Timeout, []).

request(Socket, Command, Argument, Data, Timeout, Options) ->
	ok = verify_options(Options, []),
	ReqId = now(),
	case proplists:is_defined(stream_to, Options) of
		true ->
			StreamTo = proplists:get_value(stream_to, Options),
			Args = [ReqId, StreamTo, Socket, Command, Argument, Data, Options],
			Pid = spawn(lftpc_client, request, Args),
			spawn(fun() ->
				R = kill_client_after(Pid, Timeout),
				StreamTo ! {response, ReqId, Pid, R}
			end),
			{ReqId, Pid};
		false ->
			Args = [ReqId, self(), Socket, Command, Argument, Data, Options],
			Pid = spawn_link(lftpc_client, request, Args),
			receive
				{response, ReqId, Pid, R} ->
					R;
				{exit, ReqId, Pid, Reason} ->
					exit(Reason);
				{'EXIT', Pid, Reason} ->
					exit(Reason)
			after
				Timeout ->
					kill_client(Pid)
			end
	end.

send_data_part({Pid, Window}, Data) ->
	send_data_part({Pid, Window}, Data, infinity).

send_data_part({Pid, _Window}, ftp_eod, Timeout) when is_pid(Pid) ->
	Pid ! {data_part, self(), ftp_eod},
	read_client_response(Pid, Timeout);
send_data_part({Pid, 0}, Data, Timeout) when is_pid(Pid) ->
	receive
		{ack, Pid} ->
			send_data_part({Pid, 1}, Data, Timeout);
		{ftp_eod, Pid, R} ->
			{ok, R};
		{ftp_error, Pid, Reason} ->
			{error, Reason};
		{ftp_closed, Pid} ->
			{error, closed};
		{response, _ReqId, Pid, R} ->
			R;
		{exit, _ReqId, Pid, Reason} ->
			exit(Reason);
		{'EXIT', Pid, Reason} ->
			exit(Reason)
	after
		Timeout ->
			kill_client(Pid)
	end;
send_data_part({Pid, Window}, Data, _Timeout) when is_pid(Pid) ->
	Pid ! {data_part, self(), Data},
	receive
		{ack, Pid} ->
			{ok, {Pid, Window}};
		{ftp_eod, Pid, R} ->
			{ok, R};
		{ftp_error, Pid, Reason} ->
			{error, Reason};
		{ftp_closed, Pid} ->
			{error, closed};
		{response, _ReqId, Pid, R} ->
			R;
		{exit, _ReqId, Pid, Reason} ->
			exit(Reason);
		{'EXIT', Pid, Reason} ->
			exit(Reason)
	after
		0 ->
			case Window of
				_ when is_integer(Window) andalso Window > 0 ->
					{ok, {Pid, Window - 1}};
				_ ->
					{ok, {Pid, Window}}
			end
	end.

%%====================================================================
%% Socket API functions
%%====================================================================

close(Socket) ->
	lftpc_sock:close(Socket).

getopts(Socket, Options) ->
	lftpc_sock:getopts(Socket, Options).

setopts(Socket, Options) ->
	lftpc_sock:setopts(Socket, Options).

%%====================================================================
%% Utility API functions
%%====================================================================

require([]) ->
	ok;
require([App | Apps]) ->
	case application:ensure_started(App) of
		ok ->
			require(Apps);
		StartError ->
			StartError
	end.

start() ->
	_ = application:load(?MODULE),
	{ok, Apps} = application:get_key(?MODULE, applications),
	case require(Apps) of
		ok ->
			application:ensure_started(?MODULE);
		StartError ->
			StartError
	end.

%%%===================================================================
%%% High-level FTP API functions
%%%===================================================================

abort(Socket, Timeout, Options) ->
	case ftp_abor(Socket, Timeout, Options) of
		{ok, AborResponse} ->
			ok = lftpc_sock:close(Socket),
			case is_ftp_between(AborResponse, 200, 500) of
				true ->
					{ok, AborResponse};
				false ->
					{error, {badreply, [AborResponse]}}
			end;
		AborSocketError ->
			AborSocketError
	end.

append(Socket, Pathname, Data, Timeout, Options) ->
	case start_transfer(Socket, Timeout, Options) of
		{ok, _} ->
			case ftp_appe(Socket, Pathname, Data, Timeout, Options) of
				{ok, AppeResponse={_, {Pid, _}}} when is_pid(Pid) ->
					{ok, AppeResponse};
				{ok, AppeResponse} ->
					case is_ftp_between(AppeResponse, 200, 300) of
						true ->
							{ok, AppeResponse};
						false ->
							{error, {badreply, [AppeResponse]}}
					end;
				AppeSocketError ->
					AppeSocketError
			end;
		StartTransferError ->
			StartTransferError
	end.

auth_tls(Socket, Timeout) ->
	maybe_auth_tls(Socket, explicit, Timeout).

cd(Socket, Directory, Timeout, Options) ->
	Opts = [{K, V} || {K, V} <- Options, K =:= send_retry],
	case ftp_cwd(Socket, Directory, Timeout, Opts) of
		{ok, CwdResponse} ->
			case is_ftp_code(CwdResponse, 250) of
				true ->
					{ok, CwdResponse};
				false ->
					{error, {badreply, [CwdResponse]}}
			end;
		CwdSocketError ->
			CwdSocketError
	end.

cdup(Socket, Timeout, Options) ->
	Opts = [{K, V} || {K, V} <- Options, K =:= send_retry],
	case ftp_cdup(Socket, Timeout, Opts) of
		{ok, CdupResponse} ->
			case is_ftp_code(CdupResponse, 250) of
				true ->
					{ok, CdupResponse};
				false ->
					{error, {badreply, [CdupResponse]}}
			end;
		CdupSocketError ->
			CdupSocketError
	end.

connect(Host, Port, Options) ->
	connect(Host, Port, Options, infinity).

connect(Host, Port, Options, Timeout) ->
	{TLS, Opts} = case lists:keytake(tls, 1, Options) of
		{value, {tls, explicit}, O0} ->
			{explicit, O0};
		{value, {tls, implicit}, _} ->
			{implicit, Options};
		_ ->
			{false, Options}
	end,
	case lftpc_sock:connect(Host, Port, Opts, Timeout) of
		{ok, Socket} ->
			case read_sock_response(Socket, [], Timeout) of
				{ok, {Pre, Post={C, _}, Socket}} when C >= 200 andalso C < 400 ->
					case maybe_auth_tls(Socket, TLS, Timeout) of
						ok ->
							{ok, {Pre, Post, Socket}};
						TLSError ->
							ok = lftpc_sock:close(Socket),
							TLSError
					end;
				{ok, {Pre, Post, Socket}} ->
					ok = lftpc_sock:close(Socket),
					{error, {badreply, [{Pre, Post, undefined}]}};
				{error, Reason} ->
					ok = lftpc_sock:close(Socket),
					{error, Reason}
			end;
		ConnectError ->
			ConnectError
	end.

delete(Socket, Filename, Timeout, Options) ->
	Opts = [{K, V} || {K, V} <- Options, K =:= send_retry],
	case ftp_dele(Socket, Filename, Timeout, Opts) of
		{ok, DeleResponse} ->
			case is_ftp_code(DeleResponse, 250) of
				true ->
					{ok, DeleResponse};
				false ->
					{error, {badreply, [DeleResponse]}}
			end;
		DeleSocketError ->
			DeleSocketError
	end.

disconnect(Socket, Timeout, Options) ->
	Opts = [{K, V} || {K, V} <- Options, K =:= send_retry],
	case ftp_quit(Socket, Timeout, Opts) of
		{ok, QuitResponse} ->
			case is_ftp_between(QuitResponse, 200, 400) of
				true ->
					{ok, QuitResponse};
				false ->
					{error, {badreply, [QuitResponse]}}
			end;
		QuitSocketError ->
			QuitSocketError
	end.

features(Socket, Timeout, Options) ->
	Opts = [{K, V} || {K, V} <- Options, K =:= send_retry],
	case ftp_feat(Socket, Timeout, Opts) of
		{ok, FeatResponse} ->
			case is_ftp_code(FeatResponse, 211) of
				true ->
					{ok, FeatResponse};
				false ->
					{error, {badreply, [FeatResponse]}}
			end;
		FeatSocketError ->
			FeatSocketError
	end.

keep_alive(Socket, Timeout, Options) ->
	Opts = [{K, V} || {K, V} <- Options, K =:= send_retry],
	case ftp_noop(Socket, Timeout, Opts) of
		{ok, NoopResponse} ->
			case is_ftp_between(NoopResponse, 200, 400) of
				true ->
					{ok, NoopResponse};
				false ->
					{error, {badreply, [NoopResponse]}}
			end;
		NoopSocketError ->
			NoopSocketError
	end.

mkdir(Socket, Directory, Timeout, Options) ->
	Opts = [{K, V} || {K, V} <- Options, K =:= send_retry],
	case ftp_mkd(Socket, Directory, Timeout, Opts) of
		{ok, MkdResponse} ->
			case is_ftp_code(MkdResponse, 257) of
				true ->
					{ok, MkdResponse};
				false ->
					{error, {badreply, [MkdResponse]}}
			end;
		MkdSocketError ->
			MkdSocketError
	end.

login_anonymous(Socket, Timeout, Options) ->
	Credentials = [
		{username, <<"anonymous">>},
		{password, <<>>}
	],
	login(Socket, Credentials, Timeout, Options).

login(Socket, Credentials, Timeout, Options) ->
	ok = verify_credentials(Credentials, []),
	Username = proplists:get_value(username, Credentials),
	Password = proplists:get_value(password, Credentials),
	Account = proplists:get_value(accout, Credentials),
	Opts = [{K, V} || {K, V} <- Options, K =:= send_retry],
	UserFunction = fun
		(undefined) ->
			{ok, []};
		(User) ->
			case ftp_user(Socket, User, Timeout, Opts) of
				{ok, UserResponse} ->
					case is_ftp_between(UserResponse, 200, 400) of
						true ->
							{ok, [UserResponse]};
						false ->
							{error, {badreply, [UserResponse]}}
					end;
				UserSocketError ->
					UserSocketError
			end
	end,
	PassFunction = fun
		(undefined) ->
			{ok, []};
		(Pass) ->
			case ftp_pass(Socket, Pass, Timeout, Opts) of
				{ok, PassResponse} ->
					case is_ftp_between(PassResponse, 200, 400) of
						true ->
							{ok, [PassResponse]};
						false ->
							{error, {badreply, [PassResponse]}}
					end;
				PassSocketError ->
					PassSocketError
			end
	end,
	AcctFunction = fun
		(undefined) ->
			{ok, []};
		(Acct) ->
			case ftp_acct(Socket, Acct, Timeout, Opts) of
				{ok, AcctResponse} ->
					case is_ftp_between(AcctResponse, 200, 400) of
						true ->
							{ok, [AcctResponse]};
						false ->
							{error, {badreply, [AcctResponse]}}
					end;
				AcctSocketError ->
					AcctSocketError
			end
	end,
	case UserFunction(Username) of
		{ok, UserResult} ->
			case PassFunction(Password) of
				{ok, PassResult} ->
					case AcctFunction(Account) of
						{ok, AcctResult} ->
							{ok, UserResult ++ PassResult ++ AcctResult};
						AcctError ->
							AcctError
					end;
				PassError ->
					PassError
			end;
		UserError ->
			UserError
	end.

ls(Socket, Timeout, Options) ->
	ls(Socket, undefined, Timeout, Options).

ls(Socket, Pathname, Timeout, Options) ->
	case start_transfer(Socket, Timeout, Options) of
		{ok, _} ->
			case ftp_list(Socket, Pathname, Timeout, Options) of
				{ok, ListResponse={_, Pid}} when is_pid(Pid) ->
					{ok, ListResponse};
				{ok, ListResponse} ->
					case is_ftp_between(ListResponse, 200, 400) of
						true ->
							{ok, ListResponse};
						false ->
							{error, {badreply, [ListResponse]}}
					end;
				ListSocketError ->
					ListSocketError
			end;
		StartTransferError ->
			StartTransferError
	end.

nlist(Socket, Timeout, Options) ->
	nlist(Socket, undefined, Timeout, Options).

nlist(Socket, Pathname, Timeout, Options) ->
	case start_transfer(Socket, Timeout, Options) of
		{ok, _} ->
			case ftp_nlst(Socket, Pathname, Timeout, Options) of
				{ok, NlstResponse={_, Pid}} when is_pid(Pid) ->
					{ok, NlstResponse};
				{ok, NlstResponse} ->
					case is_ftp_between(NlstResponse, 200, 300) of
						true ->
							{ok, NlstResponse};
						false ->
							{error, {badreply, [NlstResponse]}}
					end;
				NlstSocketError ->
					NlstSocketError
			end;
		StartTransferError ->
			StartTransferError
	end.

pwd(Socket, Timeout, Options) ->
	Opts = [{K, V} || {K, V} <- Options, K =:= send_retry],
	case ftp_pwd(Socket, Timeout, Opts) of
		{ok, PwdResponse} ->
			case is_ftp_between(PwdResponse, 200, 400) of
				true ->
					{ok, PwdResponse};
				false ->
					{error, {badreply, [PwdResponse]}}
			end;
		PwdSocketError ->
			PwdSocketError
	end.

rename(Socket, Old, New, Timeout, Options) ->
	Opts = [{K, V} || {K, V} <- Options, K =:= send_retry],
	case ftp_rnfr(Socket, Old, Timeout, Opts) of
		{ok, RnfrResponse} ->
			case is_ftp_between(RnfrResponse, 300, 400) of
				true ->
					case ftp_rnto(Socket, New, Timeout, Opts) of
						{ok, RntoResponse} ->
							case is_ftp_between(RntoResponse, 200, 400) of
								true ->
									{ok, [RnfrResponse, RntoResponse]};
								false ->
									{error, {badreply, [RnfrResponse, RntoResponse]}}
							end;
						RntoSocketError ->
							RntoSocketError
					end;
				false ->
					{error, {badreply, [RnfrResponse]}}
			end;
		RnfrSocketError ->
			RnfrSocketError
	end.

restart(Socket, Pathname, Offset, Timeout, Options) ->
	Opts = [{K, V} || {K, V} <- Options, K =:= send_retry],
	case start_transfer(Socket, Timeout, Options) of
		{ok, _} ->
			case ftp_rest(Socket, Offset, Timeout, Opts) of
				{ok, RestResponse} ->
					case is_ftp_between(RestResponse, 200, 400) of
						true ->
							case ftp_retr(Socket, Pathname, Timeout, Options) of
								{ok, RetrResponse={_, Pid}} when is_pid(Pid) ->
									{ok, RetrResponse};
								{ok, RetrResponse} ->
									case is_ftp_between(RetrResponse, 200, 400) of
										true ->
											{ok, RetrResponse};
										false ->
											{error, {badreply, [RetrResponse]}}
									end;
								RetrSocketError ->
									RetrSocketError
							end;
						false ->
							{error, {badreply, [RestResponse]}}
					end;
				RestSocketError ->
					RestSocketError
			end;
		StartTransferError ->
			StartTransferError
	end.

retrieve(Socket, Pathname, Timeout, Options) ->
	case start_transfer(Socket, Timeout, Options) of
		{ok, _} ->
			case ftp_retr(Socket, Pathname, Timeout, Options) of
				{ok, RetrResponse={_, Pid}} when is_pid(Pid) ->
					{ok, RetrResponse};
				{ok, RetrResponse} ->
					case is_ftp_between(RetrResponse, 200, 400) of
						true ->
							{ok, RetrResponse};
						false ->
							{error, {badreply, [RetrResponse]}}
					end;
				RetrSocketError ->
					RetrSocketError
			end;
		StartTransferError ->
			StartTransferError
	end.

rmdir(Socket, Directory, Timeout, Options) ->
	case ftp_rmd(Socket, Directory, Timeout, Options) of
		{ok, RmdResponse} ->
			case is_ftp_code(RmdResponse, 250) of
				true ->
					{ok, RmdResponse};
				false ->
					{error, {badreply, [RmdResponse]}}
			end;
		RmdSocketError ->
			RmdSocketError
	end.

start_transfer(Socket, Timeout, Options) ->
	Command = case lftpc_server:get_transfer_mode(Socket) of
		passive ->
			<<"PASV">>;
		active ->
			<<"PORT">>;
		extended_passive ->
			<<"EPSV">>;
		extended_active ->
			<<"EPRT">>
	end,
	Opts = [{K, V} || {K, V} <- Options, K =:= send_retry],
	case request(Socket, Command, undefined, undefined, Timeout, Opts) of
		{ok, Response} ->
			case is_ftp_between(Response, 200, 400) of
				true ->
					{ok, Response};
				false ->
					{error, {badreply, [Response]}}
			end;
		SocketError ->
			SocketError
	end.

store(Socket, Pathname, Data, Timeout, Options) ->
	case start_transfer(Socket, Timeout, Options) of
		{ok, _} ->
			case ftp_stor(Socket, Pathname, Data, Timeout, Options) of
				{ok, StorResponse={_, {Pid, _}}} when is_pid(Pid) ->
					{ok, StorResponse};
				{ok, StorResponse} ->
					case is_ftp_between(StorResponse, 200, 400) of
						true ->
							{ok, StorResponse};
						false ->
							{error, {badreply, [StorResponse]}}
					end;
				StorSocketError ->
					StorSocketError
			end;
		StartTransferError ->
			StartTransferError
	end.

system_type(Socket, Timeout, Options) ->
	case ftp_syst(Socket, Timeout, Options) of
		{ok, SystResponse} ->
			case is_ftp_between(SystResponse, 200, 400) of
				true ->
					{ok, SystResponse};
				false ->
					{error, {badreply, [SystResponse]}}
			end;
		SystSocketError ->
			SystSocketError
	end.

transfer_mode(Socket, Mode) ->
	lftpc_sever:set_transfer_mode(Socket, Mode).

type(Socket, Type, Timeout, Options)
		when Type =:= ascii
		orelse Type =:= binary ->
	TypeCode = case Type of
		ascii ->
			$A;
		binary ->
			$I
	end,
	Opts = [{K, V} || {K, V} <- Options, K =:= send_retry],
	case ftp_type(Socket, TypeCode, Timeout, Opts) of
		{ok, TypeResponse} ->
			case is_ftp_between(TypeResponse, 200, 400) of
				true ->
					{ok, TypeResponse};
				false ->
					{error, {badreply, [TypeResponse]}}
			end;
		TypeSocketError ->
			TypeSocketError
	end.

%%%===================================================================
%%% Low-level FTP API functions
%%%===================================================================

ftp_abor(Socket, Timeout, Options) ->
	request(Socket, <<"ABOR">>, undefined, undefined, Timeout, Options).

ftp_acct(Socket, Account, Timeout, Options) ->
	request(Socket, <<"ACCT">>, Account, undefined, Timeout, Options).

ftp_adat(Socket, Base64Data, Timeout, Options) ->
	request(Socket, <<"ADAT">>, Base64Data, undefined, Timeout, Options).

ftp_allo(Socket, NumberOfBytes, Timeout, Options) ->
	request(Socket, <<"ALLO">>, NumberOfBytes, undefined, Timeout, Options).

ftp_allo(Socket, NumberOfBytes, PageSize, Timeout, Options) ->
	request(Socket, <<"ALLO">>, [NumberOfBytes, $\s, $R, $\s, PageSize], undefined, Timeout, Options).

ftp_appe(Socket, Pathname, Data, Timeout, Options) ->
	request(Socket, <<"APPE">>, Pathname, Data, Timeout, Options).

ftp_auth(Socket, MechanismName, Timeout, Options) ->
	request(Socket, <<"AUTH">>, MechanismName, undefined, Timeout, Options).

ftp_cdup(Socket, Timeout, Options) ->
	request(Socket, <<"CDUP">>, undefined, undefined, Timeout, Options).

ftp_cwd(Socket, Directory, Timeout, Options) ->
	request(Socket, <<"CWD">>, Directory, undefined, Timeout, Options).

ftp_dele(Socket, Pathname, Timeout, Options) ->
	request(Socket, <<"DELE">>, Pathname, undefined, Timeout, Options).

ftp_eprt(Socket, Timeout, Options) ->
	request(Socket, <<"EPRT">>, undefined, undefined, Timeout, Options).

ftp_eprt(Socket, Address, Timeout, Options) ->
	request(Socket, <<"EPRT">>, Address, undefined, Timeout, Options).

ftp_epsv(Socket, Timeout, Options) ->
	request(Socket, <<"EPSV">>, undefined, undefined, Timeout, Options).

ftp_feat(Socket, Timeout, Options) ->
	request(Socket, <<"FEAT">>, undefined, undefined, Timeout, Options).

ftp_help(Socket, Timeout, Options) ->
	request(Socket, <<"HELP">>, undefined, undefined, Timeout, Options).

ftp_help(Socket, Command, Timeout, Options) ->
	request(Socket, <<"CDUP">>, Command, undefined, Timeout, Options).

ftp_list(Socket, Timeout, Options) ->
	request(Socket, <<"LIST">>, undefined, undefined, Timeout, Options).

ftp_list(Socket, Pathname, Timeout, Options) ->
	request(Socket, <<"LIST">>, Pathname, undefined, Timeout, Options).

ftp_mdtm(Socket, Pathname, Timeout, Options) ->
	request(Socket, <<"MDTM">>, Pathname, undefined, Timeout, Options).

ftp_mkd(Socket, Pathname, Timeout, Options) ->
	request(Socket, <<"MKD">>, Pathname, undefined, Timeout, Options).

ftp_mlsd(Socket, Timeout, Options) ->
	request(Socket, <<"MLSD">>, undefined, undefined, Timeout, Options).

ftp_mlsd(Socket, Pathname, Timeout, Options) ->
	request(Socket, <<"MLSD">>, Pathname, undefined, Timeout, Options).

ftp_mlst(Socket, Timeout, Options) ->
	request(Socket, <<"MLST">>, undefined, undefined, Timeout, Options).

ftp_mlst(Socket, Pathname, Timeout, Options) ->
	request(Socket, <<"MLST">>, Pathname, undefined, Timeout, Options).

ftp_mode(Socket, ModeCode, Timeout, Options) ->
	request(Socket, <<"MODE">>, ModeCode, undefined, Timeout, Options).

ftp_nlst(Socket, Timeout, Options) ->
	request(Socket, <<"NLST">>, undefined, undefined, Timeout, Options).

ftp_nlst(Socket, Pathname, Timeout, Options) ->
	request(Socket, <<"NLST">>, Pathname, undefined, Timeout, Options).

ftp_noop(Socket, Timeout, Options) ->
	request(Socket, <<"NOOP">>, undefined, undefined, Timeout, Options).

ftp_pass(Socket, Password, Timeout, Options) ->
	request(Socket, <<"PASS">>, Password, undefined, Timeout, Options).

ftp_pasv(Socket, Timeout, Options) ->
	request(Socket, <<"PASV">>, undefined, undefined, Timeout, Options).

ftp_pbsz(Socket, ProtBufSize, Timeout, Options) ->
	request(Socket, <<"PBSZ">>, ProtBufSize, undefined, Timeout, Options).

ftp_port(Socket, Timeout, Options) ->
	request(Socket, <<"PORT">>, undefined, undefined, Timeout, Options).

ftp_port(Socket, Address, Timeout, Options) ->
	request(Socket, <<"PORT">>, Address, undefined, Timeout, Options).

ftp_prot(Socket, ProtCode, Timeout, Options) ->
	request(Socket, <<"PROT">>, ProtCode, undefined, Timeout, Options).

ftp_pwd(Socket, Timeout, Options) ->
	request(Socket, <<"PWD">>, undefined, undefined, Timeout, Options).

ftp_quit(Socket, Timeout, Options) ->
	request(Socket, <<"QUIT">>, undefined, undefined, Timeout, Options).

ftp_rein(Socket, Timeout, Options) ->
	request(Socket, <<"REIN">>, undefined, undefined, Timeout, Options).

ftp_rest(Socket, Marker, Timeout, Options) ->
	request(Socket, <<"REST">>, Marker, undefined, Timeout, Options).

ftp_retr(Socket, Pathname, Timeout, Options) ->
	request(Socket, <<"RETR">>, Pathname, undefined, Timeout, Options).

ftp_rmd(Socket, Pathname, Timeout, Options) ->
	request(Socket, <<"RMD">>, Pathname, undefined, Timeout, Options).

ftp_rnfr(Socket, Pathname, Timeout, Options) ->
	request(Socket, <<"RNFR">>, Pathname, undefined, Timeout, Options).

ftp_rnto(Socket, Pathname, Timeout, Options) ->
	request(Socket, <<"RNTO">>, Pathname, undefined, Timeout, Options).

ftp_site(Socket, Argument, Timeout, Options) ->
	request(Socket, <<"SITE">>, Argument, undefined, Timeout, Options).

ftp_size(Socket, Pathname, Timeout, Options) ->
	request(Socket, <<"SIZE">>, Pathname, undefined, Timeout, Options).

ftp_smnt(Socket, Pathname, Timeout, Options) ->
	request(Socket, <<"SMNT">>, Pathname, undefined, Timeout, Options).

ftp_stat(Socket, Timeout, Options) ->
	request(Socket, <<"STAT">>, undefined, undefined, Timeout, Options).

ftp_stat(Socket, Pathname, Timeout, Options) ->
	request(Socket, <<"STAT">>, Pathname, undefined, Timeout, Options).

ftp_stor(Socket, Pathname, Data, Timeout, Options) ->
	request(Socket, <<"STOR">>, Pathname, Data, Timeout, Options).

ftp_stou(Socket, Timeout, Options) ->
	request(Socket, <<"STOU">>, undefined, undefined, Timeout, Options).

ftp_syst(Socket, Timeout, Options) ->
	request(Socket, <<"SYST">>, undefined, undefined, Timeout, Options).

ftp_type(Socket, TypeCode, Timeout, Options) ->
	request(Socket, <<"TYPE">>, TypeCode, undefined, Timeout, Options).

ftp_user(Socket, Username, Timeout, Options) ->
	request(Socket, <<"USER">>, Username, undefined, Timeout, Options).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
-spec bad_options([term()]) -> no_return().
bad_options(Errors) ->
	erlang:error({bad_options, Errors}).

%% @private
is_ftp_between({{C, _}, _, _}, A, B) when A >= 100 andalso A < 200 andalso C >= A andalso C < B ->
	true;
is_ftp_between({_, {C, _}, _}, A, B) when C >= A andalso C < B ->
	true;
is_ftp_between(_, _, _) ->
	false.

%% @private
is_ftp_code({{C, _}, _, _}, C) when C >= 100 andalso C < 200 ->
	true;
is_ftp_code({_, {C, _}, _}, C) ->
	true;
is_ftp_code(_, _) ->
	false.

%% @private
kill_client(Pid) ->
	Monitor = erlang:monitor(process, Pid),
	unlink(Pid),
	exit(Pid, timeout),
	receive
		{response, _ReqId, Pid, R} ->
			erlang:demonitor(Monitor, [flush]),
			R;
		{'DOWN', Monitor, process, Pid, timeout} ->
			{error, timeout};
		{'DOWN', Monitor, process, Pid, Reason} ->
			erlang:error(Reason)
	end.

%% @private
kill_client_after(Pid, Timeout) ->
	Monitor = erlang:monitor(process, Pid),
	receive
		{'DOWN', Monitor, process, Pid, _Reason} ->
			exit(normal)
	after
		Timeout ->
			catch unlink(Pid),
			exit(Pid, timeout),
			receive
				{'DOWN', Monitor, process, Pid, timeout} ->
					{error, timeout};
				{'DOWN', Monitor, process, Pid, Reason} ->
					erlang:error(Reason)
			after
				1000 ->
					exit(Pid, kill),
					exit(normal)
			end
	end.

%% @private
maybe_auth_tls(_, false, _) ->
	ok;
maybe_auth_tls(Socket, explicit, Timeout) ->
	case ftp_auth(Socket, <<"TLS">>, Timeout, []) of
		{ok, AuthTLSResponse} ->
			case is_ftp_code(AuthTLSResponse, 234) of
				true ->
					maybe_auth_tls(Socket, implicit, Timeout);
				false ->
					case ftp_auth(Socket, <<"SSL">>, Timeout, []) of
						{ok, AuthSSLResponse} ->
							case is_ftp_code(AuthSSLResponse, 234) of
								true ->
									maybe_auth_tls(Socket, implicit, Timeout);
								false ->
									{error, {badreply, [AuthTLSResponse, AuthSSLResponse]}}
							end;
						AuthSSLSocketError ->
							AuthSSLSocketError
					end
			end;
		AuthTLSSocketError ->
			AuthTLSSocketError
	end;
maybe_auth_tls(Socket, implicit, Timeout) ->
	case ftp_pbsz(Socket, <<"0">>, Timeout, []) of
		{ok, {_, {C, _}, _}} when C >= 200 andalso C < 400 ->
			case ftp_prot(Socket, <<"P">>, Timeout, []) of
				{ok, {_, {C, _}, _}} when C >= 200 andalso C < 400 ->
					ok;
				{ok, ProtResponse} ->
					{error, {badreply, [ProtResponse]}};
				ProtSocketError ->
					ProtSocketError
			end;
		{ok, PbszResponse} ->
			{error, {badreply, [PbszResponse]}};
		PbszSocketError ->
			PbszSocketError
	end.

%% @private
read_client_response(Pid, Timeout) ->
	receive
		{ack, Pid} ->
			read_client_response(Pid, Timeout);
		{ftp_eod, Pid, R} ->
			{ok, R};
		{ftp_error, Pid, Reason} ->
			{error, Reason};
		{ftp_closed, Pid} ->
			{error, closed};
		{response, _ReqId, Pid, R} ->
			R;
		{exit, _ReqId, Pid, Reason} ->
			exit(Reason);
		{'EXIT', Pid, Reason} ->
			exit(Reason)
	after
		Timeout ->
			kill_client(Pid)
	end.

%% @private
read_sock_response(Socket, Replies, Timeout) ->
	receive
		{ftp, Socket, undefined, Reply} ->
			read_sock_response(Socket, [Reply | Replies], Timeout);
		{ftp_eod, Socket, undefined, Reply} ->
			case Replies of
				[] ->
					{ok, {undefined, Reply, Socket}};
				[R] ->
					{ok, {R, Reply, Socket}}
			end;
		{ftp_error, Socket, undefined, Reason} ->
			{error, Reason};
		{ftp_closed, Socket, undefined} ->
			{error, closed}
	after
		Timeout ->
			{error, timeout}
	end.

%% @private
verify_credentials([{account, Account} | Options], Errors)
		when is_binary(Account) ->
	verify_credentials(Options, Errors);
verify_credentials([{password, Password} | Options], Errors)
		when is_binary(Password) ->
	verify_credentials(Options, Errors);
verify_credentials([{username, Username} | Options], Errors)
		when is_binary(Username) ->
	verify_credentials(Options, Errors);
verify_credentials([Option | Options], Errors) ->
	verify_credentials(Options, [Option | Errors]);
verify_credentials([], []) ->
	ok;
verify_credentials([], Errors) ->
	bad_options(Errors).

%% @private
-spec verify_options(options(), [term()]) -> ok | none().
verify_options([{ctrl_decoder, {CtrlDecoder, _}} | Options], Errors)
		when is_function(CtrlDecoder, 2) ->
	verify_options(Options, Errors);
verify_options([{data_decoder, {DataDecoder, _}} | Options], Errors)
		when is_function(DataDecoder, 2) ->
	verify_options(Options, Errors);
verify_options([{partial_download, DownloadOptions} | Options], Errors)
		when is_list(DownloadOptions) ->
	case verify_partial_download_options(DownloadOptions, []) of
		[] ->
			verify_options(Options, Errors);
		DownloadOptionErrors ->
			NewErrors = [{partial_download, DownloadOptionErrors} | Errors],
			verify_options(Options, NewErrors)
	end;
verify_options([{partial_upload, WindowSize}, Options], Errors)
		when is_integer(WindowSize) andalso WindowSize >= 0 ->
	verify_options(Options, Errors);
verify_options([{partial_upload, infinity} | Options], Errors) ->
	verify_options(Options, Errors);
verify_options([{send_retry, SendRetry} | Options], Errors)
		when is_integer(SendRetry) andalso SendRetry >= 0 ->
	verify_options(Options, Errors);
verify_options([{stream_to, Pid} | Options], Errors)
		when is_pid(Pid) ->
	verify_options(Options, Errors);
verify_options([Option | Options], Errors) ->
	verify_options(Options, [Option | Errors]);
verify_options([], []) ->
	ok;
verify_options([], Errors) ->
	bad_options(Errors).

%% @private
-spec verify_partial_download_options(partial_download_options(), [term()]) -> [term()].
verify_partial_download_options([{window_size, infinity} | Options], Errors) ->
	verify_partial_download_options(Options, Errors);
verify_partial_download_options([{window_size, Size} | Options], Errors)
		when is_integer(Size), Size >= 0 ->
	verify_partial_download_options(Options, Errors);
verify_partial_download_options([{part_size, Size} | Options], Errors)
		when is_integer(Size), Size >= 0 ->
	verify_partial_download_options(Options, Errors);
verify_partial_download_options([{part_size, infinity} | Options], Errors) ->
	verify_partial_download_options(Options, Errors);
verify_partial_download_options([Option | Options], Errors) ->
	verify_partial_download_options(Options, [Option | Errors]);
verify_partial_download_options([], Errors) ->
	Errors.
