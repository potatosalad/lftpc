%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <andrew@pixid.com>
%%% @copyright 2014, Andrew Bennett
%%% @doc user-FTP process
%%%
%%% @end
%%% Created :  31 Oct 2014 by Andrew Bennett <andrew@pixid.com>
%%%-------------------------------------------------------------------
-module(lftpc_protocol).

%% API exports
-export([new_decoder/0]).
-export([decode/2]).
-export([parse_epsv/1]).
-export([parse_pasv/1]).

-record(decoder, {
	mode = idle      :: idle | more,
	code = undefined :: undefined | {1..5, 0..9, 0..9},
	text = []        :: [binary()]
}).

-opaque decoder() :: #decoder{}.
-export_type([decoder/0]).

%%====================================================================
%% API functions
%%====================================================================

new_decoder() ->
	#decoder{}.

decode(Binary = << A, B, C, $-, Rest/binary >>, Decoder=#decoder{mode=idle, text=Text})
		when A >= $1 andalso A =< $5
		andalso B >= $0 andalso B =< $5
		andalso C >= $0 andalso C =< $9 ->
	case decode_line(Rest, <<>>) of
		{true, Line, SoFar} ->
			decode(SoFar, Decoder#decoder{mode=more, code={A,B,C}, text=[Line | Text]});
		false ->
			{false, Binary, Decoder}
	end;
decode(Binary = << A, B, C, $\s, Rest/binary >>, Decoder=#decoder{mode=idle})
		when A >= $1 andalso A =< $5
		andalso B >= $0 andalso B =< $5
		andalso C >= $0 andalso C =< $9 ->
	case decode_line(Rest, <<>>) of
		{true, Line, SoFar} ->
			{true, {((A-$0) * 100) + ((B-$0) * 10) + (C-$0), [Line]}, SoFar, Decoder};
		false ->
			{false, Binary, Decoder}
	end;
decode(Binary = << A, B, C, $\s, Rest/binary >>, Decoder=#decoder{mode=more, code={A,B,C}, text=Text}) ->
	case decode_line(Rest, <<>>) of
		{true, Line, SoFar} ->
			{true, {((A-$0) * 100) + ((B-$0) * 10) + (C-$0), lists:reverse([Line | Text])}, SoFar, Decoder#decoder{mode=idle, code=undefined, text=[]}};
		false ->
			{false, Binary, Decoder}
	end;
decode(Binary = << A, B, C, $-, Rest/binary >>, Decoder=#decoder{mode=more, code={A,B,C}, text=Text}) ->
	case decode_line(Rest, <<>>) of
		{true, Line, SoFar} ->
			decode(SoFar, Decoder#decoder{text=[Line | Text]});
		false ->
			{false, Binary, Decoder}
	end;
decode(Binary, Decoder=#decoder{mode=more, text=Text}) ->
	case decode_line(Binary, <<>>) of
		{true, Line, SoFar} ->
			decode(SoFar, Decoder#decoder{text=[Line | Text]});
		false ->
			{false, Binary, Decoder}
	end;
decode(Binary = <<>>, Decoder=#decoder{}) ->
	{false, Binary, Decoder}.

parse_epsv(<< $(, $|, $|, $|, Rest/binary >>) ->
	parse_epsv_port(Rest, 0, 0);
parse_epsv(<< _, Rest/binary >>) ->
	parse_epsv(Rest);
parse_epsv(<<>>) ->
	false.

parse_pasv(Rest = << C, _/binary >>) when C >= $0 andalso C < $9 ->
	parse_pasv_host(Rest, 0, 0, 0, []);
parse_pasv(<< _, Rest/binary >>) ->
	parse_pasv(Rest);
parse_pasv(<<>>) ->
	false.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

%% @private
decode_line(<< $\r, $\n, Rest/binary >>, Line) ->
	{true, Line, Rest};
decode_line(<< $\r >>, _Line) ->
	false;
decode_line(<< C, Rest/binary >>, Line) ->
	decode_line(Rest, << Line/binary, C >>);
decode_line(<<>>, _Line) ->
	false.

%%%-------------------------------------------------------------------
%%% EPSV
%%%-------------------------------------------------------------------

%% @private
parse_epsv_port(Rest, 6, _) ->
	parse_epsv(Rest);
parse_epsv_port(Rest, _, Port) when Port > 16#ffff ->
	parse_epsv(Rest);
parse_epsv_port(<< $|, $), Rest/binary >>, _, Port) when Port > 0 ->
	{true, Port, Rest};
parse_epsv_port(<< C, Rest/binary >>, I, Port)
		when C >= $0 andalso C =< $9 ->
	parse_epsv_port(Rest, (I + 1), (Port * 10) + (C - $0));
parse_epsv_port(Rest, _, _) ->
	parse_epsv(Rest).

%%%-------------------------------------------------------------------
%%% PASV
%%%-------------------------------------------------------------------

%% @private
parse_pasv_host(Rest, 0, 4, 0, [A3,A2,A1,A0]) ->
	parse_pasv_port(Rest, 0, 0, 0, {A0,A1,A2,A3}, 0);
parse_pasv_host(<< $,, Rest/binary >>, I, J, X, Host)
		when I > 0 andalso J < 4 ->
	X = case X of
		_ when X > 16#FF ->
			parse_pasv(Rest);
		_ ->
			X
	end,
	parse_pasv_host(Rest, 0, (J + 1), 0, [X | Host]);
parse_pasv_host(<< C, Rest/binary >>, I, J, X, Host)
		when I =< 2 andalso C >= $0 andalso C =< $9 ->
	parse_pasv_host(Rest, (I + 1), J, (X * 10) + (C - $0), Host);
parse_pasv_host(<< _, Rest/binary >>, _, _, _, _) ->
	parse_pasv(Rest);
parse_pasv_host(_, _, _, _, _) ->
	false.

%% @private
parse_pasv_port(<< $,, Rest/binary >>, I, J, X, Host, Port)
		when I > 0 andalso J < 1 ->
	parse_pasv_port(Rest, 0, (J + 1), 0, Host, (Port bsl 8) + X);
parse_pasv_port(<< C, Rest/binary >>, I, J, X, Host, Port)
		when I =< 2 andalso C >= $0 andalso C =< $9 ->
	parse_pasv_port(Rest, (I + 1), J, (X * 10) + (C - $0), Host, Port);
parse_pasv_port(Rest, I, 1, X, Host, Port)
		when I > 0 ->
	NewPort = (Port bsl 8) + X,
	case NewPort of
		0 ->
			parse_pasv(Rest);
		_ when NewPort > 16#FFFF ->
			parse_pasv(Rest);
		_ ->
			{true, {Host, NewPort}, Rest}
	end;
parse_pasv_port(<< _, Rest/binary >>, _, _, _, _, _) ->
	parse_pasv(Rest);
parse_pasv_port(_, _, _, _, _, _) ->
	false.
