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
-export([close/1]).
-export([request/6]).

%% Utility API
-export([require/1]).
-export([start/0]).

%% High-level FTP API
-export([append/5]).
-export([auth_tls/1]).
-export([cd/4]).
-export([cdup/3]).
-export([connect/3]).
-export([connect/4]).
-export([data_mode/2]).
-export([delete/4]).
-export([disconnect/3]).
-export([features/3]).
-export([keep_alive/2]).
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
-export([start_data/3]).
-export([store/5]).
-export([system_type/3]).
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

close(Socket) ->
	lftpc_sock:close(Socket).

request(Socket, Command, Argument, Data, Timeout, Options) ->
	ok = verify_options(Options, []),
	SendRetry = proplists:get_value(send_retry, Options, 1),
	do_request_retry(Socket, Command, Argument, Data, Timeout, Options, SendRetry).

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

append(Socket, Pathname, Data, Timeout, Options) ->
	case start_data(Socket, Timeout, Options) of
		{ok, _} ->
			case ftp_appe(Socket, Pathname, Data, Timeout, Options) of
				{ok, AppeResponse} ->
					case is_pos_response(AppeResponse) of
						true ->
							{ok, AppeResponse};
						false ->
							{error, AppeResponse}
					end;
				AppeSocketError ->
					AppeSocketError
			end;
		StartDataError ->
			StartDataError
	end.

auth_tls(Socket) ->
	case maybe_tls(Socket, explicit, infinity) of
		{ok, {_, Socket}} ->
			ok;
		TLSError ->
			TLSError
	end.

cd(Socket, Directory, Timeout, Options) ->
	Opts = [{K, V} || {K, V} <- Options, K =:= send_retry],
	case ftp_cwd(Socket, Directory, Timeout, Opts) of
		{ok, CwdResponse} ->
			case is_response_code(CwdResponse, 250) of
				true ->
					{ok, CwdResponse};
				false ->
					{error, CwdResponse}
			end;
		CwdSocketError ->
			CwdSocketError
	end.

cdup(Socket, Timeout, Options) ->
	Opts = [{K, V} || {K, V} <- Options, K =:= send_retry],
	case ftp_cdup(Socket, Timeout, Opts) of
		{ok, CdupResponse} ->
			case is_response_code(CdupResponse, 250) of
				true ->
					{ok, CdupResponse};
				false ->
					{error, CdupResponse}
			end;
		CdupSocketError ->
			CdupSocketError
	end.

connect(Address, Port, Options) ->
	connect(Address, Port, Options, infinity).

connect(Address, Port, Options, Timeout) ->
	{TLS, Opts} = case lists:keytake(tls, 1, Options) of
		{value, {tls, explicit}, O} ->
			{explicit, O};
		{value, {tls, implicit}, _} ->
			{implicit, Options};
		_ ->
			{false, Options}
	end,
	case lftpc_sock:connect(Address, Port, Opts, Timeout) of
		{ok, Socket} ->
			case read_response_timeout(Socket, undefined, Timeout) of
				{ok, Result} ->
					case is_pos_response(Result) of
						true ->
							case maybe_tls(Socket, TLS, Timeout) of
								{ok, _} ->
									{ok, Result};
								TLSError ->
									ok = close(Socket),
									TLSError
							end;
						false ->
							ok = close(Socket),
							{error, Result}
					end;
				{error, Reason} ->
					ok = close(Socket),
					{error, Reason}
			end;
		ConnectError ->
			ConnectError
	end.

data_mode(Socket, Open)
		when Open =:= active
		orelse Open =:= passive
		orelse Open =:= extended_active
		orelse Open =:= extended_passive ->
	gen_ftp:setopts(Socket, [{open, Open}]).

delete(Socket, Filename, Timeout, Options) ->
	Opts = [{K, V} || {K, V} <- Options, K =:= send_retry],
	case ftp_dele(Socket, Filename, Timeout, Opts) of
		{ok, DeleResponse} ->
			case is_response_code(DeleResponse, 250) of
				true ->
					{ok, DeleResponse};
				false ->
					{error, DeleResponse}
			end;
		DeleSocketError ->
			DeleSocketError
	end.

disconnect(Socket, Timeout, Options) ->
	Opts = [{K, V} || {K, V} <- Options, K =:= send_retry],
	case ftp_quit(Socket, Timeout, Opts) of
		{ok, QuitResponse} ->
			case is_pos_response(QuitResponse) of
				true ->
					{ok, QuitResponse};
				false ->
					{error, QuitResponse}
			end;
		QuitSocketError ->
			QuitSocketError
	end.

features(Socket, Timeout, Options) ->
	Opts = [{K, V} || {K, V} <- Options, K =:= send_retry],
	case ftp_feat(Socket, Timeout, Opts) of
		{ok, FeatResponse} ->
			case is_response_code(FeatResponse, 211) of
				true ->
					{ok, FeatResponse};
				false ->
					{error, FeatResponse}
			end;
		FeatSocketError ->
			FeatSocketError
	end.

keep_alive(Socket, Timeout, Options) ->
	Opts = [{K, V} || {K, V} <- Options, K =:= send_retry],
	case ftp_noop(Socket, Timeout, Opts) of
		{ok, NoopResponse} ->
			case is_pos_response(NoopResponse) of
				true ->
					{ok, NoopResponse};
				false ->
					{error, NoopResponse}
			end;
		NoopSocketError ->
			NoopSocketError
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
					case is_pos_response(UserResponse) of
						true ->
							{ok, [UserResponse]};
						false ->
							{error, UserResponse}
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
					case is_pos_response(PassResponse) of
						true ->
							{ok, [PassResponse]};
						false ->
							{error, PassResponse}
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
					case is_pos_response(AcctResponse) of
						true ->
							{ok, [AcctResponse]};
						false ->
							{error, AcctResponse}
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
	case start_data(Socket, Timeout, Options) of
		{ok, _} ->
			case ftp_list(Socket, Timeout, Options) of
				{ok, ListResponse} ->
					case is_pos_response(ListResponse) of
						true ->
							{ok, ListResponse};
						false ->
							{error, ListResponse}
					end;
				ListSocketError ->
					ListSocketError
			end;
		StartDataError ->
			StartDataError
	end.

ls(Socket, Pathname, Timeout, Options) ->
	case start_data(Socket, Timeout, Options) of
		{ok, _} ->
			case ftp_list(Socket, Pathname, Timeout, Options) of
				{ok, ListResponse} ->
					case is_pos_response(ListResponse) of
						true ->
							{ok, ListResponse};
						false ->
							{error, ListResponse}
					end;
				ListSocketError ->
					ListSocketError
			end;
		StartDataError ->
			StartDataError
	end.

mkdir(Socket, Directory, Timeout, Options) ->
	Opts = [{K, V} || {K, V} <- Options, K =:= send_retry],
	case ftp_mkd(Socket, Directory, Timeout, Opts) of
		{ok, MkdResponse} ->
			case is_response_code(MkdResponse, 257) of
				true ->
					{ok, MkdResponse};
				false ->
					{error, MkdResponse}
			end;
		MkdSocketError ->
			MkdSocketError
	end.

nlist(Socket, Timeout, Options) ->
	case start_data(Socket, Timeout, Options) of
		{ok, _} ->
			case ftp_nlst(Socket, Timeout, Options) of
				{ok, NlstResponse} ->
					case is_pos_response(NlstResponse) of
						true ->
							{ok, NlstResponse};
						false ->
							{error, NlstResponse}
					end;
				NlstSocketError ->
					NlstSocketError
			end;
		StartDataError ->
			StartDataError
	end.

nlist(Socket, Pathname, Timeout, Options) ->
	case start_data(Socket, Timeout, Options) of
		{ok, _} ->
			case ftp_nlst(Socket, Pathname, Timeout, Options) of
				{ok, NlstResponse} ->
					case is_pos_response(NlstResponse) of
						true ->
							{ok, NlstResponse};
						false ->
							{error, NlstResponse}
					end;
				NlstSocketError ->
					NlstSocketError
			end;
		StartDataError ->
			StartDataError
	end.

pwd(Socket, Timeout, Options) ->
	Opts = [{K, V} || {K, V} <- Options, K =:= send_retry],
	case ftp_pwd(Socket, Timeout, Opts) of
		{ok, PwdResponse} ->
			case is_pos_response(PwdResponse) of
				true ->
					{ok, PwdResponse};
				false ->
					{error, PwdResponse}
			end;
		PwdSocketError ->
			PwdSocketError
	end.

rename(Socket, Old, New, Timeout, Options) ->
	Opts = [{K, V} || {K, V} <- Options, K =:= send_retry],
	case ftp_rnfr(Socket, Old, Timeout, Opts) of
		{ok, RnfrResponse} ->
			case is_int_response(RnfrResponse) of
				true ->
					case ftp_rnto(Socket, New, Timeout, Opts) of
						{ok, RntoResponse} ->
							case is_pos_response(RntoResponse) of
								true ->
									{ok, [RnfrResponse, RntoResponse]};
								false ->
									{error, [RnfrResponse, RntoResponse]}
							end;
						RntoSocketError ->
							RntoSocketError
					end;
				false ->
					{error, [RnfrResponse]}
			end;
		RnfrSocketError ->
			RnfrSocketError
	end.

restart(Socket, Pathname, Offset, Timeout, Options) ->
	Opts = [{K, V} || {K, V} <- Options, K =:= send_retry],
	case start_data(Socket, Timeout, Options) of
		{ok, _} ->
			case ftp_rest(Socket, Offset, Timeout, Opts) of
				{ok, RestResponse} ->
					case is_int_response(RestResponse) of
						true ->
							case ftp_retr(Socket, Pathname, Timeout, Options) of
								{ok, RetrResponse} ->
									case is_pos_response(RetrResponse) of
										true ->
											{ok, RetrResponse};
										false ->
											{error, RetrResponse}
									end;
								RetrSocketError ->
									RetrSocketError
							end;
						false ->
							{error, RestResponse}
					end;
				RestSocketError ->
					RestSocketError
			end;
		StartDataError ->
			StartDataError
	end.

retrieve(Socket, Pathname, Timeout, Options) ->
	case start_data(Socket, Timeout, Options) of
		{ok, _} ->
			case ftp_retr(Socket, Pathname, Timeout, Options) of
				{ok, RetrResponse} ->
					case is_pos_response(RetrResponse) of
						true ->
							{ok, RetrResponse};
						false ->
							{error, RetrResponse}
					end;
				RetrSocketError ->
					RetrSocketError
			end;
		StartDataError ->
			StartDataError
	end.

rmdir(Socket, Directory, Timeout, Options) ->
	case ftp_rmd(Socket, Directory, Timeout, Options) of
		{ok, RmdResponse} ->
			case is_response_code(RmdResponse, 250) of
				true ->
					{ok, RmdResponse};
				false ->
					{error, RmdResponse}
			end;
		RmdSocketError ->
			RmdSocketError
	end.

start_data(Socket, Timeout, Options) ->
	case lftpc_sock:open(Socket) of
		{ok, Command} ->
			Opts = [{K, V} || {K, V} <- Options, K =:= send_retry],
			case request(Socket, Command, undefined, undefined, Timeout, Opts) of
				{ok, Response} ->
					case is_pos_response(Response) of
						true ->
							{ok, Response};
						false ->
							{error, Response}
					end;
				SocketError ->
					SocketError
			end;
		OpenError ->
			OpenError
	end.

store(Socket, Pathname, Data, Timeout, Options) ->
	case start_data(Socket, Timeout, Options) of
		{ok, _} ->
			case ftp_stor(Socket, Pathname, Data, Timeout, Options) of
				{ok, StorResponse} ->
					case is_pos_response(StorResponse) of
						true ->
							{ok, StorResponse};
						false ->
							{error, StorResponse}
					end;
				StorSocketError ->
					StorSocketError
			end;
		StartDataError ->
			StartDataError
	end.

system_type(Socket, Timeout, Options) ->
	case ftp_syst(Socket, Timeout, Options) of
		{ok, SystResponse} ->
			case is_pos_response(SystResponse) of
				true ->
					{ok, SystResponse};
				false ->
					{error, SystResponse}
			end;
		SystSocketError ->
			SystSocketError
	end.

type(Socket, Type, Timeout, Options) when Type =:= ascii orelse Type =:= binary ->
	TypeCode = case Type of
		ascii ->
			$A;
		binary ->
			$I
	end,
	Opts = [{K, V} || {K, V} <- Options, K =:= send_retry],
	case ftp_type(Socket, TypeCode, Timeout, Opts) of
		{ok, TypeResponse} ->
			case is_pos_response(TypeResponse) of
				true ->
					{ok, TypeResponse};
				false ->
					{error, TypeResponse}
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
cancel_timeout(TRef) when is_reference(TRef) ->
	catch erlang:cancel_timer(TRef),
	receive
		{timeout, TRef, timeout} ->
			ok
	after
		0 ->
			ok
	end;
cancel_timeout(_) ->
	ok.

%% @private
do_request_retry(Socket, Command, Argument, Data, Timeout, Options, 0) ->
	case lftpc_sock:start_request(Socket) of
		{ok, {ReqId, Pid}} ->
			do_request(ReqId, Pid, Socket, Command, Argument, Data, Timeout, Options);
		StartError ->
			StartError
	end;
do_request_retry(Socket, Command, Argument, Data, Timeout, Options, SendRetry) ->
	case lftpc_sock:start_request(Socket) of
		{ok, {ReqId, Pid}} ->
			do_request(ReqId, Pid, Socket, Command, Argument, Data, Timeout, Options);
		_ ->
			do_request_retry(Socket, Command, Argument, Data, Timeout, Options, SendRetry - 1)
	end.

%% @private
do_request(ReqId, Pid, _Socket, Command, Argument, Data, Timeout, Options) ->
	case proplists:is_defined(stream_to, Options) of
		true ->
			StreamTo = proplists:get_value(stream_to, Options),
			Pid ! {request, ReqId, StreamTo, self(), Command, Argument, Data, Options},
			spawn(fun() ->
				R = kill_client_after(Pid, Timeout),
				StreamTo ! {response, ReqId, Pid, R}
			end),
			{ReqId, Pid};
		false ->
			Pid ! {request, ReqId, self(), self(), Command, Argument, Data, Options},
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

%% @private
is_int_response({[{Code, _} | _], _}) when Code >= 300 andalso Code < 400 ->
	true;
is_int_response({[{_, _} | Rest], Pid}) ->
	is_int_response({Rest, Pid});
is_int_response({[], _}) ->
	false.

%% @private
is_pos_response({[{Code, _} | _], _}) when Code >= 200 andalso Code < 400 ->
	true;
is_pos_response({[{_, _} | Rest], Pid}) ->
	is_pos_response({Rest, Pid});
is_pos_response({[], _}) ->
	false.

%% @private
is_response_code({[{Code, _} | _], _}, Code) ->
	true;
is_response_code({[{_, _} | Rest], Pid}, Code) ->
	is_response_code({Rest, Pid}, Code);
is_response_code({[], _}, _Code) ->
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
					% exit(Pid, kill),
					exit(normal)
			end
	end.

%% @private
maybe_tls(Socket, false, _) ->
	{ok, {undefined, Socket}};
maybe_tls(Socket, explicit, Timeout) ->
	case ftp_auth(Socket, <<"TLS">>, Timeout, []) of
		{ok, AuthResponse} ->
			case is_response_code(AuthResponse, 234) of
				true ->
					maybe_tls(Socket, implicit, Timeout);
				false ->
					{error, AuthResponse}
			end;
		AuthSocketError ->
			AuthSocketError
	end;
maybe_tls(Socket, implicit, Timeout) ->
	case ftp_pbsz(Socket, <<"0">>, Timeout, []) of
		{ok, PbszResponse} ->
			case is_pos_response(PbszResponse) of
				true ->
					case ftp_prot(Socket, <<"P">>, Timeout, []) of
						{ok, ProtResponse} ->
							case is_pos_response(ProtResponse) of
								true ->
									{ok, {undefined, Socket}};
								false ->
									{error, ProtResponse}
							end;
						ProtSocketError ->
							ProtSocketError
					end;
				false ->
					{error, PbszResponse}
			end;
		PbszSocketError ->
			PbszSocketError
	end.

%% @private
read_response(Socket, Ref, Acc) ->
	receive
		{ftp, Socket, {Ref, Reply={Code, _}}} when Code >= 200 andalso Code < 600 ->
			receive
				{ftp, Socket, {Ref, done}} ->
					{ok, {lists:reverse([Reply | Acc]), Socket}}
			end;
		{ftp, Socket, {Ref, Reply={_, _}}} ->
			read_response(Socket, Ref, [Reply | Acc]);
		{ftp_error, Socket, {Ref, Reason}} ->
			{error, Reason};
		{ftp_closed, Socket} ->
			{error, closed}
	end.

%% @private
read_response(Socket, Ref, Acc, TRef) ->
	receive
		{ftp, Socket, {Ref, Reply={Code, _}}} when Code >= 200 andalso Code < 600 ->
			receive
				{ftp, Socket, {Ref, done}} ->
					ok = cancel_timeout(TRef),
					{ok, {lists:reverse([Reply | Acc]), Socket}}
			end;
		{ftp, Socket, {Ref, Reply={_, _}}} ->
			read_response(Socket, Ref, [Reply | Acc]);
		{ftp_error, Socket, {Ref, Reason}} ->
			ok = cancel_timeout(TRef),
			{error, Reason};
		{ftp_closed, Socket} ->
			ok = cancel_timeout(TRef),
			{error, closed};
		{timeout, TRef, timeout} ->
			{error, timeout}
	end.

%% @private
read_response_timeout(Socket, Ref, infinity) ->
	read_response(Socket, Ref, []);
read_response_timeout(Socket, Ref, Timeout) ->
	TRef = erlang:start_timer(Timeout, self(), timeout),
	read_response(Socket, Ref, [], TRef).

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
