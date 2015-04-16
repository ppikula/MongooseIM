-module(mod_obfuscated_logs).
-author('giuseppe.modarelli@gmail.com').

%% {mod_lawful_interceptor, []},

-behaviour(gen_mod).

-export([start/2,
         stop/1]).

-export([on_filter_packet/1]).

-include_lib("ejabberd/include/ejabberd.hrl").
-include_lib("ejabberd/include/jlib.hrl").
-include_lib("exml/include/exml.hrl").

start(Host, _Opts) ->
  ?DEBUG("Obfuscated Logs Module Starting...", []),
  ejabberd_hooks:add(filter_local_packet, Host, ?MODULE, on_filter_packet, 0).

stop(Host) ->
  ?DEBUG("Obfuscated Logs Module Stopping...", []),
  ejabberd_hooks:delete(filter_local_packet, Host, ?MODULE, on_filter_packet, 0).

-type fpacket() :: {From :: ejabberd:jid(),
                    To :: ejabberd:jid(),
                    Packet :: jlib:xmlel()}.
-spec on_filter_packet(Value :: fpacket() | drop) -> fpacket() | drop.
on_filter_packet(drop) ->
    drop;
on_filter_packet({_From, _To, #xmlel{name = StanzaType}} = Packet) ->
  case StanzaType of
    <<"presence">> ->
      log_presence(Packet);
    <<"message">> ->
      log_message(Packet);
    <<"iq">> ->
      log_iq(Packet)
  end,

  Packet.

log_message({From, To, XML} = Packet) ->
    Type = xml:get_tag_attr_s(<<"type">>, XML),
    Id = xml:get_tag_attr_s(<<"id">>, XML),
    case is_valid_message_type(Type) of
      true ->
        ?INFO_MSG("[id:~s] [from:~s] [to:~s] [type:~s]",
                  [<<Id/binary>>, jlib:jid_to_binary(From), jlib:jid_to_binary(To), <<Type/binary>>]);
      false ->
        ok
    end.

log_presence(_Packet) -> ok.
log_iq(_Packet) -> ok.

is_valid_message_type(<<"">>)          -> true;
is_valid_message_type(<<"chat">>)      -> true;
is_valid_message_type(<<"groupchat">>) -> true;
is_valid_message_type(<<"error">>)     -> false;
is_valid_message_type(_)               -> false.
