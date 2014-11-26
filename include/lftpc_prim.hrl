%% -*- mode: erlang; tab-width: 4; indent-tabs-mode: 1; st-rulers: [70] -*-
%% vim: ts=4 sw=4 ft=erlang noet
%%%-------------------------------------------------------------------
%%% @author Andrew Bennett <andrew@pixid.com>
%%% @copyright 2014, Andrew Bennett
%%% @doc
%%%
%%% @end
%%% Created :  07 Nov 2014 by Andrew Bennett <andrew@pixid.com>
%%%-------------------------------------------------------------------

-ifndef(LFTPC_SOCK_HRL).

%% INLINE_UPPERCASE_BC(Bin)
%%
%% Uppercase the entire binary string in a binary comprehension.

-define(INLINE_UPPERCASE_BC(Bin),
	<< << case C of
		$a -> $A;
		$b -> $B;
		$c -> $C;
		$d -> $D;
		$e -> $E;
		$f -> $F;
		$g -> $G;
		$h -> $H;
		$i -> $I;
		$j -> $J;
		$k -> $K;
		$l -> $L;
		$m -> $M;
		$n -> $N;
		$o -> $O;
		$p -> $P;
		$q -> $Q;
		$r -> $R;
		$s -> $S;
		$t -> $T;
		$u -> $U;
		$v -> $V;
		$w -> $W;
		$x -> $X;
		$y -> $Y;
		$z -> $Z;
		C -> C
	end >> || << C >> <= Bin >>).

-define(LFTPC_SOCK_HRL, 1).

-endif.
