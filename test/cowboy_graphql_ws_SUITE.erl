-module(cowboy_graphql_ws_SUITE).

-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    echo_case/1,
    subscription_case/1,
    subscription_request_error_case/1,
    graphql_error_case/1,
    handle_request_validation_error_case/1,
    handle_request_other_error_case/1,
    handle_request_crash_case/1,
    connection_auth_error_case/1,
    connection_other_error_case/1,
    protocol_error_unordered_case/1,
    protocol_error_bad_json_syntax_case/1,
    protocol_error_bad_json_case/1,
    heartbeat_case/1,
    idle_timeout_case/1
]).

-record(cli, {gun, proto}).
-define(APP, cowboy_graphql).

-include_lib("stdlib/include/assert.hrl").

all() ->
    %% All exported functions of arity 1 whose name ends with "_case"
    [{group, graphql_ws}, {group, apollo}].

groups() ->
    Exports = ?MODULE:module_info(exports),
    {Generic, Proto} =
        lists:foldl(
            fun
                ({F, 1}, {Generic, Proto}) ->
                    case lists:reverse(atom_to_list(F)) of
                        "esacneg_" ++ _ -> {[F | Generic], Proto};
                        "esac_" ++ _ -> {Generic, [F | Proto]};
                        _ -> {Generic, Proto}
                    end;
                (_, Acc) ->
                    Acc
            end,
            {[], []},
            Exports
        ),
    [
        {graphql_ws, [sequence], Proto},
        {apollo, [sequence], Proto},
        {generic, [sequence], Generic}
    ].

init_per_suite(Cfg) ->
    {ok, _} = application:ensure_all_started(?APP),
    {ok, _} = application:ensure_all_started(gun),
    Cfg.

end_per_suite(Cfg) ->
    ok = application:stop(?APP),
    ok = application:stop(gun),
    Cfg.

init_per_testcase(Name, Cfg) ->
    Opts =
        try
            ?MODULE:Name({transport_opts, Cfg})
        catch
            error:function_clause ->
                #{}
        end,
    cowboy_graphql_mock:start(#{transports => [{ws, Opts}]}),
    ?MODULE:Name({pre, Cfg}).

end_per_testcase(Name, Cfg) ->
    cowboy_graphql_mock:stop(),
    ?MODULE:Name({post, Cfg}).

%% @doc Simple echo
echo_case({pre, Cfg}) ->
    Cfg;
echo_case({post, Cfg}) ->
    Cfg;
echo_case(Cfg) when is_list(Cfg) ->
    Cli = client("/api/ok--/websocket", proto(Cfg)),
    Payload = r(request(Cli, <<"echo">>, <<"graphql query">>, #{<<"k">> => <<"v">>})),
    ?assertEqual(
        #{
            <<"data">> =>
                #{
                    <<"extensions">> => #{},
                    <<"query">> => <<"graphql query">>,
                    <<"vars">> => #{<<"k">> => <<"v">>}
                }
        },
        Payload
    ),
    close(Cli).

%% @doc Same as `echo_case', but callback reports GraphQL executor error
graphql_error_case({pre, Cfg}) ->
    Cfg;
graphql_error_case({post, Cfg}) ->
    Cfg;
graphql_error_case(Cfg) when is_list(Cfg) ->
    Cli = client("/api/ok--/websocket", proto(Cfg)),
    Payload = r(request(Cli, <<"data-and-errors">>, <<"graphql query">>, #{<<"k">> => <<"v">>})),
    ?assertEqual(
        #{
            <<"data">> =>
                #{
                    <<"extensions">> => #{},
                    <<"query">> => <<"graphql query">>,
                    <<"vars">> => #{<<"k">> => <<"v">>}
                },
            <<"errors">> =>
                [
                    #{
                        <<"extensions">> => #{<<"k">> => <<"v">>},
                        <<"message">> => <<"graphql query">>
                    }
                ]
        },
        Payload
    ),
    close(Cli).

subscription_case({pre, Cfg}) ->
    Cfg;
subscription_case({post, Cfg}) ->
    Cfg;
subscription_case(Cfg) when is_list(Cfg) ->
    F = atom_to_binary(?FUNCTION_NAME),
    Cli = client("/api/ok--pubsub/websocket", proto(Cfg)),
    Resp = request(Cli, <<"subscribe">>, F, #{<<"k">> => <<"v">>}),
    %% TODO: better synchronization, request/4 is asynchronous
    timer:sleep(300),
    ok = cowboy_graphql_mock:sync(?FUNCTION_NAME),
    ?assertEqual(
        #{
            <<"data">> =>
                #{
                    <<"extensions">> => #{},
                    <<"query">> => <<"subscription_case">>,
                    <<"vars">> => #{<<"k">> => <<"v">>},
                    <<"extra">> => <<>>
                }
        },
        pubsub(Resp, ?FUNCTION_NAME, false)
    ),
    ?assertEqual(
        #{
            <<"data">> =>
                #{
                    <<"extensions">> => #{},
                    <<"query">> => <<"subscription_case">>,
                    <<"vars">> => #{<<"k">> => <<"v">>},
                    <<"extra">> => <<>>
                }
        },
        pubsub(Resp, ?FUNCTION_NAME, false)
    ),
    cancel(Cli, Resp),
    close(Cli).

%% @doc Subscription returned `error' from `handle_info'
subscription_request_error_case({pre, Cfg}) ->
    Cfg;
subscription_request_error_case({post, Cfg}) ->
    Cfg;
subscription_request_error_case(Cfg) when is_list(Cfg) ->
    F = atom_to_binary(?FUNCTION_NAME),
    Cli = client("/api/ok--pubsub/websocket", proto(Cfg)),
    Resp = request(Cli, <<"subscribe">>, F, #{<<"k">> => <<"v">>}),
    %% TODO: better synchronization, request/6 is asynchronous
    timer:sleep(300),
    ok = cowboy_graphql_mock:sync(?FUNCTION_NAME),
    Payload = pubsub_error(Resp, ?FUNCTION_NAME, <<"err msg">>),
    ?assertEqual(
        [
            #{
                <<"extensions">> => #{
                    <<"exts">> => #{},
                    <<"query">> => F,
                    <<"vars">> => #{<<"k">> => <<"v">>}
                },
                <<"message">> => <<"err msg">>
            }
        ],
        Payload
    ),
    close(Cli).

%% @doc `handle_request' callback returns `request_validation_error' error
handle_request_validation_error_case({pre, Cfg}) ->
    Cfg;
handle_request_validation_error_case({post, Cfg}) ->
    Cfg;
handle_request_validation_error_case(Cfg) when is_list(Cfg) ->
    F = atom_to_binary(?FUNCTION_NAME),
    Cli = client("/api/ok--/websocket", proto(Cfg)),
    Payload = re(request(Cli, <<"error-request-validation">>, F, #{<<"f">> => F})),
    ?assertEqual(
        #{
            <<"extensions">> => #{<<"f">> => F},
            <<"message">> => F
        },
        Payload
    ),
    close(Cli).

%% @doc `handle_request' callback returns `other_error' error
handle_request_other_error_case({pre, Cfg}) ->
    Cfg;
handle_request_other_error_case({post, Cfg}) ->
    Cfg;
handle_request_other_error_case(Cfg) when is_list(Cfg) ->
    F = atom_to_binary(?FUNCTION_NAME),
    Cli = client("/api/ok--/websocket", proto(Cfg)),
    ?assertEqual({close, 4400, F}, rc(request(Cli, <<"error-other">>, F, #{<<"f">> => F}))),
    close(Cli).

%% @doc `handle_request' crashes
handle_request_crash_case({pre, Cfg}) ->
    Cfg;
handle_request_crash_case({post, Cfg}) ->
    Cfg;
handle_request_crash_case(Cfg) when is_list(Cfg) ->
    F = atom_to_binary(?FUNCTION_NAME),
    Cli = client("/api/ok--/websocket", proto(Cfg)),
    ?assertMatch({close, 4500, _CrashId}, rc(request(Cli, <<"crash">>, F, #{<<"f">> => F}))),
    close(Cli).

%% @doc `connection' returns `auth_error'
connection_auth_error_case({pre, Cfg}) ->
    Cfg;
connection_auth_error_case({post, Cfg}) ->
    Cfg;
connection_auth_error_case(Cfg) when is_list(Cfg) ->
    try
        client("/api/auth-error--msg/websocket", proto(Cfg))
    catch
        throw:Err ->
            ?assertMatch(
                {403, _, #{
                    <<"errors">> :=
                        [
                            #{
                                <<"extensions">> :=
                                    #{<<"code">> := <<"authentication_error">>},
                                <<"message">> := <<"msg">>
                            }
                        ]
                }},
                Err
            )
    end.

%% @doc `connection' returns `other_error'
connection_other_error_case({pre, Cfg}) ->
    Cfg;
connection_other_error_case({post, Cfg}) ->
    Cfg;
connection_other_error_case(Cfg) when is_list(Cfg) ->
    try
        client("/api/error--msg/websocket", proto(Cfg))
    catch
        throw:Err ->
            ?assertMatch(
                {400, _Hdrs, #{<<"errors">> := [#{<<"message">> := <<"msg">>}]}},
                Err
            )
    end.

%% @doc Unordered protocol messages (request without init)
protocol_error_unordered_case({pre, Cfg}) ->
    Cfg;
protocol_error_unordered_case({post, Cfg}) ->
    Cfg;
protocol_error_unordered_case(Cfg) when is_list(Cfg) ->
    Proto = proto(Cfg),
    % Connect without handshake
    Cli = connect("/api/ok--/websocket", Proto),
    case ra(request(Cli, <<"echo">>, <<"graphql query">>, #{<<"k">> => <<"v">>})) of
        {close, 4400, Msg} when Proto == graphql_ws ->
            ?assertEqual(<<"Unexpected packet">>, Msg);
        {ok, Msg} when Proto == apollo ->
            ?assertMatch(
                #{
                    <<"type">> := <<"connection_error">>,
                    <<"payload">> :=
                        #{
                            <<"message">> := <<"Unexpected packet">>,
                            <<"extra">> :=
                                #{
                                    <<"packet">> :=
                                        #{
                                            <<"id">> := _,
                                            <<"payload">> :=
                                                #{
                                                    <<"operationName">> := <<"echo">>,
                                                    <<"query">> := <<"graphql query">>,
                                                    <<"variables">> := #{<<"k">> := <<"v">>}
                                                },
                                            <<"type">> := <<"start">>
                                        },
                                    <<"protocol">> := <<"apollo">>
                                }
                        }
                },
                Msg
            )
    end,
    close(Cli).

%% @doc Incorrect JSON syntax
protocol_error_bad_json_syntax_case({pre, Cfg}) ->
    Cfg;
protocol_error_bad_json_syntax_case({post, Cfg}) ->
    Cfg;
protocol_error_bad_json_syntax_case(Cfg) when is_list(Cfg) ->
    Proto = proto(Cfg),
    #cli{gun = {Pid, Stream}} = Cli = client("/api/ok--/websocket", Proto),
    ok = gun:ws_send(Pid, Stream, {text, <<"not-json">>}),
    case ws_await(Pid, Stream) of
        {ws, {text, Resp}} when Proto =:= apollo ->
            ?assertEqual(
                #{
                    <<"payload">> =>
                        #{
                            <<"extra">> => #{<<"json">> => <<"not-json">>},
                            <<"message">> => <<"Invalid JSON">>
                        },
                    <<"type">> => <<"connection_error">>
                },
                jsx:decode(Resp)
            );
        {ws, Other} when Proto =:= graphql_ws ->
            ?assertEqual({close, 4400, <<"Invalid JSON">>}, Other)
    end,
    close(Cli).

%% @doc Incorrect JSON structure
protocol_error_bad_json_case({pre, Cfg}) ->
    Cfg;
protocol_error_bad_json_case({post, Cfg}) ->
    Cfg;
protocol_error_bad_json_case(Cfg) when is_list(Cfg) ->
    Proto = proto(Cfg),
    #cli{gun = {Pid, Stream}} = Cli = client("/api/ok--/websocket", Proto),
    ok = gun:ws_send(Pid, Stream, {text, jsx:encode(#{<<"k">> => 1})}),
    case ws_await(Pid, Stream) of
        {ws, {text, Resp}} when Proto =:= apollo ->
            ?assertEqual(
                #{
                    <<"payload">> =>
                        #{
                            <<"extra">> => #{<<"packet">> => #{<<"k">> => 1}},
                            <<"message">> => <<"Missing 'type' field">>
                        },
                    <<"type">> => <<"connection_error">>
                },
                jsx:decode(Resp)
            );
        {ws, Other} when Proto =:= graphql_ws ->
            ?assertEqual({close, 4400, <<"Missing 'type' field">>}, Other)
    end,
    close(Cli).

%% @doc Make sure server sends `ping' packets when heartbeat is enabled
heartbeat_case({transport_opts, _Cfg}) ->
    #{heartbeat => 100};
heartbeat_case({pre, Cfg}) ->
    Cfg;
heartbeat_case({post, Cfg}) ->
    Cfg;
heartbeat_case(Cfg) when is_list(Cfg) ->
    Cli = #cli{gun = {Pid, Stream}} = client("/api/ok--/websocket", proto(Cfg)),
    %% requires `silence_pings => false'
    ?assertEqual({ws, ping}, ws_await(Pid, Stream)),
    ?assertEqual({ws, ping}, ws_await(Pid, Stream)),
    close(Cli),
    ok = gun:flush(Pid),
    ok.

%% @doc Connection is automatically closed when `idle_timeout' is set
idle_timeout_case({transport_opts, _Cfg}) ->
    #{idle_timeout => 300};
idle_timeout_case({pre, Cfg}) ->
    Cfg;
idle_timeout_case({post, Cfg}) ->
    Cfg;
idle_timeout_case(Cfg) when is_list(Cfg) ->
    Cli = #cli{gun = {Pid, Stream}} = client("/api/ok--/websocket", proto(Cfg)),
    %% Still possible to do requests
    Payload = r(request(Cli, <<"echo">>, <<"graphql query">>, #{<<"k">> => <<"v">>})),
    ?assertMatch(#{<<"data">> := #{<<"query">> := <<"graphql query">>}}, Payload),
    %% It replies with `pong' to `ping's
    ok = gun:ws_send(Pid, Stream, ping),
    ?assertMatch({ws, pong}, ws_await(Pid, Stream)),
    %% But then it times out
    ?assertEqual({ws, {close, 1000, <<>>}}, ws_await(Pid, Stream)),
    close(Cli),
    ok.

%%
%% Test client
%%

proto(Cfg) ->
    lists:foldl(fun proplists:get_value/2, Cfg, [tc_group_properties, name]).

client(Path, Protocol) ->
    Cli = connect(Path, Protocol),
    ok = init(Cli),
    Cli.

connect(Path, Protocol) ->
    {ok, Pid} = gun:open("localhost", cowboy_graphql_mock:port()),
    {ok, http} = gun:await_up(Pid),
    Proto =
        case Protocol of
            graphql_ws ->
                <<"graphql-transport-ws">>;
            apollo ->
                <<"graphql-ws">>
        end,
    WsStream1 = gun:ws_upgrade(Pid, Path, [], #{
        protocols => [{Proto, gun_ws_h}],
        silence_pings => false
    }),
    Stream =
        receive
            {gun_upgrade, Pid, WsStream1, [<<"websocket">>], _Hdrs} ->
                WsStream1;
            {gun_response, Pid, WsStream1, nofin, Code, Hdrs} ->
                {ok, Body} = gun:await_body(Pid, WsStream1),
                ok = gun:shutdown(Pid),
                throw({Code, Hdrs, jsx:decode(Body)});
            Other ->
                error({bad_msg, Other})
        after 5000 -> error(timeout)
        end,
    #cli{gun = {Pid, Stream}, proto = Protocol}.

init(#cli{gun = {Pid, Stream}, proto = graphql_ws}) ->
    Pkt = jsx:encode(#{<<"type">> => <<"connection_init">>}),
    ok = gun:ws_send(Pid, Stream, {text, Pkt}),
    {ws, {text, Resp}} = ws_await(Pid, Stream),
    ?assertMatch(#{<<"type">> := <<"connection_ack">>}, jsx:decode(Resp)),
    ok;
init(#cli{gun = {Pid, Stream}, proto = apollo}) ->
    Pkt = jsx:encode(#{<<"type">> => <<"connection_init">>}),
    ok = gun:ws_send(Pid, Stream, {text, Pkt}),
    {ws, {text, Resp1}} = ws_await(Pid, Stream),
    ?assertMatch(#{<<"type">> := <<"connection_ack">>}, jsx:decode(Resp1)),
    {ws, {text, Resp2}} = ws_await(Pid, Stream),
    ?assertMatch(#{<<"type">> := <<"ka">>}, jsx:decode(Resp2)),
    ok.

close(#cli{gun = {Pid, _Stream}}) ->
    ok = gun:shutdown(Pid).

request(#cli{proto = graphql_ws = Proto, gun = {Pid, Stream}}, Op, Query, Vars) ->
    ReqId = integer_to_binary(erlang:unique_integer([positive])),
    Pkt = jsx:encode(#{
        <<"type">> => <<"subscribe">>,
        <<"id">> => ReqId,
        <<"payload">> =>
            #{
                <<"operationName">> => Op,
                <<"query">> => Query,
                <<"variables">> => Vars
            }
    }),
    ok = gun:ws_send(Pid, Stream, {text, Pkt}),
    {ReqId, Proto, fun() ->
        case ws_await(Pid, Stream) of
            {ws, {text, Resp}} ->
                {ok, jsx:decode(Resp)};
            {ws, Other} ->
                Other
        end
    end};
request(#cli{proto = apollo = Proto, gun = {Pid, Stream}}, Op, Query, Vars) ->
    ReqId = integer_to_binary(erlang:unique_integer([positive])),
    Pkt = jsx:encode(#{
        <<"type">> => <<"start">>,
        <<"id">> => ReqId,
        <<"payload">> =>
            #{
                <<"operationName">> => Op,
                <<"query">> => Query,
                <<"variables">> => Vars
            }
    }),
    ok = gun:ws_send(Pid, Stream, {text, Pkt}),
    {ReqId, Proto, fun() ->
        case ws_await(Pid, Stream) of
            {ws, {text, Resp}} ->
                {ok, jsx:decode(Resp)};
            {ws, Other} ->
                Other
        end
    end}.

cancel(#cli{proto = graphql_ws, gun = {Pid, Stream}}, {ReqId, _, _}) ->
    Pkt = jsx:encode(#{
        <<"type">> => <<"complete">>,
        <<"id">> => ReqId
    }),
    ok = gun:ws_send(Pid, Stream, {text, Pkt});
cancel(#cli{proto = apollo, gun = {Pid, Stream}}, {ReqId, _, _}) ->
    Pkt = jsx:encode(#{
        <<"type">> => <<"stop">>,
        <<"id">> => ReqId
    }),
    ok = gun:ws_send(Pid, Stream, {text, Pkt}).

r({ReqId, graphql_ws, Await}) ->
    {ok, #{
        <<"type">> := <<"next">>,
        <<"id">> := ReqId,
        <<"payload">> := Payload
    }} = Await(),
    {ok, #{
        <<"type">> := <<"complete">>,
        <<"id">> := ReqId
    }} = Await(),
    Payload;
r({ReqId, apollo, Await}) ->
    {ok, #{
        <<"type">> := <<"data">>,
        <<"id">> := ReqId,
        <<"payload">> := Payload
    }} = Await(),
    {ok, #{
        <<"type">> := <<"complete">>,
        <<"id">> := ReqId
    }} = Await(),
    Payload.

pubsub({ReqId, graphql_ws, Await}, Conn, Done) ->
    ok = cowboy_graphql_mock:publish(Conn, ReqId, <<>>, Done),
    {ok, #{
        <<"type">> := <<"next">>,
        <<"id">> := ReqId,
        <<"payload">> := Payload
    }} = Await(),
    Payload;
pubsub({ReqId, apollo, Await}, Conn, Done) ->
    ok = cowboy_graphql_mock:publish(Conn, ReqId, <<>>, Done),
    {ok, #{
        <<"type">> := <<"data">>,
        <<"id">> := ReqId,
        <<"payload">> := Payload
    }} = Await(),
    Payload.

pubsub_error({ReqId, _, Await}, Conn, Msg) ->
    ok = cowboy_graphql_mock:publish_request_error(Conn, ReqId, Msg),
    {ok, #{
        <<"type">> := <<"error">>,
        <<"id">> := ReqId,
        <<"payload">> := Payload
    }} = Await(),
    Payload.

re({ReqId, Proto, Await}) when
    Proto == graphql_ws;
    Proto == apollo
->
    {ok, #{
        <<"type">> := <<"error">>,
        <<"id">> := ReqId,
        <<"payload">> := [Payload]
    }} = Await(),
    Payload.

rc({_ReqId, _Proto, Await}) ->
    {close, _Code, _Msg} = Await().

ra({_ReqId, _Proto, Await}) ->
    Await().

ws_await(Pid, Stream) ->
    MRef = monitor(process, Pid),
    receive
        {gun_ws, Pid, Stream, Frame} ->
            demonitor(MRef, [flush]),
            {ws, Frame};
        {'DOWN', MRef, process, Pid, Reason} ->
            {error, Reason};
        Other ->
            error({bad_msg, Other})
    after 5000 ->
        demonitor(MRef, [flush]),
        error(timeout)
    end.
