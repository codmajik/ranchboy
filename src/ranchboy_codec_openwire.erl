-module(ranchboy_codec_openwire).

-export([decode/1, encode/1]).

-define(BIG_ENDIAN(V, B), V:(B*8)/big-integer).
-define(OW_CHAR(V), ?OW_SHORT(V)).
-define(OW_SHORT(V), ?BIG_ENDIAN(V,2)).
-define(OW_INT(V), ?BIG_ENDIAN(V, 4)).
-define(OW_LONG(V), ?BIG_ENDIAN(V, 8)).
-define(OW_FLOAT(V), V:4/big-float).
-define(OW_DOUBLE(V), V:8/big-float).

decode(<<Data/bytes>>) ->
  decode_bin_string(Data),
  decode_throwable(Data).

encode(_Data) ->
  erlang:error(not_implemented).



decode_bin_string(<<0:8, Rest/bytes>>) -> {<<>>, Rest};
decode_bin_string(<<1:8, Sz:16/big-integer, Rest/bytes>>) -> extract(Sz, Rest).

decode_throwable(<<0:8, Rest/bytes>>) -> {<<>>, Rest};
decode_throwable(<<1:8, ?OW_SHORT(Sz), Rest/bytes>>) ->
  {<<>>,Sz,  Rest}.


extract(Sz, <<Data/bytes>>) ->
  <<Value:Sz/bytes, Rest/bytes>> = Data,
  {Value, Rest}.
