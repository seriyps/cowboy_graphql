-module(cowboy_graphql_http_SUITE).

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
    echo_multipart_case/1,
    graphql_error_case/1,
    subscription_case/1,
    subscription_multipart_case/1,
    subscription_autocancel_case/1,
    subscription_request_error_case/1,
    handle_request_validation_error_case/1,
    handle_request_other_error_case/1,
    handle_request_crash_case/1,
    connection_auth_error_case/1,
    connection_other_error_case/1,
    protocol_error_method_gencase/1
]).

-record(cli, {gun, accept}).
-define(APP, cowboy_graphql).

-include_lib("stdlib/include/assert.hrl").

all() ->
    %% All exported functions of arity 1 whose name ends with "_case"
    [{group, post_json}, {group, post_form}, {group, get_qs}, {group, generic}].

groups() ->
    Exports = ?MODULE:module_info(exports),
    Cases = [
        F
     || {F, A} <- Exports,
        A == 1,
        case lists:reverse(atom_to_list(F)) of
            "esac_" ++ _ -> true;
            _ -> false
        end
    ],
    [
        {post_json, [sequence], Cases},
        {post_form, [sequence], Cases},
        {get_qs, [sequence], Cases},
        {generic, [sequence], [protocol_error_method_gencase]}
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
    cowboy_graphql_mock:start(#{transports => [http]}),
    ?MODULE:Name({pre, Cfg}).

end_per_testcase(Name, Cfg) ->
    cowboy_graphql_mock:stop(),
    ?MODULE:Name({post, Cfg}).

%% @doc Simple echo command (happy path)
echo_case({pre, Cfg}) ->
    Cfg;
echo_case({post, Cfg}) ->
    Cfg;
echo_case(Cfg) when is_list(Cfg) ->
    Cli = client(),
    {200, Hdrs, Payload} =
        r(
            request(
                Cli,
                enc(Cfg),
                "/api/ok--",
                <<"echo">>,
                <<"graphql query">>,
                #{<<"k">> => <<"v">>},
                #{<<"ek">> => <<"ev">>}
            )
        ),
    ?assertEqual(<<"application/json">>, proplists:get_value(<<"content-type">>, Hdrs)),
    ?assertEqual(
        #{
            <<"data">> =>
                #{
                    <<"extensions">> => #{<<"ek">> => <<"ev">>},
                    <<"query">> => <<"graphql query">>,
                    <<"vars">> => #{<<"k">> => <<"v">>}
                }
        },
        Payload
    ),
    ok.

%% @doc Simple echo command over multipart/mixed (happy path)
echo_multipart_case({pre, Cfg}) ->
    Cfg;
echo_multipart_case({post, Cfg}) ->
    Cfg;
echo_multipart_case(Cfg) when is_list(Cfg) ->
    Cli = client(<<"multipart/mixed">>),
    {200, Hdrs, NextChunkFun} =
        r(
            request(
                Cli,
                enc(Cfg),
                "/api/ok--",
                <<"echo">>,
                <<"graphql query">>,
                #{<<"k">> => <<"v">>},
                #{<<"ek">> => <<"ev">>}
            )
        ),
    ?assertMatch(<<"multipart/mixed", _/binary>>, proplists:get_value(<<"content-type">>, Hdrs)),
    {done, ChunkHdrs, Data} = NextChunkFun(),
    ?assertMatch(
        <<"application/json", _/binary>>, proplists:get_value(<<"content-type">>, ChunkHdrs)
    ),
    ?assertEqual(
        #{
            <<"data">> =>
                #{
                    <<"extensions">> => #{<<"ek">> => <<"ev">>},
                    <<"query">> => <<"graphql query">>,
                    <<"vars">> => #{<<"k">> => <<"v">>}
                }
        },
        Data
    ),
    ok.

%% @doc Same as `echo_case', but callback reports GraphQL executor error
graphql_error_case({pre, Cfg}) ->
    Cfg;
graphql_error_case({post, Cfg}) ->
    Cfg;
graphql_error_case(Cfg) when is_list(Cfg) ->
    Cli = client(),
    {200, Hdrs, Payload} =
        r(
            request(
                Cli,
                enc(Cfg),
                "/api/ok--",
                <<"data-and-errors">>,
                <<"graphql query">>,
                #{<<"k">> => <<"v">>}
            )
        ),
    ?assertEqual(<<"application/json">>, proplists:get_value(<<"content-type">>, Hdrs)),
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
    ok.

%% @doc Subscription over HTTP with long-polling (only one response allowed)
subscription_case({pre, Cfg}) ->
    Cfg;
subscription_case({post, Cfg}) ->
    Cfg;
subscription_case(Cfg) when is_list(Cfg) ->
    F = atom_to_binary(?FUNCTION_NAME),
    Cli = client(),
    Resp = request(Cli, enc(Cfg), "/api/ok--pubsub", <<"subscribe">>, F, #{<<"k">> => <<"v">>}),
    %% TODO: better synchronization, request/6 is asynchronous
    timer:sleep(300),
    ok = cowboy_graphql_mock:sync(?FUNCTION_NAME),
    {200, Hdrs, Payload} = pubsub(?FUNCTION_NAME, Resp, #{}, true),
    ?assertEqual(<<"application/json">>, proplists:get_value(<<"content-type">>, Hdrs)),
    ?assertEqual(
        #{
            <<"data">> =>
                #{
                    <<"extensions">> => #{},
                    <<"query">> => <<"subscription_case">>,
                    <<"vars">> => #{<<"k">> => <<"v">>},
                    <<"extra">> => #{}
                }
        },
        Payload
    ).

%% @doc Subscription over HTTP with multipart/mixed response body
subscription_multipart_case({pre, Cfg}) ->
    Cfg;
subscription_multipart_case({post, Cfg}) ->
    Cfg;
subscription_multipart_case(Cfg) when is_list(Cfg) ->
    F = atom_to_binary(?FUNCTION_NAME),
    Cli = client(<<"multipart/mixed">>),
    Resp = request(Cli, enc(Cfg), "/api/ok--pubsub", <<"subscribe">>, F, #{<<"k">> => <<"v">>}),
    %% TODO: better synchronization, request/6 is asynchronous
    timer:sleep(300),
    ok = cowboy_graphql_mock:sync(?FUNCTION_NAME),
    {200, Hdrs, NextChunkFun1} = pubsub(?FUNCTION_NAME, Resp, <<"req1">>, false),
    ?assertMatch(<<"multipart/mixed", _/binary>>, proplists:get_value(<<"content-type">>, Hdrs)),
    %% HTTP/1.1 but not HTTP/2
    %% ?assertEqual(<<"chunked">>, proplists:get_value(<<"transfer-encoding">>, Hdrs)),

    {ok, ChunkHdrs1, Data1, NextChunkFun2} = NextChunkFun1(),
    ?assertMatch(
        <<"application/json", _/binary>>,
        proplists:get_value(<<"content-type">>, ChunkHdrs1)
    ),
    ?assertEqual(
        #{
            <<"data">> =>
                #{
                    <<"extensions">> => #{},
                    <<"query">> => <<"subscription_multipart_case">>,
                    <<"vars">> => #{<<"k">> => <<"v">>},
                    <<"extra">> => <<"req1">>
                }
        },
        Data1
    ),
    {done, ChunkHdrs2, Data2} = pubsub(?FUNCTION_NAME, NextChunkFun2, <<"req2">>, true),
    ?assertMatch(
        <<"application/json", _/binary>>,
        proplists:get_value(<<"content-type">>, ChunkHdrs2)
    ),
    ?assertEqual(
        #{
            <<"data">> =>
                #{
                    <<"extensions">> => #{},
                    <<"query">> => <<"subscription_multipart_case">>,
                    <<"vars">> => #{<<"k">> => <<"v">>},
                    <<"extra">> => <<"req2">>
                }
        },
        Data2
    ).

%% @doc Subscription over HTTP with long-polling - it is ok to return `Done = false'
%% When `Done = false', the `handle_cancel' callback will be called.
subscription_autocancel_case({pre, Cfg}) ->
    Cfg;
subscription_autocancel_case({post, Cfg}) ->
    Cfg;
subscription_autocancel_case(Cfg) when is_list(Cfg) ->
    F = atom_to_binary(?FUNCTION_NAME),
    Cli = client(),
    Resp = request(Cli, enc(Cfg), "/api/ok--pubsub", <<"subscribe">>, F, #{<<"k">> => <<"v">>}),
    %% TODO: better synchronization, request/6 is asynchronous
    timer:sleep(300),
    ok = cowboy_graphql_mock:sync(?FUNCTION_NAME),
    {200, Hdrs, Payload} = pubsub(?FUNCTION_NAME, Resp, #{}, false),
    ?assertEqual(<<"application/json">>, proplists:get_value(<<"content-type">>, Hdrs)),
    ?assertEqual(
        #{
            <<"data">> =>
                #{
                    <<"extensions">> => #{},
                    <<"query">> => <<"subscription_autocancel_case">>,
                    <<"vars">> => #{<<"k">> => <<"v">>},
                    <<"extra">> => #{}
                }
        },
        Payload
    ).

%% @doc Subscription returned `error' from `handle_info'
subscription_request_error_case({pre, Cfg}) ->
    Cfg;
subscription_request_error_case({post, Cfg}) ->
    Cfg;
subscription_request_error_case(Cfg) when is_list(Cfg) ->
    F = atom_to_binary(?FUNCTION_NAME),
    Cli = client(),
    Resp = request(Cli, enc(Cfg), "/api/ok--pubsub", <<"subscribe">>, F, #{<<"k">> => <<"v">>}),
    %% TODO: better synchronization, request/6 is asynchronous
    timer:sleep(300),
    ok = cowboy_graphql_mock:sync(?FUNCTION_NAME),
    {200, Hdrs, Payload} = pubsub_error(?FUNCTION_NAME, Resp, <<"err msg">>),
    ?assertEqual(<<"application/json">>, proplists:get_value(<<"content-type">>, Hdrs)),
    ?assertEqual(
        #{
            <<"errors">> =>
                [
                    #{
                        <<"extensions">> => #{
                            <<"exts">> => #{},
                            <<"query">> => F,
                            <<"vars">> => #{<<"k">> => <<"v">>}
                        },
                        <<"message">> => <<"err msg">>
                    }
                ]
        },
        Payload
    ).

%% @doc `handle_request' callback returns `request_validation_error' error
handle_request_validation_error_case({pre, Cfg}) ->
    Cfg;
handle_request_validation_error_case({post, Cfg}) ->
    Cfg;
handle_request_validation_error_case(Cfg) when is_list(Cfg) ->
    F = atom_to_binary(?FUNCTION_NAME),
    Cli = client(),
    {200, Hdrs, Payload} =
        r(
            request(
                Cli, enc(Cfg), "/api/ok--", <<"error-request-validation">>, F, #{<<"f">> => F}
            )
        ),
    ?assertEqual(<<"application/json">>, proplists:get_value(<<"content-type">>, Hdrs)),
    ?assertEqual(
        #{
            <<"errors">> =>
                [
                    #{
                        <<"extensions">> => #{<<"f">> => F},
                        <<"message">> => F
                    }
                ]
        },
        Payload
    ).

%% @doc `handle_request' callback returns `other_error' error
handle_request_other_error_case({pre, Cfg}) ->
    Cfg;
handle_request_other_error_case({post, Cfg}) ->
    Cfg;
handle_request_other_error_case(Cfg) when is_list(Cfg) ->
    F = atom_to_binary(?FUNCTION_NAME),
    Cli = client(),
    {400, Hdrs, Payload} =
        r(
            request(
                Cli, enc(Cfg), "/api/ok--", <<"error-other">>, F, #{<<"f">> => F}
            )
        ),
    ?assertEqual(<<"application/json">>, proplists:get_value(<<"content-type">>, Hdrs)),
    ?assertEqual(
        #{
            <<"errors">> =>
                [
                    #{
                        <<"extensions">> => #{<<"f">> => F},
                        <<"message">> => F
                    }
                ]
        },
        Payload
    ).

%% @doc `handle_request' crashes
handle_request_crash_case({pre, Cfg}) ->
    Cfg;
handle_request_crash_case({post, Cfg}) ->
    Cfg;
handle_request_crash_case(Cfg) when is_list(Cfg) ->
    F = atom_to_binary(?FUNCTION_NAME),
    Cli = client(),
    {500, Hdrs, Payload} =
        r(
            request(
                Cli, enc(Cfg), "/api/ok--", <<"crash">>, F, #{<<"f">> => F}
            )
        ),
    ?assertEqual(<<"application/json">>, proplists:get_value(<<"content-type">>, Hdrs)),
    ?assertMatch(
        #{
            <<"errors">> :=
                [
                    #{
                        <<"extensions">> := #{<<"error_id">> := _},
                        <<"message">> := <<"internal_error">>
                    }
                ]
        },
        Payload
    ).

%% @doc `connection' returns `auth_error'
connection_auth_error_case({pre, Cfg}) ->
    Cfg;
connection_auth_error_case({post, Cfg}) ->
    Cfg;
connection_auth_error_case(Cfg) when is_list(Cfg) ->
    F = atom_to_binary(?FUNCTION_NAME),
    Cli = client(),
    {403, Hdrs, Payload} =
        r(
            request(
                Cli, enc(Cfg), "/api/auth-error--msg", <<"echo">>, F, #{<<"f">> => F}
            )
        ),
    ?assertEqual(<<"application/json">>, proplists:get_value(<<"content-type">>, Hdrs)),
    ?assertEqual(
        #{
            <<"errors">> =>
                [
                    #{
                        <<"extensions">> => #{<<"code">> => <<"authentication_error">>},
                        <<"message">> => <<"msg">>
                    }
                ]
        },
        Payload
    ).

%% @doc `connection' returns `other_error'
connection_other_error_case({pre, Cfg}) ->
    Cfg;
connection_other_error_case({post, Cfg}) ->
    Cfg;
connection_other_error_case(Cfg) when is_list(Cfg) ->
    F = atom_to_binary(?FUNCTION_NAME),
    Cli = client(),
    {400, Hdrs, Payload} =
        r(
            request(
                Cli, enc(Cfg), "/api/error--msg", <<"echo">>, F, #{<<"f">> => F}
            )
        ),
    ?assertEqual(<<"application/json">>, proplists:get_value(<<"content-type">>, Hdrs)),
    ?assertEqual(
        #{<<"errors">> => [#{<<"message">> => <<"msg">>}]},
        Payload
    ).

protocol_error_method_gencase({pre, Cfg}) ->
    Cfg;
protocol_error_method_gencase({post, Cfg}) ->
    Cfg;
protocol_error_method_gencase(Cfg) when is_list(Cfg) ->
    #cli{gun = Gun} = client(),
    Stream = gun:put(Gun, "/api/ok--", [], <<"{}">>),
    {400, Hdrs, Payload} = http_await_with_json_body(Gun, Stream, <<"application/json">>),
    ?assertEqual(<<"application/json">>, proplists:get_value(<<"content-type">>, Hdrs)),
    ?assertEqual(
        #{
            <<"errors">> =>
                [
                    #{
                        <<"extensions">> => #{<<"code">> => <<"method_not_allowed">>},
                        <<"message">> => <<"Http processing error: method_not_allowed">>
                    }
                ]
        },
        Payload
    ).

%%
%% Test client

client() ->
    client(<<"application/json">>).

client(Accept) ->
    {ok, Pid} = gun:open("localhost", cowboy_graphql_mock:port()),
    {ok, http} = gun:await_up(Pid),
    #cli{gun = Pid, accept = Accept}.

r(Reader) ->
    Reader().

enc(Cfg) ->
    lists:foldl(fun proplists:get_value/2, Cfg, [tc_group_properties, name]).

request(C, Format, Path, Op, Query, Vars) ->
    request(C, Format, Path, Op, Query, Vars, null).

request(#cli{accept = Accept} = C, post_json, Path, Operation, Query, Vars, Extensions) ->
    Headers = [
        {<<"Content-Type">>, <<"application/json">>},
        {<<"Accept">>, Accept}
    ],
    Body = jsx:encode(
        preprocess(
            [
                {<<"operationName">>, Operation},
                {<<"query">>, Query},
                {<<"variables">>, Vars},
                {<<"extensions">>, Extensions}
            ],
            fun(V) -> V end
        )
    ),
    http_post_path(Path, Headers, Body, C);
request(#cli{accept = Accept} = C, post_form, Path, Operation, Query, Vars, Extensions) ->
    Headers = [
        {<<"Content-Type">>, <<"application/x-www-form-urlencoded">>},
        {<<"Accept">>, Accept}
    ],
    Body = cow_qs:qs(
        preprocess(
            [
                {<<"operationName">>, Operation},
                {<<"query">>, Query},
                {<<"variables">>, jsx:encode(Vars)},
                {<<"extensions">>, Extensions}
            ],
            fun jsx:encode/1
        )
    ),
    http_post_path(Path, Headers, Body, C);
request(#cli{accept = Accept} = C, get_qs, Path, Operation, Query, Vars, Extensions) ->
    Headers = [{<<"Accept">>, Accept}],
    QS = cow_qs:qs(
        preprocess(
            [
                {<<"operationName">>, Operation},
                {<<"query">>, Query},
                {<<"variables">>, jsx:encode(Vars)},
                {<<"extensions">>, Extensions}
            ],
            fun jsx:encode/1
        )
    ),
    FullPath = iolist_to_binary([Path, $?, QS]),
    http_get_path(FullPath, Headers, C).

http_get_path(UrlPath, Hdrs, #cli{gun = Http, accept = Accept}) ->
    Stream = gun:get(Http, UrlPath, Hdrs),
    fun() -> http_await_with_json_body(Http, Stream, Accept) end.

http_post_path(UrlPath, Hdrs, Body, #cli{gun = Http, accept = Accept}) ->
    Stream = gun:post(Http, UrlPath, Hdrs, Body),
    fun() -> http_await_with_json_body(Http, Stream, Accept) end.

http_await_with_json_body(Pid, Stream, Accept) ->
    case gun:await(Pid, Stream) of
        {response, fin, Status, Headers} ->
            {Status, Headers};
        {response, nofin, Status, Headers} when Accept == <<"application/json">> ->
            {ok, Body} = gun:await_body(Pid, Stream),
            {Status, Headers, jsx:decode(Body)};
        {response, nofin, Status, Headers} when Accept == <<"multipart/mixed">> ->
            ct:pal("Status: ~p~nHeaders: ~p", [Status, Headers]),
            <<"multipart/mixed;boundary=", Boundary/binary>> = proplists:get_value(
                <<"content-type">>, Headers
            ),
            {Status, Headers, fun() -> next_chunk(Pid, Stream, Boundary) end}
    end.

next_chunk(Pid, Stream, Boundary) ->
    receive
        {gun_data, Pid, Stream, IsFin, Data} ->
            {ok, PartHdrs, Rest} = cow_multipart:parse_headers(Data, Boundary),
            case IsFin of
                fin ->
                    {done, Body, _Trail} = cow_multipart:parse_body(Rest, Boundary),
                    Struct = jsx:decode(Body),
                    {done, PartHdrs, Struct};
                nofin ->
                    {ok, Body} = cow_multipart:parse_body(Rest, Boundary),
                    Struct = jsx:decode(Body),
                    {ok, PartHdrs, Struct, fun() -> next_chunk(Pid, Stream, Boundary) end}
            end;
        Other ->
            Other
    after 5000 ->
        error(timeout)
    end.

pubsub(Proc, Await, Extra, Done) ->
    ok = cowboy_graphql_mock:publish(Proc, <<"1">>, Extra, Done),
    Await().

pubsub_error(Proc, Await, Msg) ->
    ok = cowboy_graphql_mock:publish_request_error(Proc, <<"1">>, Msg),
    Await().

preprocess([{_K, null} | KV], MapEncoder) ->
    preprocess(KV, MapEncoder);
preprocess([{K, V} | KV], MapEncoder) when is_map(V) ->
    [{K, MapEncoder(V)} | preprocess(KV, MapEncoder)];
preprocess([{K, V} | KV], MapEncoder) when is_binary(V) ->
    [{K, V} | preprocess(KV, MapEncoder)];
preprocess([], _) ->
    [].
