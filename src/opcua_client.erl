-module(opcua_client).

-behaviour(gen_statem).
% Insipired by: https://gist.github.com/ferd/c86f6b407cf220812f9d893a659da3b8


% When adding a state handler, remember to always add a timeout by calling
% enter_timeouts or event_timeouts so the state machine keep consuming data
% from the protocol. When adding a completly new state, remember to update
% enter_timeouts and event_timeouts themselves to handle the new state name.


%%% EXPORTS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% API
-export([connect/1, connect/2]).
-export([browse/2, browse/3]).
-export([read/3, read/4]).
-export([batch_read/3]).
-export([write/3, write/4]).
-export([close/1]).

%% Startup functions
-export([start_link/1]).

%% Behaviour gen_statem callback functions
-export([init/1]).
-export([callback_mode/0]).
-export([handle_event/4]).
-export([terminate/3]).


%%% INCLUDES %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-include_lib("kernel/include/logger.hrl").
-include_lib("stdlib/include/assert.hrl").

-include("opcua.hrl").
-include("opcua_internal.hrl").


%%% TYPES %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-type client_auth_spec() :: anonymous | {user_name, binary(), binary()} | {certificate, opcua_keychain:ident()}.
-type endpoint_selector() :: fun((Endpoints :: [map()]) ->
     {ok, Endpoint :: term(), TokenPolicyId :: binary(),
          AuthMethod :: client_auth_spec()}
   | {error, not_found}).

-type client_connect_options() :: #{
    % The parent keychain to use for the connection, if not defined it will use
    % the default keychain.
    keychain => opcua_keychain:state(),
    % The number of time the client will retry connecting. Default: 3
    connect_retry => non_neg_integer(),
    % The connection timeout. Default: infinty.
    connect_timeout => infinity | non_neg_integer(),
    % The keychain manager to use, if not specfied it uses the default one.
    keychain => term(),
    % If the client should lookup the server endpoints first.
    % Default: false
    endpoint_lookup => boolean(),
    % The security to use for endpoint lookup, if not specified,
    % mode and policy will be none and the identity will be the root one.
    endpoint_lookup_security => #{
        mode => opcua:security_mode(),
        policy => opcua:security_policy_type(),
        identity => undefined | opcua_keychain:ident()
    },
    % The endpoint selector function to use if endpoint lookup is enabled.
    % If not specified, the first endpoint and token type that match the then
    % required options mode and auth will be selected.
    endpoint_selector => endpoint_selector(),
    % The security mode to use if the endpoint_selector is not defined or
    % the endpoint selection is not enabled. By default it uses none.
    mode => opcua:security_mode(),
    % The security policy to use if the endpoint_selector is not defined or
    % the endpoint selection is not enabled. By default it uses none.
    policy => opcua:security_policy_type(),
    % The client identity, must be defined if the policy type is not none.
    identity => undefined | opcua_keychain:ident(),
    % The authentication method to use if the endpoint_selector is not defined
    % or the endpoint selection is not enabled. By default it uses anonymous.
    auth => client_auth_spec()
}.

-record(data, {
    opts                        :: undefined | map(),
    socket                      :: undefined | inet:socket(),
    conn                        :: undefined | opcua:connection(),
    proto                       :: undefined | term(),
    calls = #{}                 :: #{term() => gen_statem:from()}
}).


%%% API FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

connect(EndpointSpec) ->
    connect(EndpointSpec, #{}).

-spec connect(EndpointSpec :: binary(), Opts :: client_connect_options()) ->
    {ok, ClientPid :: pid()} | {error, Reason :: term()}.
connect(EndpointSpec, Opts) ->
    Endpoint  = opcua_util:parse_endpoint(EndpointSpec),
    Pid = opcua_client_pool_sup:start_client(#{}),
    try prepare_connect_options(Opts) of
        FullOpts ->
            case gen_statem:call(Pid, {connect, Endpoint, FullOpts}, infinity) of
                {error, _Reason} = Error -> Error;
                ok -> {ok, Pid}
            end
    catch throw:Reason -> {error, Reason}
    end.

browse(Pid, NodeSpec) ->
    browse(Pid, NodeSpec, #{}).

browse(Pid, NodeSpec, Opts) ->
    FixedOpts = case maps:find(type, Opts) of
        error -> Opts;
        {ok, TypeSpec} -> Opts#{type := opcua:node_id(TypeSpec)}
    end,
    Command = {browse, opcua:node_id(NodeSpec), FixedOpts},
    {ok, Result} = gen_statem:call(Pid, Command),
    Result.

read(Pid, NodeSpec, AttribSpecs) ->
    read(Pid, NodeSpec, AttribSpecs, #{}).

read(Pid, NodeSpec, AttribSpecs, Opts) when is_list(AttribSpecs) ->
    batch_read(Pid, [{NodeSpec, AttribSpecs}], Opts);
read(Pid, NodeSpec, AttribSpec, Opts) ->
    [Result] = batch_read(Pid, [{NodeSpec, [AttribSpec]}], Opts),
    Result.

batch_read(Pid, ReadSpecs, Opts) when is_list(ReadSpecs) ->
    MkList = fun(L) when is_list(L) -> L; (A) when is_atom(A) -> [A] end,
    PrepedSpecs = [{opcua:node_id(N), MkList(A)} || {N, A} <- ReadSpecs],
    Command = {read, PrepedSpecs, Opts},
    {ok, Result} = gen_statem:call(Pid, Command),
    Result.

write(Pid, NodeSpec, AttribValuePairs) ->
    write(Pid, NodeSpec, AttribValuePairs, #{}).

write(Pid, NodeSpec, AttribValuePairs, Opts) when is_list(AttribValuePairs) ->
    Command = {write, opcua:node_id(NodeSpec), AttribValuePairs, Opts},
    {ok, Result} = gen_statem:call(Pid, Command),
    Result;
write(Pid, NodeSpec, AttribValuePair, Opts) ->
    [Result] = write(Pid, NodeSpec, [AttribValuePair], Opts),
    Result.

close(Pid) ->
    gen_statem:call(Pid, close).


%%% STARTUP FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start_link(Opts) ->
    gen_statem:start_link(?MODULE, Opts, []).


%%% BEHAVIOUR gen_statem CALLBACK FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init(_Opts) ->
    ?LOG_DEBUG("OPCUA client process starting", []),
    {ok, disconnected, #data{}}.

callback_mode() -> [handle_event_function, state_enter].

%% STATE: disconnected
handle_event({call, From}, {connect, Endpoint, Opts}, disconnected = State,
             #data{conn = undefined} = Data) ->
    Data2 = Data#data{opts = Opts},
    {ProtoMode, ProtoOpts} = proto_initial_mode(Data2),
    case opcua_client_uacp:init(ProtoMode, ProtoOpts) of
        % No error use-case yet, diabling to make dialyzer happy
        % {error, Reason} ->
        %     stop_and_reply_all(normal, Data2, {error, Reason});
        {ok, Proto} ->
            Data3 = Data2#data{proto = Proto},
            next_state_and_reply_later({connecting, 0, Endpoint}, Data3,
                                       on_ready, From, event_timeouts(State, Data2))
    end;
%% STATE: {connecting, N, Endpoint}
handle_event(enter, _OldState, {connecting, N, _} = State, Data) ->
    ?LOG_DEBUG("Client ~p entered ~p", [self(), State]),
    #data{opts = #{connect_retry := MaxRetry}} = Data,
    case MaxRetry =:= infinity orelse N =< MaxRetry of
        true  ->
            {keep_state, Data, enter_timeouts(State, Data)};
        false ->
            stop_and_reply_all(normal, Data, {error, retry_exhausted})
    end;
handle_event(state_timeout, retry, {connecting, N, Endpoint} = State, Data) ->
    case conn_init(Data, Endpoint) of
        {ok, Data2} ->
            {next_state, handshaking, Data2, event_timeouts(State, Data2)};
        {error, _Reason} ->
            {next_state, {connecting, N + 1, Endpoint}, Data,
                event_timeouts(State, Data)}
    end;
%% STATE: handshaking
handle_event(enter, _OldState, handshaking = State, Data) ->
    ?LOG_DEBUG("Client ~p entered ~p", [self(), State]),
    case proto_handshake(Data) of
        % No error use-case yet, diabling to make dialyzer happy
        % {error, Reason, Data2} ->
        %     stop_and_reply_all(normal, Data2, {error, Reason});
        {ok, Data2} ->
            {keep_state, Data2, enter_timeouts(State, Data2)}
    end;
handle_event(info, {opcua_connection, {reconnect, EndpointSpec, ProtoOpts}},
             handshaking = State, Data) ->
    ?LOG_INFO("Reconnecting to endpoint ~s", [EndpointSpec #opcua_endpoint.url]),
    {next_state, {reconnecting, EndpointSpec, ProtoOpts}, Data, event_timeouts(State, Data)};
handle_event(info, {opcua_connection, ready}, handshaking = State, Data) ->
    {next_state, connected, Data, event_timeouts(State, Data)};
handle_event(info, {opcua_connection, _}, handshaking, Data) ->
    stop_and_reply_all(normal, Data, {error, opcua_handshaking_failed});
handle_event(state_timeout, abort, handshaking, Data) ->
    stop_and_reply_all(normal, Data, {error, handshake_timeout});
%% STATE: connected
handle_event(enter, _OldState, connected = State, Data) ->
    ?LOG_DEBUG("Client ~p entered connected", [self()]),
    keep_state_and_reply(Data, on_ready, ok, enter_timeouts(State, Data));
handle_event({call, From}, {browse, NodeId, Opts}, connected = State, Data) ->
    pack_command_result(From, State, proto_browse(Data, NodeId, Opts));
handle_event({call, From}, {read, ReadSpecs, Opts},
             connected = State, Data) ->
    Result = proto_read(Data, ReadSpecs, Opts),
    pack_command_result(From, State, Result);
handle_event({call, From}, {write, NodeId, AVPairs, Opts},
             connected = State, Data) ->
    pack_command_result(From, State, proto_write(Data, NodeId, AVPairs, Opts));
handle_event({call, From}, close, connected = State, Data) ->
    next_state_and_reply_later(closing, Data, on_closed, From,
                               event_timeouts(State, Data));
%% STATE: {reconnecting, EndpointSpec, ProtoOpts}
handle_event(enter, _OldState, {reconnecting, _EndpointSpec, _ProtoOpts} = State, Data) ->
    ?LOG_DEBUG("Client ~p entered reconnecting", [self()]),
    case proto_close(Data) of
        % No error use-case yet, diabling to make dialyzer happy
        % {error, Reason, Data2} ->
        %     stop_and_reply(Reason, Data2, on_closed,
        %                    {error, Reason}, {error, closed});
        {ok, Data2} ->
            {keep_state, Data2, enter_timeouts(State, Data2)}
    end;
handle_event(info, {opcua_connection, closed},
             {reconnecting, EndpointSpec, ProtoOpts} = State, Data) ->
    reconnect(Data, State, EndpointSpec, ProtoOpts);
handle_event(state_timeout, abort, {reconnecting, EndpointSpec, ProtoOpts} = State, Data) ->
    reconnect(Data, State, EndpointSpec, ProtoOpts);
handle_event(info, {tcp_closed, Sock}, {reconnecting, EndpointSpec, ProtoOpts} = State,
             #data{socket = Sock} = Data) ->
    %% When closing the server may close the socket at any time
    reconnect(Data, State, EndpointSpec, ProtoOpts);
%% STATE: closing
handle_event(enter, _OldState, closing = State, Data) ->
    ?LOG_DEBUG("Client ~p entered closing", [self()]),
    case proto_close(Data) of
        % No error use-case yet, diabling to make dialyzer happy
        % {error, Reason, Data2} ->
        %     stop_and_reply(Reason, Data2, on_closed,
        %                    {error, Reason}, {error, closed});
        {ok, Data2} ->
            {keep_state, Data2, enter_timeouts(State, Data2)}
    end;
handle_event(info, {opcua_connection, closed}, closing, Data) ->
    stop_and_reply(normal, Data, on_closed, ok, {error, closed});
handle_event(state_timeout, abort, closing, Data) ->
    stop_and_reply_all(normal, Data, {error, close_timeout});
handle_event(info, {tcp_closed, Sock}, closing, #data{socket = Sock} = Data) ->
    %% When closing the server may close the socket at any time
    stop_and_reply(normal, Data, on_closed, ok, {error, closed});
%% STATE: handshaking, connected, reconnecting and closing
handle_event(timeout, produce, State, Data) ->
    case proto_produce(Data) of
        {ok, Data2} ->
            {keep_state, Data2, event_timeouts(State, Data2)};
        {ok, Output, Data2} ->
            case conn_send(Data2, Output) of
                ok -> {keep_state, Data2, event_timeouts(State, Data2)};
                {error, Reason} -> stop(Reason, Data2)
            end;
        {error, Reason, Data2} ->
            stop(Reason, Data2)
    end;
handle_event(info, {tcp, Sock, Input}, State, #data{socket = Sock} = Data) ->
    ?DUMP("Received Data: ~p", [Input]),
    case proto_handle_data(Data, Input) of
        {ok, Responses, Data2} ->
            keep_state_reply_multi(Data2, Responses,
                                   event_timeouts(State, Data2));
        {error, Reason, Data2} ->
            stop(Reason, Data2)
    end;
handle_event(info, {tcp_passive, Sock}, State, #data{socket = Sock} = Data) ->
    case conn_activate(Data) of
        ok ->
            {keep_state, Data, event_timeouts(State, Data)};
        {error, Reason} ->
            stop_and_reply_all(Reason, Data, {error, socket_error})
    end;
handle_event(info, {tcp_closed, Sock}, _State, #data{socket = Sock} = Data) ->
    stop_and_reply_all(normal, Data, {error, socket_closed});
handle_event(info, {tcp_error, Sock}, _State, #data{socket = Sock} = Data) ->
    stop_and_reply_all(tcp_error, Data, {error, socket_error});
%% GENERIC STATE HANDLERS
handle_event(enter, _OldState, NewState, Data) ->
    ?LOG_DEBUG("Client ~p entered ~p", [self(), NewState]),
    {keep_state, Data, enter_timeouts(NewState, Data)};
handle_event(call, _, State, Data) ->
    stop_and_reply_all(unexpected_call, Data, {error, State});
handle_event(cast, _, _, Data) ->
    %TODO: Should be changed to not crash the client later on
    stop(unexpected_cast, Data);
handle_event(info, _, _, Data) ->
    %TODO: Should be changed to not crash the client later on
    stop(unexpected_message, Data).

terminate(Reason, State, Data) ->
    ?LOG_DEBUG("OPCUA client process terminated in state ~w: ~p", [State, Reason]),
    proto_terminate(Data, Reason),
    conn_close(Data).


%%% INTERNAL FUNCTIONS %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

prepare_connect_options(Opts) ->
    EndpointLookupSec = case maps:get(endpoint_lookup_security, Opts, #{}) of
        undefined -> #{};
        Value -> Value
    end,
    Merged = maps:merge(#{
        connect_retry => 3,
        connect_timeout => infinity,
        keychain => default,
        endpoint_lookup => false,
        endpoint_lookup_security =>
            maps:merge(#{
                mode => none,
                policy => none,
                auth => anonimous,
                identity => maps:get(identity, Opts, undefined)
            }, EndpointLookupSec),
        mode => none,
        policy => none,
        identity => undefined,
        auth => anonymous
    }, Opts),
    prepare_keychain(prepare_identity(prepare_selector(Merged))).

prepare_keychain(#{keychain := Keychain} = Opts) ->
    % Make sure the keychain can be shared with other processes
    Opts#{keychain := opcua_keychain:shareable(Keychain)}.

prepare_selector(#{endpoint_selector := Selector} = Opts)
  when Selector =/= undefined -> Opts;
prepare_selector(#{mode := Mode, policy := Policy, auth := AuthSpec} = Opts) ->
    DefaultSelector = fun(Endpoints) ->
        select_endpoint(Mode, Policy, AuthSpec, Endpoints)
    end,
    Opts#{endpoint_selector => DefaultSelector}.

prepare_identity(#{keychain := Keychain, identity := undefined} = Opts) ->
    case opcua_keychain:lookup(Keychain, alias, client) of
        [] -> Opts;
        [Id | _] -> Opts#{identity => Id}
    end;
prepare_identity(#{keychain := Keychain, identity := Id} = Opts) ->
    case opcua_keychain:info(Keychain, Id) of
        not_found -> throw(identity_not_found);
        #{id := Id} -> Opts
    end.

proto_initial_mode(#data{opts = #{endpoint_lookup := true} = Opts}) ->
    #{endpoint_selector := Selector, endpoint_lookup_security := SubOpts} = Opts,
    #{mode := Mode, policy := Policy, identity := Ident} = SubOpts,
    ProtoOpts = #{endpoint_selector => Selector, mode => Mode, policy => Policy, identity => Ident},
    {lookup_endpoint, ProtoOpts};
proto_initial_mode(#data{opts = #{endpoint_lookup := false} = Opts}) ->
    #{endpoint_selector := Selector, mode := Mode, policy := Policy, identity := Ident} = Opts,
    ProtoOpts = #{endpoint_selector => Selector, mode => Mode, policy => Policy, identity => Ident},
    {open_session, ProtoOpts}.

% No error use-case yet, diabling to make dialyzer happy
% pack_command_result(From, State, {error, Reason, Data}) ->
%     {keep_state, Data, [{reply, From, {error, Reason}} | enter_timeouts(State, Data)]};
pack_command_result(From, State, {async, Handle, Data}) ->
    keep_state_and_reply_later(Data, Handle, From, enter_timeouts(State, Data)).

reconnect(Data, State, EndpointSpec, ProtoOpts) ->
    Data2 = conn_close(Data),
    case opcua_client_uacp:init(open_session, ProtoOpts) of
        % No error use-case yet, diabling to make dialyzer happy
        % {error, Reason} ->
        %     stop_and_reply_all(internal_error, Data2, {error, Reason});
        {ok, Proto} ->
            Data3 = Data2#data{proto = Proto},
            {next_state, {connecting, 0, EndpointSpec}, Data3,
             event_timeouts(State, Data3)}
    end.

select_endpoint(Mode, Policy, AuthSpec, Endpoints) ->
    %TODO: Validate the servers certificate ?
    PolicyUri = opcua_util:policy_uri(Policy),
    AuthType = auth_type(AuthSpec),
    FilteredEndpoints =
        [E || E = #{security_mode := M, security_policy_uri := P} <- Endpoints,
              M =:= Mode, P =:= PolicyUri],
    case FilteredEndpoints of
        [] -> {error, not_found};
        [#{user_identity_tokens := Tokens} = Endpoint | _] ->
            %TODO: Should scan all the endpoint for compatible token type
            %      instead of only checking the first one
            FilteredTokens = [I || I = #{token_type := T} <- Tokens, T =:= AuthType],
            case FilteredTokens of
                [] -> {error, not_found};
                [#{policy_id := PolicyId} | _] ->
                    {ok, Endpoint, PolicyId, AuthSpec}
            end
    end.

auth_type(anonymous) -> anonymous;
auth_type({user_name, _, _}) -> user_name.


%== Protocol Module Abstraction Functions ======================================

proto_produce(#data{conn = Conn, proto = Proto} = Data) ->
    case opcua_client_uacp:produce(Conn, Proto) of
        {ok, Conn2, Proto2} ->
            {ok, Data#data{conn = Conn2, proto = Proto2}};
        {ok, Output, Conn2, Proto2} ->
            {ok, Output, Data#data{conn = Conn2, proto = Proto2}};
        {error, Reason, Proto2} ->
            {error, Reason, Data#data{proto = Proto2}}
    end.

proto_handle_data(#data{conn = Conn, proto = Proto} = Data, Input) ->
    case opcua_client_uacp:handle_data(Input, Conn, Proto) of
        {ok, Responses, Conn2, Proto2} ->
            {ok, Responses, Data#data{conn = Conn2, proto = Proto2}};
        {error, Reason, Proto2} ->
            {error, Reason, Data#data{proto = Proto2}}
    end.

proto_handshake(#data{conn = Conn, proto = Proto} = Data) ->
    case opcua_client_uacp:handshake(Conn, Proto) of
        % No error use-case yet, diabling to make dialyzer happy
        % {error, Reason, Proto2} ->
        %     {error, Reason, Data#data{proto = Proto2}};
        {ok, Conn2, Proto2} ->
            {ok, Data#data{conn = Conn2, proto = Proto2}}
    end.

proto_browse(#data{conn = Conn, proto = Proto} = Data, NodeId, Opts) ->
    case opcua_client_uacp:browse(NodeId, Opts, Conn, Proto) of
        % No error use-case yet, diabling to make dialyzer happy
        % {error, Reason, Proto2} ->
        %     {error, Reason, Data#data{proto = Proto2}};
        {async, Handle, Conn2, Proto2} ->
            {async, Handle, Data#data{conn = Conn2, proto = Proto2}}
    end.

proto_read(#data{conn = Conn, proto = Proto} = Data, ReadSpecs, Opts) ->
    case opcua_client_uacp:read(ReadSpecs, Opts, Conn, Proto) of
        % No error use-case yet, diabling to make dialyzer happy
        % {error, Reason, Proto2} ->
        %     {error, Reason, Data#data{proto = Proto2}};
        {async, Handle, Conn2, Proto2} ->
            {async, Handle, Data#data{conn = Conn2, proto = Proto2}}
    end.

proto_write(#data{conn = Conn, proto = Proto} = Data, NodeId, AVPairs, Opts) ->
    case opcua_client_uacp:write(NodeId, AVPairs, Opts, Conn, Proto) of
        % No error use-case yet, diabling to make dialyzer happy
        % {error, Reason, Proto2} ->
        %     {error, Reason, Data#data{proto = Proto2}};
        {async, Handle, Conn2, Proto2} ->
            {async, Handle, Data#data{conn = Conn2, proto = Proto2}}
    end.

proto_close(#data{conn = Conn, proto = Proto} = Data) ->
    case opcua_client_uacp:close(Conn, Proto) of
        % No error use-case yet, diabling to make dialyzer happy
        % {error, Reason, Proto2} ->
        %     {error, Reason, Data#data{proto = Proto2}};
        {ok, Conn2, Proto2} ->
            {ok, Data#data{conn = Conn2, proto = Proto2}}
    end.

proto_terminate(#data{conn = Conn, proto = Proto}, Reason) ->
    opcua_client_uacp:terminate(Reason, Conn, Proto).


%== Connection Managment =======================================================

conn_init(#data{opts = CliOpts, socket = undefined} = Data, Endpoint)
  when Endpoint =/= undefined ->
    #{keychain := ParentKeychain,
      identity := Identity,
      connect_timeout := Timeout} = CliOpts,
    #opcua_endpoint{host = Host, port = Port, url = Url} = Endpoint,
    ?LOG_DEBUG("Connecting to ~s", [Url]),
    Opts = [binary, {active, false}, {packet, raw}],
    case gen_tcp:connect(Host, Port, Opts, Timeout) of
        {error, _Reason} = Error -> Error;
        {ok, Socket} ->
            PeerNameRes = inet:peername(Socket),
            SockNameRes = inet:sockname(Socket),
            case {PeerNameRes, SockNameRes} of
                {{error, _Reason} = Error, _} -> Error;
                {_, {error, _Reason} = Error} -> Error;
                {{ok, PeerName}, {ok, SockName}} ->
                    {ok, Keychain} = opcua_keychain_ets:new(ParentKeychain),
                    Conn = opcua_connection:new(Keychain, Identity, Endpoint,
                                                PeerName, SockName),
                    Data2 = Data#data{socket = Socket, conn = Conn},
                    case conn_activate(Data2) of
                        {error, _Reason} = Error -> Error;
                        ok -> {ok, Data2}
                    end
            end
    end.

conn_activate(#data{socket = Socket}) ->
    inet:setopts(Socket, [{active, 5}]).

conn_send(#data{socket = Socket}, Packet) ->
    ?DUMP("Sending Data: ~p", [Packet]),
    gen_tcp:send(Socket, Packet).

conn_close(#data{socket = undefined}) -> ok;
conn_close(#data{socket = Socket} = Data) ->
    ?LOG_DEBUG("Closing connection"),
    gen_tcp:close(Socket),
    Data#data{socket = undefined}.


%== Reply Managment ============================================================

next_state_and_reply_later(NextState, #data{calls = Calls} = Data, Key, From, Actions) ->
    ?assertNot(maps:is_key(Key, Calls)),
    {next_state, NextState, Data#data{calls = maps:put(Key, From, Calls)}, Actions}.

keep_state_and_reply_later(#data{calls = Calls} = Data, Key, From, Actions) ->
    ?assertNot(maps:is_key(Key, Calls)),
    {keep_state, Data#data{calls = maps:put(Key, From, Calls)}, Actions}.

keep_state_and_reply(#data{calls = Calls} = Data, Key, Response, Actions) ->
    case maps:take(Key, Calls) of
        error -> {keep_state, Data, Actions};
        {From, Calls2} ->
            {keep_state, Data#data{calls = Calls2},
             [{reply, From, Response} | Actions]}
    end.

keep_state_reply_multi(#data{calls = Calls} = Data, Responses, Actions) ->
    {Actions2, Calls2} = lists:foldl(fun({Tag, Resp}, {Acc, Map}) ->
        case maps:take(Tag, Map) of
            error -> {Acc, Map};
            {From, Map2} -> {[{reply, From, Resp} | Acc], Map2}
        end
    end, {Actions, Calls}, Responses),
    {keep_state, Data#data{calls = Calls2}, Actions2}.

stop_and_reply(Reason, #data{calls = Calls} = Data, Tag, MainResp, OtherResp) ->
    %TODO: should probably cancel any pending request if possible
    Actions = [{reply, F, OtherResp} || {T, F} <- maps:to_list(Calls), T =/= Tag],
    Actions2 = case maps:find(Tag, Calls) of
        error -> Actions;
        {ok, From} -> [{reply, From, MainResp} | Actions]
    end,
    {stop_and_reply, Reason, Actions2, Data#data{calls = #{}}}.

stop_and_reply_all(Reason, #data{calls = Calls} = Data, Response) ->
    %TODO: should probably cancel any pending request if possible
    Replies = [{reply, F, Response} || F <- maps:values(Calls)],
    {stop_and_reply, Reason, Replies, Data#data{calls = #{}}}.

stop(Reason, Data) ->
    stop_and_reply_all(Reason, Data, {error, Reason}).


%== Timeouts ===================================================================

enter_timeouts({connecting, 0, _} = State, Data) ->
    [{state_timeout, 0, retry} | event_timeouts(State, Data)];
enter_timeouts({connecting, 1, _} = State, Data) ->
    [{state_timeout, 500, retry} | event_timeouts(State, Data)];
enter_timeouts({connecting, 2, _} = State, Data) ->
    [{state_timeout, 1000, retry} | event_timeouts(State, Data)];
enter_timeouts({connecting, 3, _} = State, Data) ->
    [{state_timeout, 3000, retry} | event_timeouts(State, Data)];
enter_timeouts({connecting, _, _} = State, Data) ->
    [{state_timeout, 10000, retry} | event_timeouts(State, Data)];
enter_timeouts(handshaking = State, Data) ->
    [{state_timeout, 3000, abort} | event_timeouts(State, Data)];
enter_timeouts({reconnecting, _, _} = State, Data) ->
    [{state_timeout, 3000, abort} | event_timeouts(State, Data)];
enter_timeouts(closing = State, Data) ->
    [{state_timeout, 4000, abort} | event_timeouts(State, Data)];
enter_timeouts(State, Data) ->
    event_timeouts(State, Data).

event_timeouts({reconnecting, _, _}, Data) ->
    event_timeouts(reconnecting, Data);
event_timeouts(State, Data)
  when State =:= handshaking; State =:= connected;
       State =:= reconnecting; State =:= closing ->
    #data{conn = Conn, proto = Proto} = Data,
    case opcua_client_uacp:can_produce(Conn, Proto) of
        true -> [{timeout, 0, produce}];
        false -> []
    end;
event_timeouts(_State, _Data) ->
    [].
