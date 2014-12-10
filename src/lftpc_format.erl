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
-module(lftpc_format).

-include("lftpc_inline.hrl").

%% API exports
-export([feat_decoder/0]).
-export([nlst_decoder/0]).

%%====================================================================
%% API functions
%%====================================================================

feat_decoder() ->
	{fun feat_decoder/2, undefined}.

nlst_decoder() ->
	{fun nlst_decoder/2, <<>>}.

%%%-------------------------------------------------------------------
%%% FEAT functions
%%%-------------------------------------------------------------------

%% @private
feat_decoder(undefined, {211, Text=[_ | Feat]}) ->
	case format_features(Feat, []) of
		[] ->
			{true, {211, Text}, undefined};
		Features ->
			{true, {211, Features}, undefined}
	end;
feat_decoder(undefined, Reply) ->
	{true, Reply, undefined}.

%% @private
format_feature(<< $\s, Rest/binary >>) ->
	format_feature(Rest);
format_feature(<< "END", _/binary >>) ->
	false;
format_feature(<<>>) ->
	false;
format_feature(Feature) ->
	{true, Feature}.

%% @private
format_features([Feat | Rest], Features) ->
	case format_feature(?INLINE_UPPERCASE_BC(Feat)) of
		{true, Feature} ->
			format_features(Rest, [Feature | Features]);
		false ->
			format_features(Rest, Features)
	end;
format_features([], Features) ->
	lists:reverse(Features).

%%%-------------------------------------------------------------------
%%% NLST functions
%%%-------------------------------------------------------------------

%% @private
nlst_decoder(Buf, Data) ->
	line_decoder(Buf, Data).

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
line_decoder(Buf, <<>>) ->
	{false, Buf};
line_decoder(Buf, Data) when is_binary(Buf) ->
	SoFar = << Buf/binary, Data/binary >>,
	case decode_lines(SoFar, []) of
		{true, Lines, Rest} ->
			{true, Lines, Rest};
		false ->
			{false, SoFar}
	end.

%% @private
decode_lines(Data, Acc) ->
	case decode_line(Data, <<>>) of
		{true, Line, Rest} ->
			decode_lines(Rest, [Line | Acc]);
		false ->
			case Acc of
				[] ->
					false;
				_ ->
					{true, lists:reverse(Acc), Data}
			end
	end.

%% @private
decode_line(<< $\r, $\n, Rest/binary >>, Line) ->
	{true, Line, Rest};
decode_line(<< C, Rest/binary >>, Line) ->
	decode_line(Rest, << Line/binary, C >>);
decode_line(<<>>, _) ->
	false.
