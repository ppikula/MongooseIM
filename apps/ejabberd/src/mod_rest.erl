%%%-------------------------------------------------------------------
%%% File    : mod_rest.erl
%%% Author  : Pawel Pikula <pawel.pikula@erlang-solutions.com>
%%% Purpose : Provide an REST interface
%%%
%%% Copyright (C) 2013 Nolan Eakins
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%                         
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%-------------------------------------------------------------------

-module(mod_rest).
-author('pawel.pikula@erlang-solutions.com').

-behavior(gen_mod).

-export([start/2,stop/1]).

-include("ejabberd.hrl").
-include("jlib.hrl").
-include("ejabberd_http.hrl").
-include("ejabberd_ctl.hrl").

-define(DEFAULT_MAX_AGE, 1728000).  %% 20 days in seconds
-define(REST_LISTENER, mod_rest).
-define(INFO, <<"MongooseIM REST API version 0.1">>).

-type command() :: info | inject_stanza | get_commands |
                   get_alarms | execute_command.

-record(state, {cmd :: command()}).

%% ejabberd_cowboy API
-export ([cowboy_router_paths/1]).

%% cowboy callbacks 
-export([init/3,
         allowed_methods/2,
         rest_init/2,
         content_types_provided/2,
         content_types_accepted/2,
         terminate/3]).

%% response callbacks
-export([response/2, accept_args/2]).

%%--------------------------------------------------------------------
%% gen_mod callbacks
%%--------------------------------------------------------------------
start(_Host, Opts) ->
    start_cowboy(Opts),
    ok.

stop(_Host) ->
    cowboy:stop_listener(?REST_LISTENER).

%%--------------------------------------------------------------------
%% Callbacks implementation
%%--------------------------------------------------------------------

cowboy_router_paths(BasePath)->
    [
     {BasePath, ?REST_LISTENER,[info]},
     {[BasePath, "/stanza"], ?REST_LISTENER, [inject_stanza]}, % inject stanza
     {[BasePath, "/commands"], ?REST_LISTENER, [get_commands]}, % available commands
     {[BasePath, "/alarms"], ?REST_LISTENER, [get_alarms]}, % available alarms
     {[BasePath, "/command/:cmd_name/[...]"], ?REST_LISTENER, [execute_command]} % execute ejabberd command
    ].

start_cowboy(Opts) ->
    NumAcceptors = gen_mod:get_opt(num_acceptors, Opts, 10),
    IP = gen_mod:get_opt(ip, Opts, {0,0,0,0}),
    case gen_mod:get_opt(port, Opts, undefined) of
        undefined ->
            ok;
        Port ->
            Dispatch = cowboy_router:compile([{'_',cowboy_router_paths("/rest")}]),
            case cowboy:start_http(?REST_LISTENER, NumAcceptors,
                                   [{port, Port}, {ip, IP}],
                                   [{env, [{dispatch, Dispatch}]}]) of
                {error, {already_started, _Pid}} ->
                    ok;
                {ok, _Pid} ->
                    ok;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

terminate(_Reason, _Req, _State) ->
          ok.
%%--------------------------------------------------------------------
%% cowboy_rest callbacks
%%--------------------------------------------------------------------
-spec init({atom(), http}, cowboy_req:req(), any()) ->
    {upgrade, protocol, cowboy_rest}.
init(_Transport, _Req, _Opts) ->
    {upgrade, protocol, cowboy_rest}.

-spec rest_init(cowboy_req:req(), [command()]) ->
    {ok, cowboy_req:req(), #state{}}.
rest_init(Req, [Command]) ->
    {ok, Req, #state{cmd = Command}}.

-spec allowed_methods(cowboy_req:req(), #state{}) ->
    {[binary()],cowboy_req:req(), #state{}}.
allowed_methods(Req, #state{cmd = execute_command}=State) ->
    {[<<"POST">>], Req, State};
allowed_methods(Req, #state{cmd = inject_stanza}=State) ->
    {[<<"POST">>], Req, State};
allowed_methods(Req, State) ->
    {[<<"GET">>], Req, State}.

-spec content_types_provided(cowboy_req:req(), #state{}) ->
    {[{{binary(), binary(), []}, atom()}], cowboy_req:req(), #state{}}.
content_types_provided(Req, State) ->
    TypesProvided = [{{<<"application">>, <<"json">>, []}, response}],
    {TypesProvided, Req, State}.

-spec content_types_accepted(cowboy_req:req(), #state{}) -> 
    {[{{binary(), binary(), []}, atom()}], cowboy_req:req(), #state{}}.
content_types_accepted(Req, State) ->
	{[{{<<"application">>, <<"x-www-form-urlencoded">>, []}, accept_args}], Req, State}.

%%--------------------------------------------------------------------
%% response callbacks
%%--------------------------------------------------------------------

% check_member_option(Host, ClientAddress, allowed_ips),
%        {Code,Opts,Response} = maybe_post_request(Data,Host,ClientIP),
%        {ok,Resp} = cowboy_req:reply(Code,Opts,Response,R4),

-spec accept_args(cowboy_req:req(), #state{}) ->
    {boolean(), cowboy_req:req(), #state{}}.
accept_args(Req, #state{cmd = inject_stanza} = State) ->
    {Host, _} = cowboy_req:host(Req),
    {ClientIp, _} = cowboy_req:peer(Req),
    {ok, Data2, _} = cowboy_req:body(Req), 
    %%TODO: check ip? or it is done on higher level  previously returned 406 
    case catch inject_stanza(Data2,Host,ClientIp) of
        ok ->
            Req2 = cowboy_req:set_resp_body(encode_json({struct,[{result,ok}]}),Req),
            {true, Req2, State};
        {error, Reason} ->
            ?DEBUG("Error when processing REST request: ~nData: ~p~nError: ~p", [Data2, Reason]),
            Req2 = cowboy_req:set_resp_body(encode_json({struct,[{error, Reason}]}),Req),
            {ok, Req3} = cowboy_req:reply(500, Req2),
            {halt, Req3, State};
        {'EXIT', {{badmatch,_},_}=Error} -> 
            ?DEBUG("Error when processing REST request: ~nData: ~p~nError: ~p", [Data2, Error]),
            Req2 = cowboy_req:set_resp_body(encode_json({struct,[{error, <<"Request is not allowed">>}]}),Req),
            {ok, Req3} = cowboy_req:reply(406, Req2),
            {halt, Req3, State}
    end; 
accept_args(Req, #state{cmd = execute_command} = State) ->
    {Cmd,_} = cowboy_req:binding(cmd_name,Req),
    {Args,_} = cowboy_req:path_info(Req),
    Res = case ejabberd_ctl:process2([binary_to_list(Cmd) | [binary_to_list(A) || A <- Args]], []) of
        {"", ?STATUS_SUCCESS} ->
            integer_to_list(?STATUS_SUCCESS);
        {String, ?STATUS_SUCCESS} ->
            String;
        {"", Code} ->
            integer_to_list(Code);
        {String, _Code} ->
            String
    end,
    Req2 = cowboy_req:set_resp_body(encode_json({struct,[{result, iolist_to_binary(Res)}]}),Req),
    {true, Req2, State}.

-spec response(cowboy_req:req(), #state{}) ->
    {binary(), cowboy_req:req(), #state{}} | {halt, cowboy_req:req(), #state{}}.
response(Req, #state{cmd = info}=State) ->
    Response = encode_json({struct,[{result, ?INFO}]}),
    {Response, Req, State};
response(Req, #state{cmd = get_commands}=State) ->
    Commands = get_commands(),
    Response = encode_json({struct, [{status, ok}, {result, Commands}]}),
    {Response, Req, State};
response(Req, #state{cmd = get_alarms}=State) ->
    Alarms = get_alarms,
    Response = encode_json([{available_alarms, Alarms}]),
    {Response, Req, State};
response(Req, State) ->
    Response = encode_json({struct,[{info, ?INFO}]}),
    {Response, Req, State}.
%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------
get_alarms() ->
    %TODO: implement me
    [].

get_commands() ->
    Commands = get_list_commands()++get_list_ctls(),
    %% map commands to json structs
    [{struct, [{name, atom_to_binary(CmdName,utf8)},
               {args, lists:map(fun({Name, Type}) -> {struct, [{name, Name},{type,atom_to_binary(Type, utf8)}]} end, Args)},
               {desc, iolist_to_binary(Description)}]}
      || {CmdName, Args, Description} <- Commands ].

execute_command(_Cmd, _Args) ->
    ok.

inject_stanza(Data, Host, ClientIp) ->
    case xml_stream:parse_element(Data) of
        {error,{_, Reason}} ->
            {error,Reason};
        Stanza ->
            From = jlib:binary_to_jid(xml:get_tag_attr_s(<<"from">>, Stanza)),
            To = jlib:binary_to_jid(xml:get_tag_attr_s(<<"to">>, Stanza)),
            allowed = check_stanza(Stanza, From, To, Host),
            ?INFO_MSG("Got valid request from ~s~nwith IP ~p~nto ~s:~n~p",
                      [jlib:jid_to_binary(From),
                       ClientIp,
                       jlib:jid_to_binary(To),
                       Stanza]),
            % route message
            case ejabberd_router:route(From, To, Stanza) of
                ok -> ok;
                _  -> {error, <<"routing error">>}
            end
    end.

get_list_commands() -> 
    try ejabberd_commands:list_commands() of
        Commands -> Commands
    catch
        exit :_ ->
            []
    end.

get_list_ctls() ->
    case catch ets:tab2list(ejabberd_ctl_cmds) of
        {'EXIT', _} -> [];
        Cs -> [{NameArgs, [], Desc} || {NameArgs, Desc} <- Cs]
    end.

encode_json(Element) ->
    mochijson2:encode(Element).

%% This function crashes if the stanza does not satisfy configured restrictions
check_stanza(Stanza, _From, To, Host) ->
    check_member_option(Host, binary_to_list(jlib:jid_to_binary(To)), allowed_destinations),
    #xmlel{name = StanzaType} = Stanza,
    check_member_option(Host, binary_to_list(StanzaType), allowed_stanza_types),
    allowed.

%%--------------------------------------------------------------------
%% Old
%%--------------------------------------------------------------------
   
maybe_post_request(Data, Host, _ClientIp) ->
    ?INFO_MSG("Data: ~p", [Data]),
    AccessCommands = get_option_access(Host),
    case ejabberd_ctl:process2([], AccessCommands) of
	{"", ?STATUS_SUCCESS} ->
	    {200, [], integer_to_list(?STATUS_SUCCESS)};
	{String, ?STATUS_SUCCESS} ->
	    {200, [], String};
	{"", Code} ->
	    {200, [], integer_to_list(Code)};
	{String, _Code} ->
	    {200, [], String}
    end.

%% This function throws an error if the module is not started in that VHost.
try_get_option(Host, OptionName, DefaultValue) ->
    case gen_mod:is_loaded(Host, ?MODULE) of
	true -> ok;
	_ -> throw({module_must_be_started_in_vhost, ?MODULE, Host})
    end,
    gen_mod:get_module_opt(Host, ?MODULE, OptionName, DefaultValue).

get_option_access(Host) ->
    try_get_option(Host, access_commands, []).


check_member_option(Host, Element, Option) ->
    true = case try_get_option(Host, Option, all) of
	       all -> true;
	       AllowedValues -> lists:member(Element, AllowedValues)
	   end.

