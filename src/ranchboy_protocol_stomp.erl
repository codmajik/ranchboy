%%%-------------------------------------------------------------------
%%% @author Vincent Chinedu Okonkwo (codmajik@gmail.com)
%%% @doc
%%%
%%% @end
%%% Created : 25. Dec 2015 9:59 AM
%%%-------------------------------------------------------------------
-module(ranchboy_protocol_stomp).
-author("Vincent Chinedu Okonkwo (codmajik@gmail.com)").

%% API
-export([]).


parse(<< "CONNECT \r\n">>) -> ok.
