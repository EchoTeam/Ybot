%%%-----------------------------------------------------------------------------
%%% @author 0xAX <anotherworldofworld@gmail.com>
%%% @doc
%%% Xmpp client with ssl support.
%%% @end
%%%-----------------------------------------------------------------------------
-module(xmpp_client).

-behaviour(gen_server).

-include("xmpp.hrl").
-include_lib("xmerl/include/xmerl.hrl").

-export([start_link/9]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%% @doc Xmpp client internal state
-record (state, {
        % Xmpp client socket
        socket = null,
        % Is auth state or not
        is_auth = false,
        % client callback module or pid
        callback,
        % Xmpp client login
        login,
        % Xmpp client password
        password,
        % jabber server host
        host,
        % Jabber room
        room,
        % Client resource
        resource,
        % Xmpp server port
        port = 5222,
        % socket mode
        socket_mod = null,
        % reconnect timeout
        reconnect_timeout = 0,
        % is_authorizated
        success = false
    }).

%%%=============================================================================
%%% API
%%%=============================================================================

start_link(CallbackModule, Login, Password, Server, Port, Room, Resource, SocketMode, ReconnectTimeout) ->
    gen_server:start_link(?MODULE, [CallbackModule, Login, Password, Server, Port, Room, Resource, SocketMode, ReconnectTimeout], []).

%%%=============================================================================
%%% xmpp_client callbacks
%%%=============================================================================

init([CallbackModule, Login, Password, Server, Port, Room, Resource, SocketMode, ReconnectTimeout ]) ->
    % try to connect
    gen_server:cast(self(), {connect, Server, Port}),
    % init process internal state
    {ok, #state{callback = CallbackModule,
                login = Login,
                password = Password,
                host = Server,
                room = Room,
                resource = Resource,
                port = Port,
                socket_mod = SocketMode,
                reconnect_timeout = ReconnectTimeout
               }
    }.

handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

%% @doc connect to jabber server
handle_cast({connect, Host, Port}, State) ->
    % Connection options
    Options = case State#state.socket_mod of
                ssl -> 
                    [list, {verify, 0}];
                gen_tcp -> 
                    [list]
    end,
    % connect
    case (State#state.socket_mod):connect(binary_to_list(Host), Port, Options) of
        {ok, Socket} ->
            % Get new stream
            NewStream = lists:last(string:tokens(binary_to_list(State#state.login), "@")),
            % handshake with jabber server
            (State#state.socket_mod):send(Socket, ?STREAM(NewStream)),
            % Format login/password
            Auth = binary_to_list(base64:encode("\0" ++ binary_to_list(State#state.login) ++ "\0" ++ binary_to_list(State#state.password))),
            % Send authorization (PLAIN method)
            (State#state.socket_mod):send(Socket, xmpp_xml:auth_plain(Auth)),
            % init
            {noreply, State#state{socket = Socket}};
        {error, Reason} ->
            % Some log
            lager:error("Unable to connect to xmpp server with reason ~p", [Reason]),
            % try to reconnect
            try_reconnect(State)
    end;

%% @doc send message to jabber
handle_cast({send_message, From, Message}, State) ->
    % Check private or public message
    case From of
        % this is public message
        "" ->
            % Make room
            [Room | _] = string:tokens(binary_to_list(State#state.room), "/"),
            % send message to jabber
            (State#state.socket_mod):send(State#state.socket, xmpp_xml:message(Room, Message));
        _ ->
            % send message to jabber
            (State#state.socket_mod):send(State#state.socket, xmpp_xml:private_message(From, Message))
    end,
    
    % return
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({ssl_closed, Reason}, State) ->
    % Some log
    lager:info("ssl_closed with reason: ~p~n", [Reason]),
    % try reconnect
    try_reconnect(State);

handle_info({ssl_error, _Socket, Reason}, State) ->
    % Some log
    lager:error("tcp_error: ~p~n", [Reason]),
    % try reconnect
    try_reconnect(State);

handle_info({tcp_closed, Reason}, State) ->
    % Some log
    lager:info("tcp_closed with reason: ~p~n", [Reason]),
    % try reconnect
    try_reconnect(State);

handle_info({tcp_error, _Socket, Reason}, State) ->
    % Some log
    lager:error("tcp_error: ~p~n", [Reason]),
    % try reconnect
    try_reconnect(State);

%% handle chat message
handle_info({_, _, "<message " ++ Rest}, State) ->
    % parse xml
    try xmerl_scan:string("<message " ++ Rest) of
        [] ->
            nop;
        {Xml, _} ->
            % Try to catch incoming xmpp message and send it to hander
            ok = is_xmpp_message(Xml, State#state.callback)
    catch
        C:R ->
            lager:warning("Bad xml. It is posible that this is a first part of message")
    end,
    {noreply, State};

%% @doc Handle incoming XMPP message
handle_info({_, _Socket, Data}, State) ->
    case State#state.success of
        true ->
            {noreply, State};
        false ->
            case parse_data(Data) of
                success ->
                    % make xmpp stream string
                    Login = string:tokens(binary_to_list(State#state.login), "@"),
                    NewStream = lists:last(Login),
                    Nickname  = hd(Login),
                    % create new stream
                    (State#state.socket_mod):send(State#state.socket, ?STREAM(NewStream)),
                    % bind resource
                    (State#state.socket_mod):send(State#state.socket, xmpp_xml:bind(binary_to_list(State#state.resource))),
                    % create session
                    (State#state.socket_mod):send(State#state.socket, xmpp_xml:create_session()),
                    % send presence
                    (State#state.socket_mod):send(State#state.socket, xmpp_xml:presence()),
                    % Join to muc
                    Room = hd(string:tokens(binary_to_list(State#state.room), "/")),
                    RoomNick = erlang:iolist_to_binary([Room, "/", Nickname]),
                    (State#state.socket_mod):send(State#state.socket, xmpp_xml:muc(RoomNick)),
                    % set is_auth = true and return
                    {noreply, State#state{is_auth = true, success = true}};
                ok ->
                    {noreply, State}
            end
    end;

handle_info(_Info, State) ->
    {noreply, State}.

parse_data("<success " ++ _) ->
    success;

parse_data(_) ->
    ok.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%% @doc try reconnect
-spec try_reconnect(State :: #state{}) -> {normal, stop, State} | {noreply, State}.
try_reconnect(#state{reconnect_timeout = Timeout, host = Host, port = Port} = State) ->
    case Timeout > 0 of
        true ->
            % no need in reconnect
            {normal, stop, State};
        false ->
            % sleep
            timer:sleep(Timeout),
            % Try reconnect
            gen_server:cast(self(), {connect, Host, Port}),
            % return
            {noreply, State}
    end.

%% @doc Check incomming message type and send it to handler
-spec send_message_to_handler(Xml :: #xmlDocument{}, Callback :: pid(), IncomingMessage :: binary()) -> ok.
send_message_to_handler(Xml, Callback, IncomingMessage) ->
    % Try to get message type
    case xmerl_xpath:string("/message/@type", Xml) of
        % this is group-chat
        [{_,_,_,_, _, _, _, _,"groupchat", _}] ->
            % Send public message to callback
            Callback ! {incoming_message, "", IncomingMessage};
            % This is private message
        [{_,_,_,_, _, _, _, _,"chat", _}] ->
            % Get From parameter
            [{_,_,_,_, _, _, _, _, From, _}] = xmerl_xpath:string("/message/@from", Xml),
            % Send private message to callback
            Callback ! {incoming_message, From, IncomingMessage}
    end,
    % return
    ok.

%% @doc Check is it incoming message
-spec is_xmpp_message(Xml :: #xmlDocument{}, Callback :: pid()) -> ok.
is_xmpp_message(Xml, Callback) ->
    case xmerl_xpath:string("/message", Xml) of
        [] ->
            % this is not xmpp message. do nothing
            pass;
        _ ->
            % Get message body
            case xmerl_xpath:string("/message/body/text()", Xml) of
                [{xmlText, _, _, _, IncomingMessage, text}] ->
                    % Check message type and send it to handler
                    ok = send_message_to_handler(Xml, Callback, IncomingMessage);
                _ ->
                    error
            end
    end,
    ok.
