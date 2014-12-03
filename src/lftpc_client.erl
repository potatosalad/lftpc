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

%% Internal API exports
-export([init_it/4]).

%% Records
-record(state_data, {
	parent    = undefined :: undefined | pid(),
	owner     = undefined :: undefined | pid(),
	stream_to = undefined :: undefined | pid(),
	req_id    = undefined :: undefined | term(),
	req_ref   = undefined :: undefined | reference(),
	socket    = undefined :: undefined | lftpc_prim:socket(),
	% Buffers
	ctrl_buf = [] :: [{integer(), iodata()}],
	data_buf = [] :: iodata(),
	empty    = undefined :: undefined | reference(),
	rcvbuf   = undefined :: undefined | queue:queue(term()),
	% Download
	partial_download = undefined :: undefined | boolean(),
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

start_request(ReqId, Socket, Owner) ->
	proc_lib:start_link(?MODULE, init_it, [self(), ReqId, Socket, Owner]).

%%====================================================================
%% Internal API functions
%%====================================================================

%% @private
init_it(Parent, ReqId, Socket, Owner) ->
	ok = proc_lib:init_ack(Parent, {ok, self()}),
	receive
		{request, ReqId, StreamTo, Owner, Command, Argument, UploadData, Options} ->
			process_flag(trap_exit, true),
			request(Parent, Owner, StreamTo, ReqId, Socket, Command, Argument, UploadData, Options)
	end.

%%%-------------------------------------------------------------------
%%% Request functions
%%%-------------------------------------------------------------------

%% @private
request(Parent, Owner, StreamTo, ReqId, Socket, Command, Argument, Data, Options) ->
	unlink(Parent),
	unlink(StreamTo),
	ParentMonitor = erlang:monitor(process, Parent),
	StreamToMonitor = erlang:monitor(process, StreamTo),
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
		{response, _, _, {ok, no_return}} ->
			ok;
		_ ->
			lftpc_prim:controlling_process(Socket, Parent),
			Parent ! {response, ReqId, self(), Socket},
			StreamTo ! Result
	end,
	true = erlang:demonitor(ParentMonitor, [flush]),
	true = erlang:demonitor(StreamToMonitor, [flush]),
	ok.

%% @private
execute(Parent, Owner, StreamTo, ReqId, Socket, Command, Argument, UploadData, Options) ->
	UploadWindowSize = proplists:get_value(partial_upload, Options),
	PartialUpload = proplists:is_defined(partial_upload, Options),
	PartialDownload = proplists:is_defined(partial_download, Options),
	PartialDownloadOptions = proplists:get_value(partial_download, Options, []),
	DownloadWindowSize = proplists:get_value(window_size, PartialDownloadOptions, infinity),
	DownloadPartSize = proplists:get_value(part_size, PartialDownloadOptions, infinity),
	StateData = #state_data{
		parent    = Parent,
		owner     = Owner,
		stream_to = StreamTo,
		req_id    = ReqId,
		socket    = Socket,
		% Buffers
		rcvbuf = queue:new(),
		% Download
		partial_download = PartialDownload,
		download_part    = DownloadPartSize,
		download_window  = DownloadWindowSize,
		% Upload
		partial_upload = PartialUpload,
		upload_data    = UploadData,
		upload_window  = UploadWindowSize
	},
	Response = send_request(StateData, Command, Argument),
	{response, ReqId, self(), Response}.

%% @private
send_request(SD0=#state_data{socket=Socket}, Command, Argument) ->
	case do_call(Socket, Command, Argument) of
		{ok, ReqRef} ->
			SD1 = SD0#state_data{req_ref=ReqRef},
			before_loop(SD1, read_initial)
	end.

%%%-------------------------------------------------------------------
%%% Loop functions
%%%-------------------------------------------------------------------

%% @private
loop(SD=#state_data{parent=Parent, stream_to=StreamTo, req_ref=ReqRef, socket=Socket, empty=Empty}, SN) ->
	receive
		{ftp, Socket, {ReqRef, {Code, Text}}} ->
			handle_ctrl(SD, SN, {Code, Text});
		{ftp, Socket, {ReqRef, Data}} when is_binary(Data) ->
			handle_data(SD, SN, Data);
		{ftp, Socket, {ReqRef, done}} ->
			handle_done(SD, SN);
		{data_part, StreamTo, Data} ->
			handle_send(SD, SN, Data);
		M={ftp, Socket, _Message} ->
			enqueue(SD, SN, M);
		M={ftp_error, Socket, _Reason} ->
			enqueue(SD, SN, M);
		M={ftp_closed, Socket} ->
			enqueue(SD, SN, M);
		{'EXIT', _, Reason} ->
			shutdown(SD, SN, Reason);
		{empty, Empty} when is_reference(Empty) ->
			lftpc_prim:setopts(Socket, [{active, once}]),
			loop(SD#state_data{empty=undefined}, SN);
		{'DOWN', _, process, Parent, _} ->
			shutdown(SD, SN, normal);
		{'DOWN', _, process, StreamTo, _} ->
			shutdown(SD, SN, normal);
		Info ->
			error_logger:error_msg(
				"~p ~p received unexpected message ~p in state ~p~nStateData: ~p~n",
				[?MODULE, self(), Info, SN, SD])
	end.

%% @private
before_loop(SD0=#state_data{empty=undefined}, SN) ->
	Empty = make_ref(),
	SD1 = SD0#state_data{empty=Empty},
	erlang:send_after(0, self(), {empty, Empty}),
	loop(SD1, SN);
before_loop(SD, SN) ->
	loop(SD, SN).

%% @private
enqueue(SD0=#state_data{rcvbuf=Rcvbuf, socket=Socket}, SN, M) ->
	SD1 = SD0#state_data{rcvbuf=queue:in(M, Rcvbuf)},
	case M of
		{ftp, Socket, _Message} ->
			loop(SD1, SN);
		{ftp_error, Socket, Reason} ->
			shutdown(SD1, SN, Reason);
		{ftp_closed, Socket} ->
			shutdown(SD1, SN, closed)
	end.

%% @private
handle_ctrl(SD0=#state_data{partial_download=false,
		partial_upload=false, upload_data=undefined,
		ctrl_buf=CtrlBuf}, read_initial, {Code, Text})
			when Code >= 100 andalso Code < 200 ->
	SD1 = SD0#state_data{ctrl_buf=[{Code, Text} | CtrlBuf]},
	before_loop(SD1, read_data);
handle_ctrl(SD0=#state_data{socket=Socket, partial_download=false,
		partial_upload=false, upload_data=UploadData,
		ctrl_buf=CtrlBuf}, read_initial, {Code, Text})
			when Code >= 100 andalso Code < 200 ->
	lftpc_prim:send(Socket, UploadData),
	lftpc_prim:done(Socket),
	SD1 = SD0#state_data{ctrl_buf=[{Code, Text} | CtrlBuf]},
	SD2 = SD1#state_data{upload_data=undefined},
	before_loop(SD2, read_ctrl);
handle_ctrl(SD=#state_data{partial_upload=true}, read_initial,
		{Code, Text}) ->
	partial_upload(SD, {Code, Text});
handle_ctrl(SD=#state_data{partial_download=true}, read_initial,
		{Code, Text}) ->
	partial_download(SD, {Code, Text});
handle_ctrl(SD0=#state_data{ctrl_buf=CtrlBuf}, read_initial,
		{Code, Text}) ->
	SD1 = SD0#state_data{ctrl_buf=[{Code, Text} | CtrlBuf]},
	before_loop(SD1, read_ctrl);
handle_ctrl(SD0=#state_data{ctrl_buf=CtrlBuf}, SN, {Code, Text})
		when SN =:= partial_download
		orelse SN =:= read_ctrl
		orelse SN =:= read_data ->
	SD1 = SD0#state_data{ctrl_buf=[{Code, Text} | CtrlBuf]},
	before_loop(SD1, SN).

%% @private
handle_data(SD=#state_data{stream_to=StreamTo}, SN=partial_download, Data) ->
	StreamTo ! {data_part, self(), Data},
	before_loop(SD, SN);
handle_data(SD0=#state_data{data_buf=DataBuf}, SN, Data)
		when SN =:= read_initial
		orelse SN =:= read_data ->
	SD1 = SD0#state_data{data_buf=[Data | DataBuf]},
	before_loop(SD1, SN).

%% @private
handle_done(SD0=#state_data{parent=Parent, stream_to=StreamTo,
		req_id=ReqId, socket=Socket, ctrl_buf=CtrlBuf},
		partial_download) ->
	_SD1 = flush_rcvbuf(SD0),
	lftpc_prim:controlling_process(Socket, Parent),
	Parent ! {response, ReqId, self(), Socket},
	StreamTo ! {ftp_eod, self(), lists:reverse(CtrlBuf)},
	{ok, no_return};
handle_done(SD0=#state_data{ctrl_buf=CtrlBuf, data_buf=DataBuf}, SN)
		when SN =:= read_ctrl
		orelse SN =:= read_data ->
	_SD1 = flush_rcvbuf(SD0),
	Ctrl = lists:reverse(CtrlBuf),
	Data = case DataBuf of
		[] ->
			undefined;
		_ ->
			lists:reverse(DataBuf)
	end,
	{ok, {Ctrl, Data}}.

%% @private
handle_send(SD=#state_data{socket=Socket}, partial_upload, ftp_eod) ->
	lftpc_prim:done(Socket),
	before_loop(SD, partial_download);
handle_send(SD=#state_data{stream_to=StreamTo, socket=Socket},
		SN=partial_upload, UploadData) ->
	lftpc_prim:send(Socket, UploadData),
	StreamTo ! {ack, self()},
	before_loop(SD, SN).

%% @private
shutdown(SD=#state_data{stream_to=StreamTo, req_id=ReqId,
		socket=Socket, parent=Parent}, SN, Reason) ->
	% error_logger:error_msg(
	% 	"~p ~p shutting down for reason ~p in state ~p~nStateData: ~p~n",
	% 	[?MODULE, self(), Reason, SN, SD]),
	ok = case Reason of
		timeout ->
			ok;
		_ ->
			StreamTo ! {response, ReqId, self(), {error, Reason}},
			ok
	end,
	_ = SN,
	_ = flush_rcvbuf(SD),
	lftpc_prim:controlling_process(Socket, Parent),
	exit(Reason).

%%%-------------------------------------------------------------------
%%% Download functions
%%%-------------------------------------------------------------------

%% @private
partial_download(SD0=#state_data{req_id=ReqId, stream_to=StreamTo,
		ctrl_buf=CtrlBuf, data_buf=DataBuf}, {Code, Text})
			when Code >= 100 andalso Code < 200 ->
	Ctrl = lists:reverse([{Code, Text} | CtrlBuf]),
	Download = self(),
	Response = {ok, {Ctrl, Download}},
	StreamTo ! {response, ReqId, self(), Response},
	SD1 = case DataBuf of
		[] ->
			SD0;
		_ ->
			StreamTo ! {data_part, self(), iolist_to_binary(lists:reverse(DataBuf))},
			SD0#state_data{data_buf=[]}
	end,
	SD2 = SD1#state_data{ctrl_buf=[]},
	before_loop(SD2, partial_download);
partial_download(SD0=#state_data{ctrl_buf=CtrlBuf}, {Code, Text}) ->
	SD1 = SD0#state_data{ctrl_buf=[{Code, Text} | CtrlBuf]},
	before_loop(SD1, read_ctrl).

%%%-------------------------------------------------------------------
%%% Upload functions
%%%-------------------------------------------------------------------

%% @private
partial_upload(SD0=#state_data{req_id=ReqId, stream_to=StreamTo,
		socket=Socket, ctrl_buf=CtrlBuf,
		upload_window=UploadWindowSize}, {Code, Text})
			when Code >= 100 andalso Code < 200 ->
	Ctrl = lists:reverse([{Code, Text} | CtrlBuf]),
	Upload = {self(), UploadWindowSize},
	Response = {ok, {Ctrl, Upload}},
	StreamTo ! {response, ReqId, self(), Response},
	SD1 = case SD0#state_data.upload_data of
		undefined ->
			SD0;
		UploadData ->
			lftpc_prim:send(Socket, UploadData),
			SD0#state_data{upload_data=undefined}
	end,
	SD2 = SD1#state_data{ctrl_buf=[]},
	before_loop(SD2, partial_upload);
partial_upload(SD0=#state_data{ctrl_buf=CtrlBuf}, {Code, Text}) ->
	SD1 = SD0#state_data{ctrl_buf=[{Code, Text} | CtrlBuf]},
	before_loop(SD1, read_ctrl).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
do_call(Socket, Command, undefined) ->
	lftpc_prim:call(Socket, Command);
do_call(Socket, Command, Argument) ->
	lftpc_prim:call(Socket, Command, Argument).

%% @private
flush_rcvbuf(SD0=#state_data{parent=Parent, rcvbuf=Rcvbuf}) ->
	case queue:out(Rcvbuf) of
		{{value, Message}, NewRcvbuf} ->
			Parent ! Message,
			SD1 = SD0#state_data{rcvbuf=NewRcvbuf},
			flush_rcvbuf(SD1);
		{empty, Rcvbuf} ->
			SD0
	end.
