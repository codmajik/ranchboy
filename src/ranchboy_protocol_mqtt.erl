-module(ranchboy_protocol_mqtt).
-author("Vincent Chinedu Okonkwo (codmajik@gmail.com)").

-behaviour(ranch_protocol).

-export([init/4, start_link/4]).
-export([setopt/2, socket/1, peername/1, sockname/1, set/3]).

-define(TIMEOUT, 5).
-define(MSECS(T), timer:seconds(T)).
-define(QOS_VAL(Q), (Q =:= atmost_once
    orelse Q =:= atlease_once orelse Q =:= extactly_once)).

-define(VAL_ID(Q, ID), (
      ?QOS_VAL(Q) andalso (
        (Q =:= atmost_once andalso ID =:= null)
          orelse (is_integer(ID) andalso ID > 0)
      )
  )).


-include("../inc/ranchboy_mqtt_codec.hrl").

-record(context, {
  socket :: ranch:ref(),
  transport :: module(),
  ka_timeout :: non_neg_integer(),
  ka_grace_period :: non_neg_integer(),
  timer :: timer:tref(),
  module :: module(),
  state :: any(),
  data = <<>> :: binary(),
  connected = false :: boolean()
}).

-opaque context() :: #context{}.

-export_type([context/0]).

start_link(Ref, Socket, Transport, Opts) ->
  Pid = spawn_link(?MODULE, init, [Ref, Socket, Transport, Opts]),
  {ok, Pid}.

init(Ref, Socket, Transport, [Mod, Opts]) when is_atom(Mod), is_list(Opts) ->
  ok = ranch:accept_ack(Ref),

  _ = code:ensure_loaded(Mod),

  Ctx = #context{
    socket = Socket,
    transport = Transport,
    timer = erlang:make_ref(),
    ka_timeout = ?MSECS(5),
    ka_grace_period = ?MSECS(3),
    module = Module
  },

  case Mod:init(Opts, Ctx) of
    {ok, Ctx2, State} ->
      loop(Ctx2#context{state = State});

    {terminate, Reason, _, State} ->
      down(Ctx#context{state = State}, Reason)
  end.

set(#context{} = Ctx, grace_period, V)
  when is_integer(V); V > 0 -> Ctx#context{ka_grace_period = V};
set(#context{} = Ctx, keepalive, V)
  when is_integer(V); V > 0 -> Ctx#context{ka_timeout = V}.

peername(#context{transport = T, socket = Sock}) -> T:peername(Sock).
sockname(#context{transport = T, socket = Sock}) -> T:sockname(Sock).
setopt(#context{transport = T, socket = Sock}, Opts) ->
  T:setopt(Sock, proplists:delete(active, Opts)).
socket(#context{socket = Sock}) -> Sock.

loop(#context{socket = Sock, transport = T, ka_timeout = TOut, timer = Tmr} = Ctx) ->

  {OK, Close, Err} = T:messages(),

  T:setopts(Sock, [{active, once}]),

  receive
    {OK, Sock, Data} ->

      %% this is just to make sure a busy process doesn't stave the connection
      erlang:cancel_timer(Tmr, [{async, true}, {info, false}]),
      case packet(Data, Ctx) of
        {ok, #context{ka_timeout = TOut2, ka_grace_period=GPeriod} = Ctx2} ->
          TRef = erlang:send_after(TOut2 + GPeriod, self(), {Err, Sock, timeout}),
          loop(Ctx2#context{timer = TRef});

        {E, Ctx2} -> down(Ctx2, E)
      end;

    {Close, Sock} -> down(Ctx, {error, transport_closed});

    {Err, Sock, E} -> down(Ctx, {error, E});


    {OK, _PSock_, _} when _PSock_ =/= Sock -> loop(Ctx);
    {Close, _PSock_} when _PSock_ =/= Sock -> loop(Ctx);
    {Err, _PSock_, _} when _PSock_ =/= Sock -> loop(Ctx);

    Data ->
      case info(Ctx, Data) of
        {ok, Ctx2} -> loop(Ctx2);
        {E, Ctx2} -> down(Ctx2, E)
      end

  after TOut + Ctx#context.ka_grace_period ->
    %%this might be problematic for when the process is busy with other non mqtt requested message
    down(Ctx, {error, timeout})
  end.

down(#context{socket = Sock, transport = T, module = Mod, timer = Tmr, state = S}, Reason) ->
  erlang:cancel_timer(Tmr, [{async, true}, {info, false}]),
  T:close(Sock),
  Mod:terminate(Reason, S).


publish_pkt({<<Topic/bytes>>, <<Data/bytes>>, #{qos := Q, retain := R, dup := Dup, id := PktID}})
  when is_boolean(R), is_boolean(Dup), ?VAL_ID(Q, PktID) ->
  #mqtt_packet{
    cmd = ?MQTT_PUBLISH,
    qos = qos_p(Q),
    dup = Dup,
    retain = R,
    pkt_id = PktID,
    payload = #mqtt_publish{
      topic = Topic,
      payload = Data
    }
  }.

info(#context{module = Mod, state = State} = Ctx, Msg) ->
  case Mod:handle_mqtt_info(Msg, Ctx, State) of
    {reply, {<<Topic/bytes>>, <<Data/bytes>>, #{} = Props}, #context{} = Ctx2, S} ->

      %% set some defaults
      Def = #{qos => atlease_once, dup => false, retain => false, id => null},
      send_packet(Ctx2, publish_pkt({Topic, Data, maps:merge(Def, Props)})),
      {ok, Ctx2#context{state = S}};

    {ok, Ctx2, S} ->
      {ok, Ctx2#context{state = S}};

    {terminate, Reason, Ctx2, S} ->
      {Reason, Ctx2#context{state = S}}

  end.

combine_data(<<Data/bytes>>, {#mqtt_packet{} = P, <<OldData/bytes>>}) -> {P, <<OldData/bytes, Data/bytes>>};
combine_data(<<Data/bytes>>, <<OldData/bytes>>) -> <<OldData/bytes, Data/bytes>>.

packet(<<>>, #context{} = Ctx) -> {ok, Ctx};
packet(<<Data/bytes>>, #context{connected = C, data = LeftOver} = Ctx) ->

  case ranchboy_codec_mqtt:decode(combine_data(Data, LeftOver)) of
    {ok, #mqtt_packet{cmd = CMD}, _} when
      (CMD =:= ?MQTT_CONNECT andalso C == true) orelse
      (CMD =/= ?MQTT_CONNECT andalso C == false) ->
        {{mqtt_proto_error, invalid_packet}, Ctx};

    {ok, {mqtt_proto_error, invalid_version} = E, _} ->
      ConnError = #mqtt_packet{
        cmd = ?MQTT_CONNACK,
        payload = #mqtt_connack{
          has_session = 0,
          return_code = 1
        }
      },

      send_packet(Ctx, ConnError),
      {E, Ctx};

    {ok, #mqtt_packet{} = Pkt, MoreData} ->
      case mqtt_proto(Pkt, Ctx) of
        {terminate, Reason, #context{} = Ctx2} -> {Reason, Ctx2};
        {noreply, #context{} = Ctx2} -> {ok, Ctx2};

        {K, #mqtt_packet{} = RespPkt, #context{} = Ctx2} ->
          case send_packet(Ctx2, RespPkt) of
            K -> packet(MoreData, Ctx2);
            {error, _} = E -> {E, Ctx2};
            _ -> {K, Ctx2}
          end
      end;

  %%wait for more data
    {more, {#mqtt_packet{cmd = CMD}, _}} when
      (CMD =:= ?MQTT_CONNECT andalso C == true);
      (CMD =/= ?MQTT_CONNECT andalso C == false) ->
        {{mqtt_proto_error, invalid_packet}, Ctx};

    {more, {#mqtt_packet{}, _} = L} ->
      {ok, Ctx#context{data = L}};

    {nore, <<Data2/bytes>>} ->
      {ok, Ctx#context{data = Data2}}
  end.

send_packet(#context{transport = T, socket = Sock}, #mqtt_packet{} = Pkt) ->
  T:send(Sock, ranchboy_codec_mqtt:encode(Pkt)).

connect_error_to_code(invalid_ident) -> 2;
connect_error_to_code(service_unavailable) -> 3;
connect_error_to_code(bad_credential) -> 4;
connect_error_to_code(not_authorized) -> 5;
connect_error_to_code(error) -> 99.

-spec mqtt_proto(mqtt_packet(), context()) ->
  {ok | noreply | terminate, mqtt_packet(), context()}.
mqtt_proto(#mqtt_packet{cmd = ?MQTT_CONNECT, payload = #mqtt_connect{} = P}, #context{module = Mod, connected = false} = Ctx) ->

  ConnInfo = #{
    id => P#mqtt_connect.client_id,
    user => P#mqtt_connect.username,
    password => P#mqtt_connect.password,
    clean => P#mqtt_connect.clean,
    keepalive => P#mqtt_connect.keep_alive
  },

  case Mod:handle_mqtt_connect(ConnInfo, Ctx, Ctx#context.state) of

    {ok, Ctx2, State} ->
      {
        ok,
        #mqtt_packet{
          cmd = ?MQTT_CONNACK,
          payload = #mqtt_connack{
            has_session = false,
            return_code = 0
          }
        },
        Ctx2#context{state = State, ka_timeout = ?MSECS(P#mqtt_connect.keep_alive), connected = true}
      };

    {terminate, Reason, Ctx2, State} ->
      {
        {mqtt_proto_error, Reason},
        #mqtt_packet{
          cmd = ?MQTT_CONNACK,
          payload = #mqtt_connack{
            has_session = false,
            return_code = connect_error_to_code(Reason)
          }
        },
        Ctx2#context{state = State, connected = false}
      }
  end;

mqtt_proto(#mqtt_packet{cmd = ?MQTT_DISCONNECT}, #context{} = Ctx) -> {terminate, {mqtt_proto, disconnect}, Ctx};
mqtt_proto(#mqtt_packet{cmd = ?MQTT_PINGREQ}, #context{module = Mod, state = State} = Ctx) ->
  case erlang:function_exported(Mod, handle_mqtt_ping, 2) of
    false -> {ok, #mqtt_packet{cmd = ?MQTT_PINGRES}, Ctx};
    true ->
      case Mod:handle_mqtt_ping(Ctx, State) of
        {ok, #context{} = Ctx2, State2} ->
          {ok, #mqtt_packet{cmd = ?MQTT_PINGRES}, Ctx2#context{state = State2}};

        {terminate, Reason, #context{} = Ctx2, State2} ->
          {terminate, Reason, Ctx2#context{state = State2}}
      end

  end;

mqtt_proto(#mqtt_packet{cmd = ?MQTT_PUBLISH, payload = #mqtt_publish{topic = T, payload = Data}} = P,
    #context{module = Mod} = Ctx) ->

  PropMap = #{
    qos => qos_a(P#mqtt_packet.qos),
    dup => P#mqtt_packet.dup,
    retain => P#mqtt_packet.retain,
    id => P#mqtt_packet.pkt_id
  },

  case Mod:handle_mqtt_publish({T, Data, PropMap}, Ctx, Ctx#context.state) of
    {ok, #context{} = Ctx2, State2} ->
      Ctx3 = Ctx2#context{state = State2},
      case P#mqtt_packet.qos of
        0 -> {noreply, Ctx3};
        1 ->
          {ok, #mqtt_packet{cmd = ?MQTT_PUBACK, pkt_id = P#mqtt_packet.pkt_id}, Ctx3};

        2 ->
          {ok, #mqtt_packet{cmd = ?MQTT_PUBREC, pkt_id = P#mqtt_packet.pkt_id}, Ctx3}
      end;

    {terminate, Reason, #context{} = Ctx2, State2} ->
      {terminate, Reason, Ctx2#context{state = State2}}

  end;

mqtt_proto(#mqtt_packet{cmd = ?MQTT_SUBSCRIBE, pkt_id = PktID, payload = [_ | _] = Subs}, #context{module = M} = C) ->
  case M:handle_mqtt_subscribe([{T, qos_a(Q)} || #mqtt_topic{topic = T, qos = Q} <- Subs], C, C#context.state) of
    {ok, #context{} = C2, S} ->
      Payload = [Q || #mqtt_topic{qos = Q} <- Subs],
      {ok, #mqtt_packet{cmd = ?MQTT_SUBACK, pkt_id = PktID, payload = Payload}, C2#context{state = S}};

    {ok, [_ | _] = Resps, #context{} = C2, S} when length(Resps) =:= length(Subs) ->
      Payload = [qos_p(Q) || Q <- Resps],
      {ok, #mqtt_packet{cmd = ?MQTT_SUBACK, pkt_id = PktID, payload = Payload}, C2#context{state = S}};

    {terminate, Reason, #context{} = Ctx2, State2} ->
      {terminate, Reason, Ctx2#context{state = State2}}
  end;

mqtt_proto(#mqtt_packet{}, #context{} = Ctx) -> {terminate, {mqtt_proto_error, invalid_packet}, Ctx}.

qos_p(atmost_once) -> 0;
qos_p(atleast_once) -> 1;
qos_p(exactly_once) -> 2.
qos_a(0) -> atmost_once;
qos_a(1) -> atleast_once;
qos_a(2) -> exactly_once.
