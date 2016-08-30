-module(ranchboy_mqtt_handler).
-author("Vincent Chinedu Okonkwo (codmajik@gmail.com)").

-type context() :: ranchboy_protocol_mqtt:context().
-type state() :: any().
-type packet_id() :: non_neg_integer().
-type qos() :: atlease_once | atmost_once | exactly_once.
-type pub_ack() :: ack | received | release | complete.

-type pub_header() :: #{qos => qos(), dup => boolean(), retain => boolean(), id => null | non_neg_integer()}.

-type connect_info() :: #{id => nonempty_string(), user => string(), password => binary(), clean => boolean()}.
-type connect_error() :: invalid_ident | service_unavailable | bad_credential | not_authorized | error.

-callback init(Opts :: list(), Context :: context()) ->
  {ok, Context :: context(), State :: state()} |
  {terminate, Reason :: atom(), Context :: context(), State :: state()}.

-callback handle_mqtt_connect(ConnectionInfo :: connect_info(), Context :: context(), State :: state()) ->
  {ok, Context :: context(), State :: state()} |
  {terminate, Reason :: connect_error(), Context :: context(), State :: state()}.

-callback handle_mqtt_publish(
    {Topic :: nonempty_string(), Data :: binary(), Hdr :: pub_header()}, Context :: context(), State :: state()) ->
  {ok, Context :: context(), State :: state()} | %% this would acknowledge the pub based on qos pub_ack | pub_rec
  {terminate, Reason :: atom(), Context :: context(), State :: state()}.

%% this is only called for qos() =/= atleast_once messages
-callback handle_mqtt_published({PktID :: packet_id(), Ack :: pub_ack()}, Context :: context(), State :: state()) ->
  {ok, Context :: context(), State :: state()} |
  {terminate, Reason :: atom(), Context :: context(), State :: state()}.

-callback handle_mqtt_subscribe(Topics :: list({nonempty_string(), qos()}), Context :: context(), State :: state()) ->
  {ok, Context :: context(), State :: state()} |
  {ok, list(qos()), Context :: context(), State :: state()} |
  {terminate, Reason :: atom(), Context :: context(), State :: state()}.

-callback handle_mqtt_unsubscribe(Topics :: list(nonempty_string()), Context :: context(), State :: state()) ->
  {ok, Context :: context(), State :: state()} |
  {terminate, Reason :: atom(), Context :: context(), State :: state()}.

-callback handle_mqtt_ping(Context :: context(), State :: state()) ->
  {ok, Context :: context(), State :: state()} |
  {terminate, Reason :: atom(), Context :: context(), State :: state()}.

-callback handle_mqtt_info(Data :: any(), Context :: context(), State :: state()) ->
  {ok, Context :: context(), State :: state()} |
  {reply, {Topic :: nonempty_string(), Data :: binary(), Hdr :: pub_header()}, Ctx :: context(), State :: state()} |
  {terminate, Reason :: binary(), Context :: context(), State :: state()}.

-callback terminate(Reason :: atom(), State :: state()) -> any().

-optional_callbacks([handle_mqtt_ping/2]).
-optional_callbacks([handle_mqtt_published/3]).
