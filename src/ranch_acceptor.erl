%% Copyright (c) 2011-2015, Loïc Hoguin <essen@ninenines.eu>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

-module(ranch_acceptor).

-export([start_link/6]).
-export([loop/9]).

-spec start_link(any(), inet:socket(), module(), pid(), any(), any())
	-> {ok, pid()}.
start_link(Ref, LSocket, Transport, TransOpts, ConnsSup, Protocol) ->
	MaxConn = ranch_server:get_max_connections(Ref),
	ProtoOpts = ranch_server:get_protocol_options(Ref),
    AckTimeout = proplists:get_value(ack_timeout, TransOpts, 5000),

	Pid = spawn_link(?MODULE, loop, [Ref, LSocket, Transport, TransOpts,
				ConnsSup, AckTimeout, MaxConn, Protocol, ProtoOpts]),
	{ok, Pid}.

loop(Ref, LSocket, Transport, TransOpts, ConnsSup,
	AckTimeout, MaxConn, Protocol, ProtoOpts) ->
    process_flag(priority, high),
	process_flag(trap_exit, true),
	_ = case Transport:accept(LSocket, infinity) of
		{ok, CSocket} ->
			% ranch_conns_sup 单线程且占内存, infinity时不使用supervisor启动连接
			case MaxConn == infinity of
				true ->
					catch case Protocol:start_link(Ref, CSocket, Transport, ProtoOpts) of
						{ok, Pid} ->
							case Transport:controlling_process(CSocket, Pid) of
								ok ->
									Pid ! {shoot, Ref, Transport, CSocket, AckTimeout};
								Error ->
									Transport:close(CSocket),
									error_logger:error_msg("~p ~p", [Protocol, Error])
							end;
						Error ->
							error_logger:error_msg("~p ~p", [Protocol, Error])
					end;
				false ->
					case Transport:controlling_process(CSocket, ConnsSup) of
						ok ->
							%% This call will not return until process has been started
							%% AND we are below the maximum number of connections.

							ranch_conns_sup:start_protocol(ConnsSup, CSocket);
						{error, _} ->
							Transport:close(CSocket)
					end
			end;
		%% Reduce the accept rate if we run out of file descriptors.
		%% We can't accept anymore anyway, so we might as well wait
		%% a little for the situation to resolve itself.
		{error, emfile} ->
			receive after 100 -> ok end;
		%% We want to crash if the listening socket got closed.
		{error, Reason} when Reason =/= closed ->
			ok
	end,
	flush(),
	?MODULE:loop(Ref, LSocket, Transport, TransOpts, ConnsSup,
		AckTimeout, MaxConn, Protocol, ProtoOpts).

flush() ->
	receive Msg ->
		error_logger:error_msg(
			"Ranch acceptor received unexpected message: ~p~n",
			[Msg]),
		flush()
	after 0 ->
		ok
	end.
