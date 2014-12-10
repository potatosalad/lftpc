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
-export([request/7]).

%% Records
-record(state_data, {
	req_id    = undefined :: undefined | term(),
	stream_to = undefined :: undefined | pid(),
	socket    = undefined :: undefined | lftpc_prim:socket(),
	req_ref   = undefined :: undefined | reference(),
	replies   = [] :: [{integer(), iodata()}],
	% Decoders
	ctrl_decoder = undefined :: undefined | {function(), any()},
	data_decoder = undefined :: undefined | {function(), any()},
	% Download
	partial_download = undefined :: undefined | boolean(),
	download_data    = []        :: iodata(),
	download_part    = undefined :: undefined | non_neg_integer() | infinity,
	download_window  = undefined :: undefined | non_neg_integer() | infinity,
	% Upload
	partial_upload = undefined :: undefined | boolean(),
	upload_data    = undefined :: undefined | iodata(),
	upload_window  = undefined :: undefined | non_neg_integer() | infinity
}).

%%====================================================================
%% API functions
%%====================================================================

request(ReqId, StreamTo, Socket, Command, Argument, Data, Options) ->
	Result = try
		execute(ReqId, StreamTo, Socket, Command, Argument, Data, Options)
	catch
		Reason ->
			{response, ReqId, self(), {error, Reason}};
		error:closed ->
			{response, ReqId, self(), {error, closed}};
		error:Error ->
			{exit, ReqId, self(), {Error, erlang:get_stacktrace()}}
	end,
	case Result of
		{response, _, _, {ok, no_return}} ->
			ok;
		_ ->
			StreamTo ! Result
	end,
	unlink(StreamTo),
	ok.

%%%-------------------------------------------------------------------
%%% Request functions
%%%-------------------------------------------------------------------

%% @private
execute(ReqId, StreamTo, Socket, Command, Argument, Data, Options) ->
	CtrlDecoder = proplists:get_value(ctrl_decoder, Options),
	DataDecoder = proplists:get_value(data_decoder, Options),
	UploadWindowSize = proplists:get_value(partial_upload, Options),
	PartialUpload = proplists:is_defined(partial_upload, Options),
	PartialDownload = proplists:is_defined(partial_download, Options),
	PartialDownloadOptions = proplists:get_value(partial_download, Options, []),
	DownloadWindowSize = proplists:get_value(window_size, PartialDownloadOptions, infinity),
	DownloadPartSize = proplists:get_value(part_size, PartialDownloadOptions, infinity),
	StateData = #state_data{
		req_id    = ReqId,
		stream_to = StreamTo,
		socket    = Socket,
		% Decoders
		ctrl_decoder = CtrlDecoder,
		data_decoder = DataDecoder,
		% Download
		partial_download = PartialDownload,
		download_part    = DownloadPartSize,
		download_window  = DownloadWindowSize,
		% Upload
		partial_upload = PartialUpload,
		upload_data    = Data,
		upload_window  = UploadWindowSize
	},
	Monitor = erlang:monitor(process, StreamTo),
	Response = send_request(StateData, Command, Argument),
	erlang:demonitor(Monitor, [flush]),
	{response, ReqId, self(), Response}.

%% @private
send_request(SD0=#state_data{socket=Socket}, Command, undefined) ->
	{ok, ReqRef} = lftpc_sock:quote(Socket, Command),
	SD1 = SD0#state_data{req_ref=ReqRef},
	loop(SD1, read_initial);
send_request(SD0=#state_data{socket=Socket}, Command, Argument) ->
	{ok, ReqRef} = lftpc_sock:quote(Socket, Command, Argument),
	SD1 = SD0#state_data{req_ref=ReqRef},
	loop(SD1, read_initial).

%%%-------------------------------------------------------------------
%%% Loop functions
%%%-------------------------------------------------------------------

%% @private
loop(SD0=#state_data{stream_to=StreamTo, socket=Socket, req_ref=ReqRef}, SN) ->
	receive
		{ftp, Socket, ReqRef, {Code, Text}} ->
			{true, Reply, SD1} = ctrl_decode(SD0, {Code, Text}),
			handle_ctrl(SD1, SN, Reply);
		{data_part, Socket, ReqRef, Data} ->
			case data_decode(SD0, Data) of
				{true, NewData, SD1} ->
					handle_download(SD1, SN, NewData);
				{false, SD1} ->
					loop(SD1, SN)
			end;
		{data_part, StreamTo, Data} ->
			handle_upload(SD0, SN, Data);
		{ftp_eod, Socket, ReqRef, {Code, Text}} ->
			{true, Reply, SD1} = ctrl_decode(SD0, {Code, Text}),
			handle_eod(SD1, SN, Reply);
		{ftp_error, Socket, ReqRef, Reason} ->
			handle_error(SD0, SN, {ftp_error, Reason});
		{data_error, Socket, ReqRef, Reason} ->
			handle_error(SD0, SN, {data_error, Reason});
		{ftp_closed, Socket, ReqRef} ->
			handle_closed(SD0, SN);
		{'DOWN', _, process, StreamTo, _} ->
			exit(normal);
		Info ->
			error_logger:error_msg(
				"~p ~p received unexpected message ~p in state ~p~nStateData: ~p~n",
				[?MODULE, self(), Info, SN, SD0])
	end.

%% @private
maybe_send_data(SD=#state_data{partial_download=false,
		partial_upload=false, upload_data=undefined}) ->
	loop(SD, read_data);
maybe_send_data(SD0=#state_data{socket=Socket, partial_download=false,
		partial_upload=false, upload_data=Data}) ->
	lftpc_sock:send_data_part(Socket, Data),
	lftpc_sock:send_data_part(Socket, ftp_eod),
	SD1 = SD0#state_data{upload_data=undefined},
	loop(SD1, read_ctrl);
maybe_send_data(SD=#state_data{partial_upload=true}) ->
	partial_upload(SD);
maybe_send_data(SD=#state_data{partial_download=true}) ->
	partial_download(SD).

%% @private
partial_download(SD0=#state_data{req_id=ReqId, stream_to=StreamTo,
		replies=[R], download_data=Data}) ->
	Download = self(),
	Response = {ok, {R, Download}},
	StreamTo ! {response, ReqId, self(), Response},
	SD1 = case Data of
		[] ->
			SD0;
		_ ->
			StreamTo ! {data_part, self(), lists:reverse(Data)},
			SD0#state_data{download_data=[]}
	end,
	SD2 = SD1#state_data{replies=[]},
	loop(SD2, partial_download).

%% @private
partial_upload(SD0=#state_data{req_id=ReqId, stream_to=StreamTo,
		socket=Socket, replies=[R], upload_data=Data,
		upload_window=UploadWindowSize}) ->
	Upload = {self(), UploadWindowSize},
	Response = {ok, {R, Upload}},
	StreamTo ! {response, ReqId, self(), Response},
	SD1 = case Data of
		undefined ->
			SD0;
		_ ->
			lftpc_sock:send_data_part(Socket, Data),
			SD0#state_data{upload_data=undefined}
	end,
	SD2 = SD1#state_data{replies=[]},
	loop(SD2, partial_upload).

%%%-------------------------------------------------------------------
%%% Handle functions
%%%-------------------------------------------------------------------

%% @private
handle_ctrl(SD0=#state_data{replies=R}, read_initial, {Code, Text})
		when Code =:= 125
		orelse Code =:= 150 ->
	SD1 = SD0#state_data{replies=[{Code, Text} | R]},
	maybe_send_data(SD1);
handle_ctrl(SD0=#state_data{replies=R}, read_initial, {Code, Text}) ->
	SD1 = SD0#state_data{replies=[{Code, Text} | R]},
	loop(SD1, read_ctrl);
handle_ctrl(SD0=#state_data{replies=R}, SN, {Code, Text}) ->
	SD1 = SD0#state_data{replies=[{Code, Text} | R]},
	loop(SD1, SN).

%% @private
handle_download(SD=#state_data{stream_to=StreamTo}, SN=partial_download, Data) ->
	StreamTo ! {data_part, self(), Data},
	loop(SD, SN);
handle_download(SD0=#state_data{download_data=D}, SN, Data)
		when SN =:= read_initial
		orelse SN =:= read_data ->
	SD1 = SD0#state_data{download_data=[Data | D]},
	loop(SD1, SN).

%% @private
handle_upload(SD=#state_data{socket=Socket}, partial_upload, ftp_eod) ->
	lftpc_sock:send_data_part(Socket, ftp_eod),
	loop(SD, partial_download);
handle_upload(SD=#state_data{stream_to=StreamTo, socket=Socket},
		SN=partial_upload, Data) ->
	lftpc_sock:send_data_part(Socket, Data),
	StreamTo ! {ack, self()},
	loop(SD, SN).

%% @private
handle_eod(SD=#state_data{replies=Replies}, SN, Reply) ->
	handle_eod(SD, SN, Replies, Reply).

%% @private
handle_eod(_SD, read_initial, [], {Code, Text}) ->
	{ok, {undefined, {Code, Text}, undefined}};
handle_eod(_SD, read_ctrl, [R], {Code, Text}) ->
	{ok, {R, {Code, Text}, undefined}};
handle_eod(_SD, read_ctrl, [], {Code, Text}) ->
	{ok, {undefined, {Code, Text}, undefined}};
handle_eod(_SD=#state_data{download_data=D}, read_data, [R], {Code, Text}) ->
	{ok, {R, {Code, Text}, lists:reverse(D)}};
handle_eod(_SD=#state_data{stream_to=StreamTo}, partial_download, [], {Code, Text}) ->
	StreamTo ! {ftp_eod, self(), {Code, Text}},
	{ok, no_return};
handle_eod(_SD=#state_data{stream_to=StreamTo}, partial_upload, [], {Code, Text}) ->
	StreamTo ! {ftp_eod, self(), {Code, Text}},
	{ok, no_return}.

%% @private
handle_error(_SD, SN, Reason)
		when SN =:= read_initial
		orelse SN =:= read_ctrl
		orelse SN =:= read_data ->
	{error, Reason};
handle_error(#state_data{stream_to=StreamTo}, SN, Reason)
		when SN =:= partial_upload
		orelse SN =:= partial_download ->
	StreamTo ! {ftp_error, self(), Reason},
	{ok, no_return}.

%% @private
handle_closed(_SD, SN)
		when SN =:= read_initial
		orelse SN =:= read_ctrl
		orelse SN =:= read_data ->
	{error, closed};
handle_closed(#state_data{stream_to=StreamTo}, SN)
		when SN =:= partial_upload
		orelse SN =:= partial_download ->
	StreamTo ! {ftp_closed, self()},
	{ok, no_return}.

%%%-------------------------------------------------------------------
%%% Decoder functions
%%%-------------------------------------------------------------------

%% @private
ctrl_decode(SD=#state_data{ctrl_decoder=undefined}, Reply) ->
	{true, Reply, SD};
ctrl_decode(SD0=#state_data{ctrl_decoder={Function, State}}, Reply) ->
	{true, NewReply, NewState} = Function(State, Reply),
	SD1 = SD0#state_data{ctrl_decoder={Function, NewState}},
	{true, NewReply, SD1}.

%% @private
data_decode(SD=#state_data{data_decoder=undefined}, Data) ->
	{true, Data, SD};
data_decode(SD0=#state_data{data_decoder={Function, State}}, Data) ->
	case Function(State, Data) of
		{true, NewData, NewState} ->
			SD1 = SD0#state_data{data_decoder={Function, NewState}},
			{true, NewData, SD1};
		{false, NewState} ->
			SD1 = SD0#state_data{data_decoder={Function, NewState}},
			{false, SD1}
	end.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------
