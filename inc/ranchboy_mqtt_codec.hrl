%%%-------------------------------------------------------------------
%%% @author codmajik
%%% @copyright (C) 2015, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 11. Sep 2015 9:41 AM
%%%-------------------------------------------------------------------

-ifndef(ranchboy_mqtt_codec_h).
-define(ranchboy_mqtt_codec_h, true).

-author("Vincent Chinedu Okonkwo (me@codmajik.com)").

-define(MQTT_CONNECT, 1).
-define(MQTT_CONNACK, 2).
-define(MQTT_PUBLISH, 3).
-define(MQTT_PUBACK, 4).
-define(MQTT_PUBREC, 5).
-define(MQTT_PUBREL, 6).
-define(MQTT_PUBCOMP, 7).
-define(MQTT_SUBSCRIBE, 8).
-define(MQTT_SUBACK, 9).
-define(MQTT_UNSUBSCRIBE, 10).
-define(MQTT_UNSUBACK, 11).
-define(MQTT_PINGREQ, 12).
-define(MQTT_PINGRES, 13).
-define(MQTT_DISCONNECT, 14).

-type mqtt_cmd() :: 1..14.
-type mqtt_qos() :: 0..2.

-record(mqtt_will, {
  will_topic :: string(),
  will_msg :: string(),
  retail_will :: boolean(),
  will_qos :: mqtt_qos()
}).

-opaque mqtt_will() :: #mqtt_will{}.

-record(mqtt_topic, {
  topic :: string(),
  qos :: mqtt_qos()
}).

-opaque mqtt_topic() :: #mqtt_topic{}.

-record(mqtt_connect, {
  keep_alive :: non_neg_integer(),
  client_id :: string(),
  username :: string(),
  password :: binary(),
  will :: null | mqtt_will(),
  clean :: boolean()
}).

-opaque mqtt_connect() :: #mqtt_connect{}.

-record(mqtt_connack, {
  has_session :: boolean(),
  return_code :: non_neg_integer()
}).

-opaque mqtt_connack() :: #mqtt_connack{}.

-record(mqtt_publish, {
  topic :: string(),
  payload :: binary()
}).
-opaque mqtt_publish() :: #mqtt_publish{}.

-opaque mqtt_subscribe() :: list(mqtt_topic()).
-opaque mqtt_suback() :: list(non_neg_integer()).
-opaque mqtt_unsubscribe() :: list(string()).

-opaque mqtt_payload() :: null | mqtt_connect() | mqtt_connack() | mqtt_publish() |
mqtt_subscribe() | mqtt_suback() | mqtt_unsubscribe().

-record(mqtt_packet, {
  cmd :: mqtt_cmd(),
  dup = false :: boolean(),
  qos = 0 :: mqtt_qos(),
  retain = false :: boolean(),
  len = 0 :: non_neg_integer(),
  pkt_id = null :: null | integer(),
  payload = null :: mqtt_payload()
}).

-opaque mqtt_packet() :: #mqtt_packet{}.

-export_type([
  mqtt_qos/0,
  mqtt_cmd/0,
  mqtt_connect/0,
  mqtt_payload/0,
  mqtt_packet/0,
  mqtt_publish/0,
  mqtt_connack/0,
  mqtt_topic/0,
  mqtt_will/0,
  mqtt_unsubscribe/0,
  mqtt_subscribe/0,
  mqtt_suback/0
]).

-endif.
