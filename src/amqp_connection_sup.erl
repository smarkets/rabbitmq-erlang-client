%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is the RabbitMQ Erlang Client.
%%
%%   The Initial Developers of the Original Code are LShift Ltd.,
%%   Cohesive Financial Technologies LLC., and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd., Cohesive Financial
%%   Technologies LLC., and Rabbit Technologies Ltd. are Copyright (C)
%%   2007 LShift Ltd., Cohesive Financial Technologies LLC., and Rabbit
%%   Technologies Ltd.;
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ____________________.

%% @private
-module(amqp_connection_sup).

-include("amqp_client.hrl").

-behaviour(supervisor2).

-export([start_link/2]).
-export([init/1]).

%%---------------------------------------------------------------------------
%% Interface
%%---------------------------------------------------------------------------

start_link(Type, AmqpParams) ->
    {ok, Sup} = supervisor2:start_link(?MODULE, []),
    {ok, ChSupSup} = supervisor2:start_child(Sup,
                         {channel_sup_sup, {amqp_channel_sup_sup, start_link,
                                            [Type]},
                          intrinsic, infinity, supervisor,
                          [amqp_channel_sup_sup]}),
    start_connection(Sup, Type, AmqpParams, ChSupSup,
                     start_infrastructure_fun(Sup, Type)),
    {ok, Sup}.
    
%%---------------------------------------------------------------------------
%% Internal plumbing
%%---------------------------------------------------------------------------

start_connection(Sup, network, AmqpParams, ChSupSup, SIF) ->
    {ok, _} = supervisor2:start_child(Sup,
                  {connection, {amqp_network_connection, start_link,
                                [AmqpParams, ChSupSup, SIF,
                                 start_heartbeat_fun(Sup)]},
                   intrinsic, ?MAX_WAIT, worker, [amqp_network_connection]});
start_connection(Sup, direct, AmqpParams, ChSupSup, SIF) ->
    {ok, _} = supervisor2:start_child(Sup,
                  {connection, {amqp_direct_connection, start_link,
                                [AmqpParams, ChSupSup, SIF]},
                   intrinsic, ?MAX_WAIT, worker, [amqp_direct_connection]}).

start_infrastructure_fun(Sup, network) ->
    fun(Sock) ->
        Connection = self(),
        {ok, CTSup} = supervisor2:start_child(Sup,
                          {connection_type_sup, {amqp_connection_type_sup,
                                                 start_link_network,
                                                 [Sock, Connection]},
                           intrinsic, infinity, supervisor,
                           [amqp_connection_type_sup]}),
        [MainReader] = supervisor2:find_child(CTSup, main_reader),
        [Framing] = supervisor2:find_child(CTSup, framing),
        [Writer] = supervisor2:find_child(CTSup, writer),
        {MainReader, Framing, Writer}
    end;
start_infrastructure_fun(Sup, direct) ->
    fun() ->
        {ok, CTSup} = supervisor2:start_child(Sup,
                          {connection_type_sup, {amqp_connection_type_sup,
                                                 start_link_direct, []},
                           intrinsic, infinity, supervisor,
                           [amqp_connection_type_sup]}),
        [Collector] = supervisor2:find_child(CTSup, collector),
        {Collector}
    end.

start_heartbeat_fun(Sup) ->
    fun(_Sock, 0) ->
        none;
       (Sock, Timeout) ->
        Connection = self(),
        {ok, Sender} = supervisor2:start_child(Sup,
                           {heartbeat_sender, {rabbit_heartbeat,
                                               start_heartbeat_sender,
                                               [Connection, Sock, Timeout]},
                            intrinsic, ?MAX_WAIT, worker, [rabbit_heartbeat]}),
        {ok, Receiver} = supervisor2:start_child(Sup,
                           {heartbeat_receiver, {rabbit_heartbeat,
                                                 start_heartbeat_receiver,
                                                 [Connection, Sock, Timeout]},
                            intrinsic, ?MAX_WAIT, worker, [rabbit_heartbeat]}),
        {Sender, Receiver}
    end.

%%---------------------------------------------------------------------------
%% supervisor2 callbacks
%%---------------------------------------------------------------------------

init([]) ->
    {ok, {{one_for_all, 0, 1}, []}}.