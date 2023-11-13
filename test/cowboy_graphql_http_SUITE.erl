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
    graphql_error_case/1,
    handle_request_validation_error_case/1,
    handle_request_other_error_case/1,
    handle_request_crash_case/1,
    connection_auth_error_case/1,
    connection_other_error_case/1,
    protocol_error_method_gencase/1
]).

-record(cli, {gun}).
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
                }
        },
        Payload
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
                <<"error-graphql">>,
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
    {400, Hdrs, Payload} = http_await_with_json_body(Gun, Stream),
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
    {ok, Pid} = gun:open("localhost", cowboy_graphql_mock:port()),
    {ok, http} = gun:await_up(Pid),
    #cli{gun = Pid}.

r(Reader) ->
    Reader().

enc(Cfg) ->
    lists:foldl(fun proplists:get_value/2, Cfg, [tc_group_properties, name]).

request(C, post_json, Path, Operation, Query, Vars) ->
    Headers = [
        {<<"Content-Type">>, <<"application/json">>},
        {<<"Accept">>, <<"application/json">>}
    ],
    Body = jsx:encode(#{
        <<"operationName">> => Operation,
        <<"query">> => Query,
        <<"variables">> => Vars
    }),
    http_post_path(Path, Headers, Body, C);
request(C, post_form, Path, Operation, Query, Vars) ->
    Headers = [
        {<<"Content-Type">>, <<"application/x-www-form-urlencoded">>},
        {<<"Accept">>, <<"application/json">>}
    ],
    Body = cow_qs:qs(
        [
            {<<"operationName">>, Operation},
            {<<"query">>, Query},
            {<<"variables">>, jsx:encode(Vars)}
        ]
    ),
    http_post_path(Path, Headers, Body, C);
request(C, get_qs, Path, Operation, Query, Vars) ->
    Headers = [{<<"Accept">>, <<"application/json">>}],
    QS = cow_qs:qs(
        [
            {<<"operationName">>, Operation},
            {<<"query">>, Query},
            {<<"variables">>, jsx:encode(Vars)}
        ]
    ),
    FullPath = iolist_to_binary([Path, $?, QS]),
    http_get_path(FullPath, Headers, C).

http_get_path(UrlPath, Hdrs, #cli{gun = Http}) ->
    Stream = gun:get(Http, UrlPath, Hdrs),
    fun() -> http_await_with_json_body(Http, Stream) end.

http_post_path(UrlPath, Hdrs, Body, #cli{gun = Http}) ->
    Stream = gun:post(Http, UrlPath, Hdrs, Body),
    fun() -> http_await_with_json_body(Http, Stream) end.

http_await_with_json_body(Pid, Stream) ->
    case gun:await(Pid, Stream) of
        {response, fin, Status, Headers} ->
            {Status, Headers};
        {response, nofin, Status, Headers} ->
            {ok, Body} = gun:await_body(Pid, Stream),
            {Status, Headers, jsx:decode(Body)}
    end.
