%%%-------------------------------------------------------------------
%%% @author codmajik
%%% @copyright (C) 2015, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 11. Sep 2015 9:43 AM
%%%-------------------------------------------------------------------
-author("Vincent Chinedu Okonkwo (me@codmajik.com)").

-ifndef(ranchboy_openwire_codec_h).
-define(ranchboy_openwire_codec_h, true).


-record(openwire_stacktrace, {
  class   :: string(),
  method  :: string(),
  file    :: string(),
  line_no :: integer()
}).

-opaque openwire_stacktrace() :: #openwire_stacktrace{}.

-record(openwire_throwable, {
  name,
  msg,
  stack_trace :: list(openwire_stacktrace())
}).





-define(WIREFORMAT_INFO, 1).
-define(BROKER_INFO, 2).
-define(CONNECTION_INFO, 3).
-define(SESSION_INFO, 4).
-define(CONSUMER_INFO, 5).
-define(PRODUCER_INFO, 6).
-define(TRANSACTION_INFO, 7).
-define(DESTINATION_INFO, 8).
-define(REMOVE_SUBSCRIPTION_INFO, 9).
-define(KEEP_ALIVE_INFO, 10).
-define(SHUTDOWN_INFO, 11).
-define(REMOVE_INFO, 12).
-define(CONTROL_COMMAND, 14).
-define(FLUSH_COMMAND, 15).
-define(CONNECTION_ERROR, 16).
-define(CONSUMER_CONTROL, 17).
-define(CONNECTION_CONTROL, 18).
-define(MESSAGE_DISPATCH, 21).
-define(MESSAGE_ACK, 22).
-define(ACTIVEMQ_MESSAGE, 23).
-define(ACTIVEMQ_BYTES_MESSAGE, 24).
-define(ACTIVEMQ_MAP_MESSAGE, 25).
-define(ACTIVEMQ_OBJECT_MESSAGE, 26).
-define(ACTIVEMQ_STREAM_MESSAGE, 27).
-define(ACTIVEMQ_TEXT_MESSAGE, 28).
-define(RESPONSE, 30).
-define(EXCEPTION_RESPONSE, 31).
-define(DATA_RESPONSE, 32).
-define(DATA_ARRAY_RESPONSE, 33).
-define(INTEGER_RESPONSE, 34).
-define(DISCOVERY_EVENT, 40).
-define(JOURNAL_ACK, 50).
-define(JOURNAL_REMOVE, 52).
-define(JOURNAL_TRACE, 53).
-define(JOURNAL_TRANSACTION, 54).
-define(DURABLE_SUBSCRIPTION_INFO, 55).
-define(PARTIAL_COMMAND, 60).
-define(PARTIAL_LAST_COMMAND, 61).
-define(REPLAY, 65).
-define(BYTE_TYPE, 70).
-define(CHAR_TYPE, 71).
-define(SHORT_TYPE, 72).
-define(INTEGER_TYPE, 73).
-define(LONG_TYPE, 74).
-define(DOUBLE_TYPE, 75).
-define(FLOAT_TYPE, 76).
-define(STRING_TYPE, 77).
-define(BOOLEAN_TYPE, 78).
-define(BYTE_ARRAY_TYPE, 79).
-define(MESSAGE_DISPATCH_NOTIFICATION, 90).
-define(NETWORK_BRIDGE_FILTER, 91).
-define(ACTIVEMQ_QUEUE, 100).
-define(ACTIVEMQ_TOPIC, 101).
-define(ACTIVEMQ_TEMP_QUEUE, 102).
-define(ACTIVEMQ_TEMP_TOPIC, 103).
-define(MESSAGE_ID, 110).
-define(ACTIVEMQ_LOCAL_TRANSACTION_ID, 111).
-define(ACTIVEMQ_XA_TRANSACTION_ID, 112).
-define(CONNECTION_ID, 120).
-define(SESSION_ID, 121).
-define(CONSUMER_ID, 122).
-define(PRODUCER_ID, 123).
-define(BROKER_ID, 124).


-endif.