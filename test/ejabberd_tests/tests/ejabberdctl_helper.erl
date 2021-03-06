%%%-------------------------------------------------------------------
%%% @author ludwikbukowski
%%% @copyright (C) 2015, Erlang Solutions
%%% @doc
%%%
%%% @end
%%% Created : 12. Nov 2015 14:39
%%%-------------------------------------------------------------------
-module(ejabberdctl_helper).
-author("ludwikbukowski").
-include_lib("escalus/include/escalus.hrl").
-import(ejabberd_node_utils, [mim/0]).
%% API
-export([ejabberdctl/3, rpc_call/3]).

ejabberdctl(Cmd, Args, Config) ->
    Node = mim(),
    CtlCmd = distributed_helper:ctl_path(Node, Config),
    run(string:join([CtlCmd, Cmd | normalize_args(Args)], " ")).

rpc_call(M, F, Args) ->
    case escalus_ejabberd:rpc(M, F, Args) of
        {badrpc, Reason} ->
            ct:fail("~p:~p/~p with arguments ~w fails with reason ~p.",
                    [M, F, length(Args), Args, Reason]);
        Result ->
            Result
    end.

normalize_args(Args) ->
    lists:map(fun
                  (Arg) when is_binary(Arg) ->
                      binary_to_list(Arg);
                  (Arg) when is_list(Arg) ->
                      Arg
              end, Args).

run(Cmd) ->
    run(Cmd, 5000).

run(Cmd, Timeout) ->
    Port = erlang:open_port({spawn, Cmd},[exit_status]),
    loop(Port,[], Timeout).

loop(Port, Data, Timeout) ->
    receive
        {Port, {data, NewData}} -> loop(Port, Data++NewData, Timeout);
        {Port, {exit_status, ExitStatus}} -> {Data, ExitStatus}
    after Timeout ->
        throw(timeout)
    end.