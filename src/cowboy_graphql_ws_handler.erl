%%% @author Sergey <me@seriyps.ru>
%%% @copyright (C) 2022, Sergey
%%% @doc
%%% Cowboy websocket handler for graphql API
%%% Supported protocols:
%%% <ul>
%%%  <li>`graphql_ws' - [[https://github.com/enisdenjo/graphql-ws/blob/master/PROTOCOL.md]]</li>
%%%  <li>`apollo' - [[https://github.com/apollographql/subscriptions-transport-ws/blob/master/PROTOCOL.md]]</li>
%%% </ul>
%%% @end
%%% Created : 3 Feb 2022 by Sergey <me@seriyps.ru>

-module(cowboy_graphql_ws_handler).

-export([config/3]).
-export([
    init/2,
    %% websocket_init/1,
    websocket_handle/2,
    websocket_info/2,
    terminate/3
]).
-export_type([
    protocol/0,
    config/0,
    features/0
]).

-include_lib("kernel/include/logger.hrl").
-define(APP, cowboy_graphql).
-define(LOG_DOMAIN, [?APP, ws_handler]).

-record(state, {
    cb :: module(),
    cb_state :: any(),
    protocol :: protocol(),
    stage = connected :: connected | handshake | active | terminated,
    json_encode :: fun((any()) -> iodata()),
    json_decode :: fun((binary()) -> any())
}).

-define(SUPPORTED_PROTOCOLS, #{
    graphql_ws => <<"graphql-transport-ws">>,
    % deprecated
    apollo => <<"graphql-ws">>
}).

-type protocol() :: apollo | graphql_ws.
-type options() :: #{
    json_mod => module(),
    max_frame_size => pos_integer(),
    protocols => [protocol()]
}.
-opaque config() :: {module(), any(), options()}.

-type features() :: #{subprotocol => protocol()}.
%% TODO: active keepalive

%% @doc Creates a structure to be passed as `InitialState' to Cowboy's router.
%% See [[https://ninenines.eu/docs/en/cowboy/2.9/manual/cowboy_router/]]
-spec config(module(), any(), options()) -> config().
config(Callback, CallbackOptions, TransportOptions) ->
    {Callback, CallbackOptions, TransportOptions}.

%%
%% Cowboy callbacks
%%

init(Req0, {Callback, CallbackOpts, Params0}) ->
    Defaults = #{
        json_mod => jsx,
        idle_timeout => 10 * 60 * 1000,
        max_frame_size => 5 * 1024 * 1024,
        protocols => [graphql_ws, apollo]
    },
    Params = maps:merge(Defaults, Params0),
    case cowboy_graphql:call_connection(Callback, Req0, CallbackOpts) of
        {ok, CbState} ->
            #{
                json_mod := JsonMod,
                max_frame_size := MaxFrameSize,
                protocols := AllowedProtocols,
                idle_timeout := IdleTimeout
            } = Params,
            {ProtoTag, Req} = choose_protocol(Req0, AllowedProtocols),
            {cowboy_websocket, Req,
                #state{
                    cb = Callback,
                    cb_state = CbState,
                    protocol = ProtoTag,
                    json_encode = fun JsonMod:encode/1,
                    json_decode = fun JsonMod:decode/1
                },
                #{
                    idle_timeout => IdleTimeout,
                    max_frame_size => MaxFrameSize
                }};
        {error, Reason} ->
            ?LOG_INFO(
                #{
                    label => callback_error,
                    function => connection,
                    module => Callback,
                    req => Req0,
                    reason => Reason
                },
                #{domain => ?LOG_DOMAIN}
            ),
            {Code, ResBody} = cowboy_graphql_http_handler:format_error(
                [auth_error, protocol_error, other_error], Reason
            ),
            JsonMod = maps:get(json_mod, Params),
            {ok,
                cowboy_req:reply(
                    Code,
                    #{<<"content-type">> => <<"application/json">>},
                    JsonMod:encode(ResBody),
                    Req0
                ),
                []}
    end.

-spec choose_protocol(cowboy_req:req(), [protocol()]) -> {protocol(), cowboy_req:req()}.
choose_protocol(Req0, [_ | _] = EnabledProtocols) ->
    %% https://www.rfc-editor.org/rfc/rfc6455#section-4.2.2
    Subprotocols = ordsets:from_list(
        cowboy_req:parse_header(<<"sec-websocket-protocol">>, Req0, [])
    ),
    case
        lists:dropwhile(
            fun(Tag) ->
                HeaderVal = maps:get(Tag, ?SUPPORTED_PROTOCOLS),
                not ordsets:is_element(HeaderVal, Subprotocols)
            end,
            EnabledProtocols
        )
    of
        [] ->
            {hd(EnabledProtocols), Req0};
        [Tag | _] ->
            HeaderVal = maps:get(Tag, ?SUPPORTED_PROTOCOLS),
            %% Req = cowboy_req:set_resp_header(<<"Sec-WebSocket-Protocol">>, HeaderVal, Req0),
            Req = cowboy_req:set_resp_header(<<"sec-websocket-protocol">>, HeaderVal, Req0),
            {Tag, Req}
    end.

%% websocket_init(#state{cb = Callback, cb_state = CbState} = St) ->
%%     {ok, State}.

websocket_handle({text, Text}, #state{protocol = Proto} = State) ->
    try json_decode(Text, State) of
        #{<<"type">> := _} = Msg ->
            handle_message(Msg, State);
        Decoded ->
            ?LOG_WARNING(
                #{
                    label => malformed_packet,
                    decoded => Decoded
                },
                #{domain => ?LOG_DOMAIN}
            ),
            Err = cowboy_graphql:protocol_error(
                ws, malformed_packet, "Missing 'type' field", #{packet => Decoded}
            ),
            {encode_packets([to_error(Proto, Err)], State), State}
    catch
        T:R:S ->
            ?LOG_WARNING(
                #{label => json_decoding_error, t => T, r => R, s => S},
                #{domain => ?LOG_DOMAIN}
            ),
            Err = cowboy_graphql:protocol_error(
                ws, malformed_packet, "Invalid JSON", #{json => Text}
            ),
            {encode_packets([to_error(Proto, Err)], State), State}
    end;
websocket_handle(_Frame, State) ->
    {ok, State}.

websocket_info(Any, #state{cb = Callback, cb_state = CallbackState0, protocol = Proto} = State) ->
    case cowboy_graphql:call_handle_info(Callback, Any, CallbackState0) of
        {noreply, CallbackState} ->
            {[], State#state{cb_state = CallbackState}};
        {reply, Results, CallbackState} ->
            JsResults =
                case Proto of
                    graphql_ws ->
                        graphql_ws_to_results(Results);
                    apollo ->
                        apollo_to_results(Results)
                end,
            {encode_packets(JsResults, State), State#state{cb_state = CallbackState}};
        {error, Err, CallbackState} ->
            ?LOG_INFO(
                #{
                    label => callback_error,
                    function => handle_info,
                    module => Callback,
                    reason => Err
                },
                #{domain => ?LOG_DOMAIN}
            ),
            {encode_packets([to_error(Proto, Err)], State), State#state{cb_state = CallbackState}}
    end.

terminate(Reason, _PartialReq, #state{cb = Callback, cb_state = CallbackState}) ->
    %% TODO: maybe report any errors and report them to `terminate' same way as in HTTP handler?
    ok = cowboy_graphql:call_terminate(Callback, Reason, CallbackState);
terminate(Reason, PartialReq, State) ->
    ?LOG_WARNING(
        #{
            label => early_termination,
            reason => Reason,
            partial_req => PartialReq,
            state => State
        },
        #{domain => ?LOG_DOMAIN}
    ),
    ok.

%%
%% Internal
%%

handle_message(Msg, State) ->
    try handle_message(Msg, State#state.stage, State#state.protocol, State) of
        {Packets, NewState} ->
            {encode_packets(Packets, NewState), NewState}
    catch
        T:R:S ->
            Id = erlang:unique_integer(),
            ?LOG_NOTICE(
                #{
                    tag => handle_message_error,
                    id => Id,
                    type => T,
                    reason => R,
                    stack => S
                },
                #{domain => ?LOG_DOMAIN}
            ),
            {[{close, 4500, integer_to_binary(Id)}], State}
    end.

encode_packets(Packets, St) ->
    [
        case Packet of
            {json, JS} ->
                {text, json_encode(JS, St)};
            Other ->
                Other
        end
     || Packet <- Packets
    ].

%% graphql-ws
%% https://github.com/enisdenjo/graphql-ws/blob/master/PROTOCOL.md
handle_message(
    #{<<"type">> := <<"connection_init">>} = Msg,
    connected,
    Proto,
    #state{cb = Callback, cb_state = CallbackState0} = State
) when
    Proto =:= graphql_ws;
    Proto =:= apollo
->
    Params = maps:get(<<"payload">>, Msg, #{}),
    TransportInfo = {ws, #{subprotocol => Proto}},
    {ok, Extra, CallbackState} = cowboy_graphql:call_init(
        Callback, Params, TransportInfo, CallbackState0
    ),
    KeepAlive =
        case Proto == apollo of
            true ->
                [{json, #{<<"type">> => <<"ka">>}}];
            false ->
                []
        end,
    {
        [
            {json,
                cowboy_graphql:put_not_empty(
                    <<"payload">>, Extra, #{<<"type">> => <<"connection_ack">>}
                )}
            | KeepAlive
        ],
        State#state{
            stage = active, cb_state = CallbackState
        }
    };
handle_message(#{<<"type">> := <<"ping">>}, active, graphql_ws, State) ->
    {[{json, #{<<"type">> => <<"pong">>}}], State};
handle_message(
    #{
        <<"type">> := <<"subscribe">>,
        <<"id">> := Id,
        <<"payload">> := #{<<"query">> := Query} = Payload
    },
    active,
    graphql_ws,
    #state{cb = Callback, cb_state = CallbackState0} = State
) ->
    OperationName = maps:get(<<"operationName">>, Payload, undefined),
    Variables = maps:get(<<"variables">>, Payload, #{}),
    Extensions = maps:get(<<"extensions">>, Payload, #{}),
    case
        cowboy_graphql:call_handle_request(
            Callback, Id, OperationName, Query, Variables, Extensions, CallbackState0
        )
    of
        {noreply, CallbackState} ->
            {[], State#state{cb_state = CallbackState}};
        {reply, Results, CallbackState} ->
            {graphql_ws_to_results(Results), State#state{cb_state = CallbackState}};
        {error, Err, CallbackState} ->
            ?LOG_INFO(
                #{
                    label => callback_error,
                    function => handle_request,
                    module => Callback,
                    reason => Err
                },
                #{domain => ?LOG_DOMAIN}
            ),
            {[to_error(graphql_ws, Err)], State#state{cb_state = CallbackState}}
    end;
handle_message(
    #{<<"type">> := <<"complete">>, <<"id">> := Id},
    active,
    graphql_ws,
    #state{cb = Callback, cb_state = CallbackState0} = State
) ->
    case cowboy_graphql:call_handle_cancel(Callback, Id, CallbackState0) of
        {noreply, CallbackState} ->
            {[], State#state{cb_state = CallbackState}};
        {error, Err, CallbackState} ->
            ?LOG_INFO(
                #{
                    label => callback_error,
                    function => handle_cancel,
                    module => Callback,
                    reason => Err
                },
                #{domain => ?LOG_DOMAIN}
            ),
            {[to_error(graphql_ws, Err)], State#state{cb_state = CallbackState}}
    end;
%% legacy Apollo "subscriptions-transport-ws"
%% https://github.com/apollographql/subscriptions-transport-ws/blob/master/PROTOCOL.md
handle_message(
    #{
        <<"type">> := <<"start">>,
        <<"id">> := Id,
        <<"payload">> := #{<<"query">> := Query} = Payload
    },
    active,
    apollo,
    #state{cb = Callback, cb_state = CallbackState0} = State
) ->
    OperationName = maps:get(<<"operationName">>, Payload, undefined),
    Variables = maps:get(<<"variables">>, Payload, #{}),
    case
        cowboy_graphql:call_handle_request(
            Callback, Id, OperationName, Query, Variables, #{}, CallbackState0
        )
    of
        {noreply, CallbackState} ->
            {[], State#state{cb_state = CallbackState}};
        {reply, Results, CallbackState} ->
            {apollo_to_results(Results), State#state{cb_state = CallbackState}};
        {error, Err, CallbackState} ->
            ?LOG_INFO(
                #{
                    label => callback_error,
                    function => handle_request,
                    module => Callback,
                    reason => Err
                },
                #{domain => ?LOG_DOMAIN}
            ),
            {[to_error(apollo, Err)], State#state{cb_state = CallbackState}}
    end;
handle_message(
    #{<<"type">> := <<"stop">>, <<"id">> := Id},
    active,
    apollo,
    #state{cb = Callback, cb_state = CallbackState0} = State
) ->
    case cowboy_graphql:call_handle_cancel(Callback, Id, CallbackState0) of
        {noreply, CallbackState} ->
            {[], State#state{cb_state = CallbackState}};
        {error, Err, CallbackState} ->
            ?LOG_INFO(
                #{
                    label => callback_error,
                    function => handle_cancel,
                    module => Callback,
                    reason => Err
                },
                #{domain => ?LOG_DOMAIN}
            ),
            {[to_error(apollo, Err)], State#state{cb_state = CallbackState}}
    end;
handle_message(
    #{<<"type">> := <<"connection_terminate">>},
    active,
    apollo,
    #state{} = State
) ->
    %% Should we close?
    {[], State#state{stage = terminated}};
handle_message(Unexpected, _, Proto, State) ->
    ?LOG_NOTICE(
        #{
            label => unexpected_message,
            message => Unexpected,
            proto => Proto
        },
        #{domain => ?LOG_DOMAIN}
    ),
    Err = cowboy_graphql:protocol_error(
        ws, malformed_packet, "Unexpected packet", #{packet => Unexpected, protocol => Proto}
    ),
    {[to_error(Proto, Err)], State}.

graphql_ws_to_results(Results) when is_list(Results) ->
    lists:flatmap(fun graphql_ws_to_results/1, Results);
graphql_ws_to_results({Id, Done, Data, Errors, Extensions}) ->
    Payload0 = cowboy_graphql:put_not_empty(<<"data">>, Data, #{}),
    Payload1 = cowboy_graphql:put_not_empty(<<"errors">>, Errors, Payload0),
    Payload = cowboy_graphql:put_not_empty(<<"extensions">>, Extensions, Payload1),
    Next =
        #{
            <<"type">> => <<"next">>,
            <<"id">> => Id,
            <<"payload">> => Payload
        },
    case Done of
        true ->
            [
                {json, Next},
                {json, #{
                    <<"type">> => <<"complete">>,
                    <<"id">> => Id
                }}
            ];
        false ->
            [{json, Next}]
    end.

apollo_to_results(Results) when is_list(Results) ->
    lists:flatmap(fun apollo_to_results/1, Results);
apollo_to_results({Id, Done, Data, Errors, _Extensions}) ->
    Payload0 = #{<<"data">> => Data},
    Payload = cowboy_graphql:put_not_empty(<<"errors">>, Errors, Payload0),
    Next =
        #{
            <<"type">> => <<"data">>,
            <<"id">> => Id,
            <<"payload">> => Payload
        },
    case Done of
        true ->
            [
                {json, Next},
                {json, #{
                    <<"type">> => <<"complete">>,
                    <<"id">> => Id
                }}
            ];
        false ->
            [{json, Next}]
    end.

to_error(_, {request_error, Id, #{message := _} = GraphQLError}) ->
    Msg = #{
        <<"type">> => <<"error">>,
        <<"id">> => Id,
        %supposed to be an array, but gql-cli crashes
        <<"payload">> => [GraphQLError]
    },
    {json, Msg};
to_error(apollo, {protocol_error, ws, malformed_packet, Msg, Extra}) ->
    %% Invalid JSON or missing `type` field
    Packet = #{
        <<"type">> => <<"connection_error">>,
        <<"payload">> => #{
            <<"message">> => unicode:characters_to_binary(Msg),
            <<"extra">> => Extra
        }
    },
    {json, Packet};
to_error(graphql_ws, {protocol_error, ws, malformed_packet, Msg, _Extra}) ->
    {close, 4400, unicode:characters_to_binary(Msg)};
to_error(_, {protocol_error, ws, _Code, Msg, _Extra}) ->
    {close, 4400, unicode:characters_to_binary(Msg)};
to_error(_, {other_error, Msg, _Extra}) ->
    {close, 4400, unicode:characters_to_binary(Msg)}.

json_decode(Json, #state{json_decode = Decode}) ->
    Decode(Json).

json_encode(Obj, #state{json_encode = Encode}) ->
    Encode(Obj).
