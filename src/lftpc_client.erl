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
-module(lftpc_client).

-include("lftpc_types.hrl").

%% API exports
-export([start_request/3]).
-export([request/9]).

%% Internal API exports
-export([init/4]).

%% Records
-record(state, {
	parent           = undefined :: undefined | pid(),
	owner            = undefined :: undefined | pid(),
	stream_to        = undefined :: undefined | pid(),
	req_id           = undefined :: undefined | term(),
	req_ref          = undefined :: undefined | reference(),
	socket           = undefined :: undefined | lftpc_prim:socket(),
	partial_upload   = undefined :: undefined | boolean(),
	upload_window    = undefined :: undefined | non_neg_integer() | infinity,
	partial_download = undefined :: undefined | boolean(),
	download_window  = undefined :: undefined | non_neg_integer() | infinity,
	part_size        = undefined :: undefined | non_neg_integer() | infinity
}).

%% Macros
-define(setactive(Socket, NextOK, NextError),
	try lftpc_prim:setopts(Socket, [{active, once}]) of
		ok ->
			NextOK;
		_ ->
			NextError
	catch
		_:_ ->
			NextError
	end).

%%====================================================================
%% API functions
%%====================================================================

start_request(ReqId, Socket, Owner) ->
	proc_lib:start_link(?MODULE, init, [self(), ReqId, Socket, Owner]).

request(Parent, Owner, StreamTo, ReqId, Socket, Command, Argument, Data, Options) ->
	Result = try
		execute(Parent, Owner, StreamTo, ReqId, Socket, Command, Argument, Data, Options)
	catch
		Reason ->
			{response, ReqId, self(), {error, Reason}};
		error:closed ->
			{response, ReqId, self(), {error, closed}};
		error:Error ->
			{exit, ReqId, self(), {Error, erlang:get_stacktrace()}}
	end,
	case Result of
		{response, _, _, {ok, {no_return, _}}} ->
			ok;
		_ ->
			lftpc_prim:controlling_process(Socket, Parent),
			Parent ! {response, ReqId, self(), Socket},
			StreamTo ! Result
	end,
	unlink(Parent),
	ok.

%%====================================================================
%% Internal API functions
%%====================================================================

%% @private
init(Parent, ReqId, Socket, Owner) ->
	ok = proc_lib:init_ack(Parent, {ok, self()}),
	receive
		{request, ReqId, StreamTo, Owner, Command, Argument, Data, Options} ->
			?MODULE:request(Parent, Owner, StreamTo, ReqId, Socket, Command, Argument, Data, Options)
	end.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
execute(Parent, Owner, StreamTo, ReqId, Socket, Command, Argument, Data, Options) ->
	UploadWindowSize = proplists:get_value(partial_upload, Options),
	PartialUpload = proplists:is_defined(partial_upload, Options),
	PartialDownload = proplists:is_defined(partial_download, Options),
	PartialDownloadOptions = proplists:get_value(partial_download, Options, []),
	DownloadWindowSize = proplists:get_value(window_size, PartialDownloadOptions, infinity),
	DownloadPartSize = proplists:get_value(part_size, PartialDownloadOptions, infinity),
	State = #state{
		parent           = Parent,
		owner            = Owner,
		stream_to        = StreamTo,
		req_id           = ReqId,
		socket           = Socket,
		partial_upload   = PartialUpload,
		upload_window    = UploadWindowSize,
		partial_download = PartialDownload,
		download_window  = DownloadWindowSize,
		part_size        = DownloadPartSize
	},
	Response = send_request(State, Command, Argument, Data),
	{response, ReqId, self(), Response}.

%% @private
send_request(State=#state{socket=Socket}, Command, Argument, Data) ->
	case do_call(Socket, Command, Argument) of
		{ok, ReqRef} ->
			lftpc_prim:setopts(Socket, [{active, once}]),
			read_response_initial(State#state{req_ref=ReqRef}, Data, [])
	end.

%% @private
do_call(Socket, Command, undefined) ->
	lftpc_prim:call(Socket, Command);
do_call(Socket, Command, Argument) ->
	lftpc_prim:call(Socket, Command, Argument).

%% @private
read_response(State=#state{req_ref=ReqRef, socket=Socket}, CAcc) ->
	receive
		{ftp, Socket, {ReqRef, {Code, Text}}} ->
			?setactive(Socket,
				read_response(State, [{Code, Text} | CAcc]),
				{ok, {lists:reverse([{Code, Text} | CAcc]), undefined}});
		{ftp, Socket, {ReqRef, Data}} when is_binary(Data) ->
			?setactive(Socket,
				read_response(State, CAcc),
				{ok, {lists:reverse(CAcc), undefined}});
		{ftp, Socket, {ReqRef, done}} ->
			{ok, {lists:reverse(CAcc), undefined}}
	end.

%% @private
read_response_data(State=#state{req_ref=ReqRef, socket=Socket}, {CAcc, DAcc}) ->
	receive
		{ftp, Socket, {ReqRef, {Code, Text}}} ->
			?setactive(Socket,
				read_response_data(State, {[{Code, Text} | CAcc], DAcc}),
				{ok, {lists:reverse([{Code, Text} | CAcc]), lists:reverse(DAcc)}});
		{ftp, Socket, {ReqRef, Data}} when is_binary(Data) ->
			?setactive(Socket,
				read_response_data(State, {CAcc, [Data | DAcc]}),
				{ok, {lists:reverse(CAcc), lists:reverse([Data | DAcc])}});
		{ftp, Socket, {ReqRef, done}} ->
			{ok, {lists:reverse(CAcc), lists:reverse(DAcc)}}
	end.

%% @private
read_response_initial(State=#state{req_ref=ReqRef, socket=Socket}, UploadData, DownloadData) ->
	receive
		{ftp, Socket, {ReqRef, {Code, Text}}} ->
			case {State#state.partial_download, State#state.partial_upload} of
				{false, false} ->
					case Code of
						_ when Code >= 100 andalso Code < 200 ->
							case UploadData of
								undefined ->
									?setactive(Socket,
										read_response_data(State, {[{Code, Text}], DownloadData}),
										{ok, {[{Code, Text}], undefined}});
								_ ->
									lftpc_prim:send(Socket, UploadData),
									lftpc_prim:done(Socket),
									?setactive(Socket,
										read_response(State, [{Code, Text}]),
										{ok, {[{Code, Text}], undefined}})
							end;
						_ ->
							?setactive(Socket,
								read_response(State, [{Code, Text}]),
								{ok, {[{Code, Text}], undefined}})
					end;
				{_, true} ->
					partial_upload(State, {Code, Text}, UploadData);
				{true, _} ->
					partial_download(State, {Code, Text}, DownloadData)
			end;
		{ftp, Socket, {ReqRef, Data}} when is_binary(Data) ->
			?setactive(Socket,
				read_response_initial(State, UploadData, [Data | DownloadData]),
				{ok, {[], lists:reverse([Data | DownloadData])}})
	end.

%% @private
partial_download(State=#state{req_id=ReqId, stream_to=StreamTo, socket=Socket}, {Code, Text}, DAcc)
		when Code >= 100 andalso Code < 200 ->
	StreamTo ! {response, ReqId, self(), {ok, {[{Code, Text}], self()}}},
	?setactive(Socket,
		partial_download_loop(State, DAcc),
		{ok, {[{Code, Text}], undefined}});
partial_download(_State=#state{req_ref=ReqRef, socket=Socket}, {Code, Text}, _DAcc) ->
	?setactive(Socket,
		receive
			{ftp, Socket, {ReqRef, done}} ->
				{ok, {[{Code, Text}], undefined}}
		end,
		{ok, {[{Code, Text}], undefined}}).

%% @private
partial_download_loop(State=#state{parent=Parent, req_id=ReqId, req_ref=ReqRef, stream_to=StreamTo, socket=Socket}, CAcc) ->
	receive
		{ftp, Socket, {ReqRef, Data}} when is_binary(Data) ->
			StreamTo ! {data_part, self(), Data},
			?setactive(Socket,
				partial_download_loop(State, CAcc),
				begin
					StreamTo ! {ftp_eod, self(), lists:reverse(CAcc)},
					{ok, {no_return, CAcc}}
				end);
		{ftp, Socket, {ReqRef, {Code, Text}}} ->
			?setactive(Socket,
				partial_download_loop(State, [{Code, Text} | CAcc]),
				begin
					StreamTo ! {ftp_eod, self(), lists:reverse([{Code, Text} | CAcc])},
					{ok, {no_return, CAcc}}
				end);
		{ftp, Socket, {ReqRef, done}} ->
			lftpc_prim:controlling_process(Socket, Parent),
			Parent ! {response, ReqId, self(), Socket},
			StreamTo ! {ftp_eod, self(), lists:reverse(CAcc)},
			{ok, {no_return, CAcc}}
	end.

%% @private
partial_upload(State=#state{req_id=ReqId, stream_to=StreamTo, socket=Socket}, {Code, Text}, Data)
		when Code >= 100 andalso Code < 200 ->
	StreamTo ! {response, ReqId, self(), {ok, {[{Code, Text}], self()}}},
	lftpc_prim:setopts(Socket, [{active, once}]),
	ok = case Data of
		undefined ->
			ok;
		_ ->
			lftpc_prim:send(Socket, Data),
			ok
	end,
	partial_upload_loop(State);
partial_upload(_State=#state{req_ref=ReqRef, socket=Socket}, {Code, Text}, _Data) ->
	lftpc_prim:setopts(Socket, [{active, once}]),
	receive
		{ftp, Socket, {ReqRef, done}} ->
			{ok, {[{Code, Text}], undefined}}
	end.

%% @private
partial_upload_loop(State=#state{stream_to=StreamTo, socket=Socket}) ->
	receive
		{data_part, StreamTo, ftp_eod} ->
			lftpc_prim:done(Socket),
			partial_download_loop(State, []);
		{data_part, StreamTo, Data} ->
			lftpc_prim:send(Socket, Data),
			partial_upload_loop(State)
	end.
