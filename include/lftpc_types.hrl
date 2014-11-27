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

-ifndef(LFTPC_TYPES_HRL).

-type partial_download_option() ::
	{part_size, non_neg_integer() | infinity} |
	{window_size, non_neg_integer() | infinity}.

-type partial_download_options() :: [partial_download_option()].

-type option() ::
	{partial_download, partial_download_options()} |
	{partial_upload, non_neg_integer() | infinity} |
	{send_retry, non_neg_integer()} |
	{stream_to, pid()}.

-type options() :: [option()].

-define(LFTPC_TYPES_HRL, 1).

-endif.
