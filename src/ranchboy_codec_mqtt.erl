-module(ranchboy_codec_mqtt).


%% API
-export([decode/1, encode/1]).

-include("../inc/ranchboy_mqtt_codec.hrl").

-define(UFMSB(Sz), Sz / big-integer-unsigned).
-define(NO_PKT_ID(C, Q), ((C < ?MQTT_PUBACK orelse C > ?MQTT_UNSUBACK ) orelse (C =:= ?MQTT_PUBLISH andalso Q =:= 0))).
-define(NO_PAYLOAD(C), ((C > ?MQTT_PUBLISH andalso C < ?MQTT_SUBSCRIBE) orelse C > ?MQTT_UNSUBSCRIBE)).

bin_while_not_empty(<<>>, Acc, _) -> Acc;
bin_while_not_empty(<<Bin/bytes>>, Acc, ApplyFn) ->
  {Bin2, Acc2} = ApplyFn(Bin, Acc),
  bin_while_not_empty(Bin2, Acc2, ApplyFn).

-spec(decode(binary() | {mqtt_packet(), binary()}) ->
  {ok, {mqtt_packet(), binary()}} | {more, {mqtt_packet(), binary()}} | {more, binary()} | {mqtt_proto_error, atom()}).
decode({#mqtt_packet{cmd = C, len = L} = _, _}) when L > 2, ?NO_PAYLOAD(C) -> {mqtt_proto_error, packet_too_large};
decode({#mqtt_packet{len = L} = H, Data}) when is_binary(Data), L > size(Data) -> {more, {H, Data}};
decode({#mqtt_packet{} = H, Data}) when is_binary(Data) -> decode_packet(H, Data);
decode(Data) when is_binary(Data) ->
  case decode_header(Data) of
    {ok, {H, Rest}} -> decode({H, Rest});
    {more, _} -> {more, Data}
  end.

-spec(decode_len(binary()) -> {non_neg_integer(), binary()} | error).
decode_len(<<Rest/bits>>) -> len_do_decode(true, Rest, 1, 0).
len_do_decode(false, <<Rest/bytes>>, _, Acc) -> {Acc, Rest};
len_do_decode(true, <<>>, _, _) -> more;
len_do_decode(true, _, _, Acc) when Acc > 268435455 -> {mqtt_proto, bad_length};
len_do_decode(true, <<L:8/integer, Rest/bits>>, Mul, Acc) ->
  len_do_decode((L band 128) =/= 0, Rest, Mul * 128, Acc + ((L band 127) * Mul)).

-spec(decode_mqtt_utf8(binary()) -> {binary(), binary()}).
decode_mqtt_utf8(<<0:16, B/binary>>) -> {<<>>, B};
decode_mqtt_utf8(<<Sz:?UFMSB(16), B/bytes>>) ->
  <<Data:Sz/bytes, Rest/bits>> = B,
  {Data, Rest}.

-spec(extract_payload(mqtt_packet(), binary()) -> {mqtt_packet(), binary(), binary()}).
extract_payload(#mqtt_packet{cmd = C, len = L, qos = QOS} = H, <<Data/bytes>>) when ?NO_PKT_ID(C, QOS) ->
  <<PktData:L/bytes, Rest/bytes>> = Data,
  {H, PktData, Rest};

extract_payload(#mqtt_packet{len = L} = H, <<Data/bytes>>) ->
  Sz = L - 2,
  <<ID:16/integer-unsigned, PktData:Sz/bytes, Rest/bytes>> = Data,
  {H#mqtt_packet{pkt_id = ID}, PktData, Rest}.


-spec decode_will(binary(), binary()) -> {mqtt_will() | null, binary()}.
decode_will(<<_:2, _:1, _:2, 0:1, _/bits>>, Bin) -> {null, Bin};
decode_will(<<_:2, Retain:1, QOS:2, 1:1, _/bits>>, Bin) ->
  {Topic, Rest} = decode_mqtt_utf8(Bin),
  {Msg, Rest1} = decode_mqtt_utf8(Rest),
  {#mqtt_will{will_topic = Topic, will_msg = Msg, will_qos = QOS, retail_will = Retain}, Rest1}.


decode_header(<<Cmd:4/big-integer, Dup:1, QOS:2, Retain:1, Rest/binary>> = Data) when Cmd > 0, Cmd < 15 ->
  case decode_len(Rest) of
    more -> {more, Data};
    {Len, Rest2} ->
      {ok, {#mqtt_packet{cmd = Cmd, dup = Dup =:= 1, qos = QOS, retain = Retain == 1, len = Len}, Rest2}}
  end.

decode_packet(#mqtt_packet{} = H, Data) when is_binary(Data) ->
  {H2, Pkt, Rest} = extract_payload(H, Data),
  {ok, decode_pkt(H2, Pkt), Rest}.


-spec decode_pkt(mqtt_packet(), binary()) -> mqtt_packet() | {mqtt_proto_error, binary() | atom()}.
decode_pkt(#mqtt_packet{cmd = C} = H, _) when ?NO_PAYLOAD(C) -> H;
decode_pkt(#mqtt_packet{cmd = ?MQTT_CONNECT} = H, <<Data/bytes>>) ->

  case Data of
    <<0:8, 4:8, "MQTT", 4:8, Flags:8/bits, KA:?UFMSB(16), Rest/bits>> ->
      {ClientID, Rest1} = decode_mqtt_utf8(Rest),

      {Will, Rest2} = decode_will(Flags, Rest1),

      <<U:1, P:1, _:4, C:1, _/bits>> = Flags,
      {User, Rest3} = if U =:= 1 -> decode_mqtt_utf8(Rest2); true -> {<<>>, Rest2} end,


      H#mqtt_packet{
        payload = #mqtt_connect{
          keep_alive = KA,
          client_id = ClientID,
          clean = C =:= 1,
          will = Will,
          username = User,
          password = coalesce(P =:= 1, Rest3, <<>>)
        }
      };
    _ -> {mqtt_proto_error, invalid_version}
  end;

decode_pkt(#mqtt_packet{cmd = ?MQTT_CONNACK, len = 2} = H, <<0:7, SP:1, RetCode:8>>) ->
  H#mqtt_packet{payload = #mqtt_connack{has_session = SP =:= 1, return_code = RetCode}};

decode_pkt(#mqtt_packet{cmd = ?MQTT_PUBLISH, qos = QOS} = H, Data) ->
  case decode_mqtt_utf8(Data) of
    {Topic, Rest} when size(Topic) > 0 ->
      {PktID, Payload} = if
                           QOS =:= 0 -> {null, Rest};
                           true ->
                             <<ID:?UFMSB(16), R/bytes>> = Rest,
                             {ID, R}
                         end,
      H#mqtt_packet{
        pkt_id = PktID,
        payload = #mqtt_publish{
          topic = Topic,
          payload = Payload
        }
      };
    {<<>>, _} ->
      {mqtt_proto_error, no_topic}
  end;

decode_pkt(#mqtt_packet{cmd = ?MQTT_SUBSCRIBE} = H, <<Data/bytes>>) ->
  H#mqtt_packet{
    payload = lists:reverse(bin_while_not_empty(Data, [],
      fun(Bin, Acc) ->
        {Topic, <<0:6, QOS:2, Rest/bytes>>} = decode_mqtt_utf8(Bin),
        {Rest, [#mqtt_topic{topic = Topic, qos = QOS} | Acc]}
      end))
  };

decode_pkt(#mqtt_packet{cmd = ?MQTT_SUBACK} = H, <<Data/bytes>>) ->
  H#mqtt_packet{
    payload = [C || <<C:8/integer>> <= Data]
  };

decode_pkt(#mqtt_packet{cmd = ?MQTT_UNSUBSCRIBE} = H, <<Data/bytes>>) ->
  H#mqtt_packet{
    payload = bin_while_not_empty(Data, [],
      fun(Rem, Acc) ->
        {Topic, Rest} = decode_mqtt_utf8(Rem),
        {Rest, [Topic | Acc]}
      end)
  }.

is_present(K) when is_binary(K) -> true;
is_present(_) -> false.

bool_to_int(true) -> 1;
bool_to_int(1) -> 1;
bool_to_int(_) -> 0.

keep_alive(K) when is_integer(K) -> <<K:16/big-integer-unsigned>>;
keep_alive(_) -> <<0:16/big-integer-unsigned>>.


coalesce(false, _, Result) -> Result;
coalesce(true, Result, _) -> Result.

%% encoder
w_mqtt_utf8(Len, <<Data/bytes>>) -> <<Len:16/big-unsigned-integer, Data:Len/binary>>.
encode_mqtt_utf8(Data) when not is_binary(Data) -> <<>>;
encode_mqtt_utf8(<<Data/bytes>>) when size(Data) < 65536 -> w_mqtt_utf8(size(Data), Data).

encode_len(0) -> <<0:8>>;
encode_len(L) -> lists:reverse(len_do_encode(L, [])).
len_do_encode(0, B) -> B;
len_do_encode(L, B) ->
  R = L div 128,
  len_do_encode(R, [<<((L rem 128) bor coalesce(R > 0, 128, 0)):8/integer>> | B]).

encode_pkt_id(#mqtt_packet{cmd = C, qos = QOS, pkt_id = ID}) when not is_integer(ID); ?NO_PKT_ID(C, QOS) -> <<>>;
encode_pkt_id(#mqtt_packet{pkt_id = PktID}) -> <<PktID:16>>.

encode(#mqtt_packet{cmd = Cmd, dup = Dup, qos = QOS, retain = Retain} = H) ->
  PktID = encode_pkt_id(H),
  Payload = encode_pkt(H),
  [<<Cmd:4/big-integer, (bool_to_int(Dup)):1, QOS:2, (bool_to_int(Retain)):1>>,
    encode_len(iolist_size(Payload) + size(PktID)), PktID, Payload].

-spec(encode_pkt(mqtt_packet()) -> binary()).
encode_pkt(#mqtt_packet{cmd = C, payload = null}) when ?NO_PAYLOAD(C) -> <<>>;

encode_pkt(#mqtt_packet{cmd = ?MQTT_CONNACK, payload = #mqtt_connack{has_session = SP, return_code = Code}}) ->
  SPInt = if SP == false -> 0; true -> 1 end,
  <<0:7, SPInt:1, Code:8>>;

encode_pkt(#mqtt_packet{cmd = ?MQTT_PUBLISH, payload = #mqtt_publish{topic = T, payload = Data}} = H) ->
  [encode_mqtt_utf8(T), encode_pkt_id(H), Data];

encode_pkt(#mqtt_packet{cmd = ?MQTT_SUBSCRIBE, payload = [_ | _] = Topics}) ->
  [[encode_mqtt_utf8(T), <<0:6, Q:2>>] || #mqtt_topic{topic = T, qos = Q} <- Topics];

encode_pkt(#mqtt_packet{cmd = ?MQTT_SUBACK, payload = [_ | _] = TopicCodes}) -> [<<T:8>> || T <- TopicCodes];
encode_pkt(#mqtt_packet{cmd = ?MQTT_UNSUBSCRIBE, payload = [_ | _] = Topics}) -> [encode_mqtt_utf8(T) || T <- Topics];
encode_pkt(#mqtt_packet{cmd = ?MQTT_CONNECT, payload = #mqtt_connect{clean = Clean} = P}) ->

  HasUsername = is_present(P#mqtt_connect.username),
  HasPassword = is_present(P#mqtt_connect.password),
  Will = case P#mqtt_connect.will of
           #mqtt_will{retail_will = R, will_qos = Q} ->
             <<1:1, Q:2, (bool_to_int(R)):1>>;
           _ -> <<0:4>>
         end,
  [
    <<0:8, 4:8, "MQTT", 4:8,
      (bool_to_int(HasUsername)):1,
        (bool_to_int(HasPassword)):1,
          Will:4/bits, (bool_to_int(Clean)):1, 0:1>>,
    keep_alive(P#mqtt_connect.keep_alive),
    encode_mqtt_utf8(P#mqtt_connect.client_id),
    encode_will(P#mqtt_connect.will),
    encode_mqtt_utf8(P#mqtt_connect.username),
    encode_mqtt_utf8(P#mqtt_connect.password)
  ].

encode_will(#mqtt_will{will_msg = M, will_topic = T}) -> [encode_mqtt_utf8(T), encode_mqtt_utf8(M)];
encode_will(_) -> <<>>.


validate_topic(<<>>) -> ok.
