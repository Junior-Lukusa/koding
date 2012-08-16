%% MIT License
%% ===========

%% Copyright (c) 2012 Son Tran <esente@gmail.com>

%% Permission is hereby granted, free of charge, to any person obtaining a
%% copy of this software and associated documentation files (the "Software"),
%% to deal in the Software without restriction, including without limitation
%% the rights to use, copy, modify, merge, publish, distribute, sublicense,
%% and/or sell copies of the Software, and to permit persons to whom the
%% Software is furnished to do so, subject to the following conditions:

%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.

%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
%% THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
%% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
%% DEALINGS IN THE SOFTWARE.
-module(broker_app).

-behaviour(application).

-behaviour(cowboy_http_handler). %% To handle the default route

%% Application callbacks
-export([start/0, start/2, stop/1, subscribe/4]).

%% Cowboy callbacks
-export([init/3, handle/2, terminate/2]).
-record (subscription, {   broker, 
                        channel, 
                        exchange,
                        private,
                        consumer,
                        routing_keys = orddict:new()}).
-include_lib("amqp_client/include/amqp_client.hrl").
-define (RABBITMQ, "localhost").
%-define (RABBITMQ, "web0.beta.system.aws.koding.com").

%% ===================================================================
%% Application callbacks
%% ===================================================================

start() ->
    application:start(crypto),
    application:start(public_key),
    application:start(ssl),
    application:start(sockjs),
    application:start(cowboy),

    application:start(broker).

start(_StartType, _StartArgs) ->
    NumberOfAcceptors = 100,
    Port = 8008,

    {ok, Broker} =
        amqp_connection:start(#amqp_params_network{host = ?RABBITMQ}),

    MultiplexState = sockjs_mq:init_state(Broker, fun connect/1, fun handle_subscription/3),

    %% sockjs_handler:init_state(Prefix, Callback, State, Options)
    %% Callback is a sockjs_service behavior module.
    SockjsState = sockjs_handler:init_state(
                    <<"/subscribe">>, sockjs_mq, MultiplexState, []),

    VhostRoutes = [
        {
            [<<"subscribe">>, '...'], 
            sockjs_cowboy_handler, 
            SockjsState
        },
        {
            [<<"static">>, '...'], 
            cowboy_http_static,
            [
                {directory, {priv_dir, broker, [<<"www">>]}},
                {mimetypes, {fun mimetypes:path_to_mimes/2, default}}
            ]
        },
        {'_', ?MODULE, []} % The rest is handled within this module.
    ],
    Routes = [{'_',  VhostRoutes}], % any vhost

    io:format(" [*] Running at http://localhost:~p~n", [Port]),

    cowboy:start_listener(http, 
        NumberOfAcceptors,
        cowboy_tcp_transport, [{port, Port}],
        cowboy_http_protocol, [{dispatch, Routes}]
    ),

    broker_sup:start_link().

stop(_State) ->
    ok.

%% ===================================================================
%% Cowboy callbacks
%% ===================================================================

init({_Any, http}, Req, []) ->
    {ok, Req, []}.

handle(Req, State) ->
    {Path, Req1} = cowboy_http_req:path(Req),
    {ok, Req2} = case Path of
        [<<"broker.js">>] ->
            {ok, Data} = file:read_file("./apps/broker/priv/www/js/broker.js"),
            cowboy_http_req:reply(200, [{<<"Content-Type">>, "application/javascript"}],
                               Data, Req1);

        [<<"auth">>] ->
            {Channel, Req3} = cowboy_http_req:qs_val(<<"channel">>, Req1),
            %PrivateChannel = uuid:to_string(uuid:uuid4()),
            PrivateChannel = <<Channel/binary, ".private">>,
            cowboy_http_req:reply(200,
                [{<<"Content-Encoding">>, <<"utf-8">>}], PrivateChannel, Req3);

        [] ->
            {ok, Data} = file:read_file("./apps/broker/priv/www/index.html"),
            cowboy_http_req:reply(200, [{<<"Content-Type">>, "text/html"}],
                               Data, Req1);
        _ ->
            cowboy_http_req:reply(404, [],
                               <<"404 - Nothing here\n">>, Req1)
        end,
    {ok, Req2, State}.

terminate(_Req, _State) ->
    ok.

%% ===================================================================
%% SockJS_MQ Handlers
%% ===================================================================

connect(Broker) ->
    {ok, Channel} = amqp_connection:open_channel(Broker),
    Channel.

%%--------------------------------------------------------------------
%% Function: handle_subscription(Conn, {init, From}, _State) -> 
%%              {ok, NewState}
%% Description: Set up RabbitMQ connection and channel, then spawn the 
%% receiving loop. This process also declares the Exchange.
%%--------------------------------------------------------------------
handle_subscription(Conn, {init, From, Channel}, _State) ->
    {topic, Exchange} = lists:last(Conn:info()),

    %RegExp = "^priv[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}",
    RegExp = ".private$",
    %Options = [{capture, [1], list}],

    case re:run(Exchange, RegExp) of
        {match, _}  -> Private = true;
        nomatch     -> Private = false
    end,

    Pid = spawn(?MODULE, subscribe, [Conn, Channel, Exchange, From]),

    Conn:send(<<"broker:subscription_succeeded">>, <<>>),
    
    {ok, #subscription{ channel     = Channel, 
                        exchange    = Exchange,
                        private     = Private,
                        consumer    = Pid}};

%%--------------------------------------------------------------------
%% Function: handle_subscription(Conn, {bind, Event, _From}, State) -> 
%%              {ok, NewState}
%% Description: When the client binds on certain event, this function
%% declare a queue and bind to an routing key with the same name as
%% the event name. This allows client to only receive messages from
%% that event.
%%--------------------------------------------------------------------
handle_subscription(_Conn, {bind, Event, _From},
                State = #subscription{  channel = Channel,
                                        exchange = Exchange,
                                        consumer = Consumer,
                                        routing_keys = Keys}) ->
    Queue = bind_queue(Channel, Exchange, Event, Consumer),
    NewKeys = orddict:store(Event, Queue, Keys),
    {ok, State#subscription{routing_keys = NewKeys}};

%%--------------------------------------------------------------------
%% Function: handle_subscription(Conn, {unbind, Event, _From}, State)
%%              -> {ok, NewState}.
%% Description: When the client unbinds certain event, this function
%% unbinds the associated queue.
%%--------------------------------------------------------------------
handle_subscription(_Conn, {unbind, Event, _From}, 
                    State = #subscription{  channel = Channel,
                                            exchange = Exchange,
                                            routing_keys = Keys}) ->
    
    case orddict:find(Event, Keys) of 
        {ok, Queue} ->
            unbind_queue(Channel, Exchange, Event, Queue),
            % Remove from the dictionary
            NewKeys = orddict:erase(Event, Keys),
            {ok, State#subscription{routing_keys = NewKeys}};
        error ->
            {ok, State}
    end;

%%--------------------------------------------------------------------
%% Function: handle_subscription(Conn, {trigger, Event, Payload, From}
%%              , State) -> {ok, NewState}.
%% Description: Allows client to trigger certain event in an exchange.
%% The payload of the event will be broadcasted to the exchange under
%% the routing key the same as the event name.
%%--------------------------------------------------------------------
handle_subscription(_Conn, {trigger, Event, Payload, From},
                    State = #subscription{channel = Channel,
                                            exchange = Exchange,
                                            private = Private}) ->
    case Private of 
        true -> 
            broadcast(From, Channel, Exchange, Event, Payload),
            {ok, State};
        false -> {ok, State}
    end;

%%--------------------------------------------------------------------
%% Function: handle_subscription(_Conn, closed, State) -> {ok, State}.
%% Description: When the client unsubscribes from the exchange, delete
%% the exchange, close the channel and the connection.
%%--------------------------------------------------------------------
handle_subscription(_Conn, closed, #subscription{channel = Channel}) ->
    {ok, #subscription{}};

handle_subscription(_Conn, ended, #subscription{channel = Channel}) ->
    % TODO: Check if exchane has no bound queue (passive), then delete
    % Delete = #'exchange.delete'{exchange = Exchange},
    % #'exchange.delete_ok'{} = amqp_channel:call(Channel, Delete)
    amqp_channel:close(Channel),
    %amqp_connection:close(Broker),
    {ok, #subscription{}}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: broadcast(From, Channel, Exchange, Event, Data) -> void()
%% Description: Set up the correlation id, then publish the Data to 
%% the Exchange on the routing key the same as the Event.
%%--------------------------------------------------------------------
broadcast(From, Channel, Exchange, Event, Data) ->
    Props = #'P_basic'{correlation_id = From},
    Publish = #'basic.publish'{ exchange = Exchange, 
                                routing_key = Event},
    Msg = #amqp_msg{props = Props, payload = Data},
    amqp_channel:cast(Channel, Publish, Msg).

%%--------------------------------------------------------------------
%% Function: subscribe(Conn, Channel, Queue, Subscriber) -> void()
%% Description: Declares the exchange and starts the receive loop
%% process. This process is used to subscribe to queue later on.
%% The exchange is marked durable so that it can survive server reset.
%% This broker has to have a way to delete the exchange when done.
%%--------------------------------------------------------------------
subscribe(Conn, Channel, Exchange, Subscriber) -> 
    Declare = #'exchange.declare'{  exchange = Exchange, 
                                    type = <<"topic">>,
                                    durable = true,
                                    auto_delete = true},
    #'exchange.declare_ok'{} = amqp_channel:call(Channel, Declare), 

    loop(Conn, Subscriber).

%%--------------------------------------------------------------------
%% Function: bind_queue(Channel, Exchange, Routing, Consumer) -> pid()
%% Description: Declares a queue and bind to the routing key. Also
%% starts the subscription on that queue.
%%--------------------------------------------------------------------
bind_queue(Channel, Exchange, Routing, Consumer) ->
    #'queue.declare_ok'{queue = Queue} =
        amqp_channel:call(Channel, #'queue.declare'{exclusive = true,
                                                    durable = true}),

    Binding = #'queue.bind'{exchange = Exchange,
                            routing_key = Routing,
                            queue = Queue},
    #'queue.bind_ok'{} = amqp_channel:call(Channel, Binding),
    Sub = #'basic.consume'{queue = Queue, no_ack = true},
    amqp_channel:subscribe(Channel, Sub, Consumer),
    Queue.

%%--------------------------------------------------------------------
%% Function: unbind_queue(Channel, Exchange, Routing, Queue) -> pid()
%% Description: Unbinds the queue from the routing key in the exchange
%% and deletes it.
%%--------------------------------------------------------------------
unbind_queue(Channel, Exchange, Routing, Queue) ->
    % Unbind the queue from the routing key
    Binding = #'queue.unbind'{  exchange    = Exchange,
                                routing_key = Routing,
                                queue       = Queue},
    #'queue.unbind_ok'{} = amqp_channel:call(Channel, Binding),
    % Delete the queue
    Delete = #'queue.delete'{queue = Queue},
    #'queue.delete_ok'{} = amqp_channel:call(Channel, Delete).

rpc_call(Broker, RoutingKey, Payload) ->
    %Fun = fun(X) -> X + 1 end,
    %RPCHandler = fun(X) -> term_to_binary(Fun(binary_to_term(X))) end,
    %Server = amqp_rpc_server:start(Broker, <<"RoutingKey">>, RPCHandler),
    RpcClient = amqp_rpc_client:start(Broker, RoutingKey),
    io:format("RpcClient ~p~n", [RpcClient]),
    _Reply = amqp_rpc_client:call(RpcClient, list_to_binary(Payload)).
    %Reply = amqp_rpc_client:call(RpcClient, term_to_binary(1)),
    %io:format("Reply ~p~n", [binary_to_term(Reply)]).

%%--------------------------------------------------------------------
%% Function: loop(Conn) -> void()
%% Description: The receive loop to send broadcast message to client.
%%--------------------------------------------------------------------
loop(Conn, Subscriber) ->
    receive
        #'basic.consume_ok'{} ->
            loop(Conn, Subscriber);
        % Own message is ignored
        {#'basic.deliver'{}, 
        #amqp_msg{props = #'P_basic'{correlation_id = Subscriber}}} ->
            loop(Conn, Subscriber);
        % Only send message from the bound event
        {#'basic.deliver'{routing_key = Event, exchange = Exchange}, 
            #amqp_msg{payload = Body}} ->
            io:format(" [x] ~p:~p:~p~n", [Exchange, Event, Body]),
            Conn:send(Event, Body),
            loop(Conn, Subscriber)
    end.