-module(ranchboy_gen_mqtt).

-behaviour(gen_fsm).

-type state() :: any().
-type terminate_reason() :: normal | {mqtt_proto_error, atom()} | atom().
-type context() :: {mqtt_client_state(), null | mqtt_packet()}.
-type qos_type() :: atleast_once | atmost_once | exactly_once.
-type pub_opts() :: list({qos, qos_type()} | {retain, boolean()} | {dup, boolean()}).

-type mqtt_reply_action() ::
  {sub, Topics :: list({ binary(), qos_type() })} |
  {unsub, Topics :: list(binary())} |
  {pub, {Topic :: string(), Data :: binary()} | {Topic :: string(), Data :: binary() | pub_opts()}}.

-type mqtt_return_action() :: {reply, mqtt_reply_action(), Context :: context(), State :: state()}.
-type terminate_return_action() :: {shutdown, Reason :: terminate_reason(), Context :: context(), State :: state()}.
-type return_action() :: {noreply, Context :: context(), State :: state()} | terminate_return_action().


-callback init(Opts :: list()) -> terminate_return_action().
-callback handle_mqtt_connect(Context :: context(), State :: state()) -> mqtt_return_action() | mqtt_client_state().

-callback handle_mqtt_publish(
    {Topic :: string(), Data :: binary(), QOS :: qos_type()},
    Context :: context(),
    State :: state()
) -> mqtt_return_action() | return_action().

-callback handle_mqtt_unsubscribe(
    Topic :: string(),
    Context :: context(),
    State :: state()
) -> mqtt_return_action() | return_action().

-callback handle_mqtt_subscribe(
    Topic :: string(),
    Context :: context(),
    State :: state()
) ->
  {noreply, Context :: context(), State :: state()} |
  {shutdown, normal, State :: state()} |
  {shutdown, Reason :: atom(), State :: state()}.


-callback handle_mqtt_info(
    _Data :: any(),
    Context :: context(),
    State :: state()
) -> mqtt_return_action() | return_action().

-callback mqtt_terminate(Reason::terminate_reason(), Context :: context(), State::state()) -> ok.

-record(state, {
  socket :: inet:socket(),
  transport :: ranch_tcp | ranch_ssl,
  cl_id :: nonempty_string(),
  username :: binary(),
  password :: binary(),
  user_state :: state(),
  data = <<>> :: binary(),
  pkt_id = 10 :: non_neg_integer(),
  timeout = 5 :: non_neg_integer(),
  module :: module(),
  trans_msg :: {atom(), atom(), atom()},
  conn_state :: connect_ack | ready
}).

-opaque mqtt_client_state() :: #state{}.

%% API
-export([init/1, handle_event/3, handle_sync_event/4, handle_info/3, terminate/3, code_change/4, format_status/2]).
-export([start_link/2]).

-export([connect/4, qos/1, set/3, ready/2]).

-export_type([mqtt_client_state/0]).

-define(MSECS(T), T * 1000).
-define(CONNACK, connack).
-define(READY, ready).

-include("../inc/ranchboy_mqtt_codec.hrl").


start_link(Mod, Opts) ->
  _ = code:ensure_loaded(Mod),
  gen_fsm:start_link(?MODULE, [Mod, Opts], []).

init([Mod, Opts]) ->
  case Mod:init(Opts) of
    {ok, #state{ transport = T} = Ctx, UState} ->
      mqtt_connect( Ctx#state{ module = Mod, user_state = UState, trans_msg = T:messages()});

    {error, Error} ->  {stop, Error};
    {stop, _} = R ->  R
  end.

handle_event(_Event, _StateName, _StateData) ->
  erlang:error(not_implemented).

handle_sync_event(_Event, _From, _StateName, _StateData) ->
  erlang:error(not_implemented).

handle_info({K, PSock}, StateName, #state{socket = Sock, timeout = T, trans_msg = TMsg} = S)
  when (K == element(1, TMsg) orelse K == element(2, TMsg) orelse K == element(2, TMsg)),  PSock =/= Sock ->
  {next_state, StateName, S, ?MSECS(T)};

handle_info({TMsg, Sock}, _, #state{socket = Sock, trans_msg = {_,TMsg, _}} = S) -> down(S, closed);
handle_info({TMsg, Sock, R}, _, #state{socket = Sock, trans_msg = {_, _, TMsg}} = S) -> down(S, {error, R});
handle_info({TMsg, Sock, Data}, StateName, #state{socket = Sock, transport = T, trans_msg = {TMsg, _, _}} = S) ->
  case do_handler(Data, StateName, S) of
    {terminate, E, S2} -> {stop, E, S2};
    {ok, S2} ->
      T:setopts(Sock, [{active, once}]),
      {next_state, ?READY, S2, ?MSECS(S2#state.timeout)}
  end;

handle_info(Info, ready, #state{module = Mod, user_state = U, transport = T, socket = Sock} = S) ->
  case resp(Mod:handle_mqtt_info(Info, S, U)) of
    {terminate, Reason, State} -> {terminate, Reason, State};

    {reply, ReplyData, #state{} = State} ->
      T:send(Sock, ReplyData),
      {next_state, ?READY, State, ?MSECS(State#state.timeout)};

    {noreply, State} ->
      {next_state, ?READY, State, ?MSECS(State#state.timeout)}
  end.

terminate(Reason, _, #state{ module = Mod, transport = T, socket = Sock, user_state = U} = Ctx) ->
  T:close(Sock),
  Mod:mqtt_terminate(Reason, Ctx, U),
  {stop, Reason, Ctx}.

code_change(_OldVsn, _StateName, _StateData, _Extra) ->
  erlang:error(not_implemented).

format_status(_Opt, #state{ module = Mod, socket = Sock, transport = T}) ->
  {ok, {IP, Port}} = T:sockname(Sock),
  io:format("gen_ranchboy_mqtt:~p -> ~p [~p (~p:~p)]", [self(), Mod, T:name(), IP, Port]).


%% this is the only send event we are expecting
ready(timeout, #state{ transport = T, socket = Sock, timeout = TO} = Ctx) ->
  T:send(Sock, ranchboy_codec_mqtt:encode(#mqtt_packet{ cmd = ?MQTT_PINGREQ })),
  {next_state, ready, Ctx, ?MSECS(TO)}.

set(#state{}=Ctx, timeout, T) when is_integer(T) -> Ctx#state{ timeout = T };
set(#state{}=Ctx, client_id, ID) when is_list(ID); is_binary(ID) -> Ctx#state{ cl_id = ID };
set(#state{}=Ctx, username, U) when is_list(U); is_binary(U) -> Ctx#state{ username = U };
set(#state{}=Ctx, password, P) when is_list(P); is_binary(P) -> Ctx#state{ password = P }.

qos({_, null}) -> null;
qos({_, #mqtt_packet{qos = Q}}) -> Q.

connect(ssl, Host, Port, Opts) -> do_connect(ranch_ssl, Host, Port, Opts);
connect(tcp, Host, Port, Opts) -> do_connect(ranch_tcp, Host, Port, Opts).


%%internal
do_connect(Transport, Host, Port, Opts) ->
  case Transport:connect(Host, Port, Opts) of
    {ok, Socket} ->
      {ok, #state{socket = Socket, transport = Transport}};

    Err -> Err
  end.

mqtt_connect(#state{transport = T, socket = Sock, username = U, password = Ps, cl_id = I} = S) ->

  Pkt = #mqtt_packet{
    cmd = ?MQTT_CONNECT,
    payload = #mqtt_connect{
      username = U,
      password = Ps,
      keep_alive = S#state.timeout,
      client_id = if not is_binary(I) -> <<"test">>; true -> I end
    }
  },
  T:send(Sock, ranchboy_codec_mqtt:encode(Pkt)),
  T:setopts(Sock, [{active, once}]),
  {ok, ?CONNACK, S, ?MSECS(S#state.timeout)}.


down(#state{}=S, Reason) ->  {stop, Reason, S}.

do_handler(Data, Mode, #state{socket = Sock, transport = Transport} = S) ->
  case handle(Data, Mode, S) of
    {terminate, Reason, State} ->
      {terminate, Reason, State};

    {more, Data, State} ->
      {ok, State#state{data = Data}};

    {reply, ReplyData, #state{data = OData} = State} ->
      Transport:send(Sock, ReplyData),
      do_handler(OData, Mode, State);

    {noreply, State} ->
      {ok, State}
  end.

handle(<<>>, _, #state{} = S) -> {noreply, S#state{data = <<>>}};
handle(<<Data/bytes>>, Mode, #state{data = OData} = S) ->
  ToDecode = case OData of
               {#mqtt_packet{} = H, <<ExtraData>>} -> {H, <<ExtraData/bits, Data>>};
               _ -> <<OData/bytes, Data/bytes>>
             end,

  case ranchboy_codec_mqtt:decode(ToDecode) of
    {more, <<Data/bytes>>} ->
      {more, Data, S};

    {ok, #mqtt_packet{cmd = CMD}, _} when
      CMD =:= ?MQTT_CONNECT;
      CMD =:= ?MQTT_SUBSCRIBE;
      CMD =:= ?MQTT_UNSUBSCRIBE;
      CMD =:= ?MQTT_PINGREQ;
      (CMD == ?MQTT_CONNACK andalso  Mode =/= ?CONNACK);
      (CMD =/= ?MQTT_CONNACK andalso  Mode == ?CONNACK) ->

      {terminate, {mqtt_error, proto}, S#state{data = <<>>}};

    {ok, #mqtt_packet{cmd = ?MQTT_DISCONNECT}, _} ->
      {terminate, normal, S#state{data = <<>>}};

    {ok, #mqtt_packet{} = P, Rest} ->
      case process(P, S) of
        {reply, Pkt, #state{} = S2} ->
          {reply, Pkt, S2#state{ data = Rest }};

        {ok, S2} ->
          handle(Rest, Mode, S2#state{data = <<>>});

        {stop, S2} ->
          {terminate, normal, S2}
      end;

    {mqtt_proto_error, Error} ->
      {terminate, {mqtt_error, Error}, S}
  end.

process(#mqtt_packet{ cmd = ?MQTT_PINGRES }, #state{} = Ctx) ->  {ok, Ctx};
process(#mqtt_packet{cmd = ?MQTT_CONNACK, payload = #mqtt_connack{ return_code = 0 }}, #state{module = Mod } = Ctx) ->
  resp(Mod:handle_mqtt_connect(Ctx, Ctx#state.user_state));

process(#mqtt_packet{cmd = ?MQTT_CONNACK,payload=#mqtt_connack{return_code=Code}}, #state{} = Ctx) ->
  down(Ctx, {connect_error, Code});

process(#mqtt_packet{cmd = ?MQTT_SUBACK,payload=[_|_]=Codes}, #state{ module = Mod, user_state = U} = Ctx) ->
  resp(Mod:handle_mqtt_subscribe(Codes, Ctx, U));

process(#mqtt_packet{cmd = ?MQTT_PUBLISH, qos = Q, payload = #mqtt_publish{topic = T, payload = D}}, #state{module = Mod}=S) ->
  resp(Mod:handle_mqtt_publish({T, D, qos_a(Q)}, S, S#state.user_state)).


resp({reply, {Cmd, Param}, #state{ pkt_id = Idx } = Ctx, UState}) ->
  P = reply(Cmd, Param),
  ID = case P#mqtt_packet.cmd of C when ?MQTT_PUBLISH; C == ?MQTT_SUBSCRIBE -> Idx + 1; _ -> Idx end,
  Pkt = ranchboy_codec_mqtt:encode(P#mqtt_packet{pkt_id = ID}),
  {reply, Pkt, Ctx#state{user_state = UState, pkt_id=ID}};

resp({ok, #state{} = Ctx, UState}) -> {ok, Ctx#state{user_state = UState}};
resp({stop, #state{} = Ctx, UState}) -> {stop, Ctx#state{ user_state = UState}}.


encode_subs([], Acc) -> Acc;
encode_subs([{<<Topic/bytes>>, QOS}|R], Acc) -> encode_subs(R, [ #mqtt_topic{topic =Topic, qos = qos_p(QOS)} |Acc]);
encode_subs([<<Topic/bytes>>|R], Acc) -> encode_subs(R, [ #mqtt_topic{topic=Topic, qos= qos_p(atleast_once)} |Acc]).


reply(sub, [_|_]=Topics) ->
  #mqtt_packet {
    cmd = ?MQTT_SUBSCRIBE,
    qos = qos_p(atmost_once),
    payload = encode_subs(Topics, [])
  };

reply(pub, {<<Topic/bytes>>, <<Data/bytes>>}) -> reply(pub, {Topic, Data, [{qos, atleast_once}]});
reply(pub, {<<Topic/bytes>>, <<Data/bytes>>, Props}) ->
  #mqtt_packet {
    cmd = ?MQTT_PUBLISH,
    qos = qos_p(proplists:get_value(qos, Props, atleast_once)),
    dup = proplists:get_value(dup, Props, false),
    retain = proplists:get_value(retain, Props, false),
    payload = #mqtt_publish{
      topic = Topic,
      payload = Data
    }
  }.

qos_p(atleast_once) -> 0;
qos_p(atmost_once) -> 1;
qos_p(exactly_once) -> 2.
qos_a(0) -> atleast_once;
qos_a(1) -> atmost_once;
qos_a(2) -> exactly_once.
