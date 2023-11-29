%%% @author Sergey <me@seriyps.ru>
%%% @copyright (C) 2021, Sergey
%%% @doc
%%% Cowboy HTTP handler for graphql API
%%%
%%% It supports following REQUEST methods:
%%% * HTTP GET with query, operationName, variables, extensions query string parameters
%%% * HTTP POST with application/json payload
%%% * HTTP POST with application/x-www-form-urlencoded payload
%%% For POST payload is negotiated via Content-Type header
%%% See https://github.com/graphql/graphql-over-http/blob/main/spec/GraphQLOverHTTP.md
%%%
%%% It supports following RESPONSE methods (negotiated via Accept header):
%%% * application/json (only single reply can be delivered)
%%%   See https://github.com/graphql/graphql-over-http/blob/main/spec/GraphQLOverHTTP.md#response
%%% * multipart/mixed (multiple replies can be delivered, including subscription stream)
%%%   See https://github.com/graphql/graphql-over-http/blob/main/rfcs/IncrementalDelivery.md
%%%
%%% We don't use `application/graphql-response+json' yet, just `application/json'.
%%% Non-graphql-execution errors are also reported as `application/json'
%%% @end
%%% Created : 14 Feb 2021 by Sergey <me@seriyps.ru>

-module(cowboy_graphql_http_handler).

%% -behaviour(cowboy_handler).
-behaviour(cowboy_loop).

-export([config/3]).
-export([init/2, info/3, terminate/3]).
% private
-export([format_error/2]).
-export_type([
    input_content_type/0,
    options/0,
    config/0,
    features/0
]).

-include_lib("kernel/include/logger.hrl").
-define(APP, cowboy_graphql).
-define(LOG_DOMAIN, [?APP, http_handler]).

-record(state, {
    cb :: module(),
    cb_state :: any(),
    json_encode :: fun((any()) -> iodata()),
    json_decode :: fun((binary()) -> any()),
    resp_method :: {output_content_type(), binary(), any()} | undefined,
    methods :: ordsets:ordset(binary()),
    inputs :: #{{binary(), binary()} => input_content_type()},
    outputs :: [{{binary(), binary()}, output_content_type()}],
    opts :: options(),
    error :: undefined | tuple() | atom(),
    headers_sent = false :: boolean(),
    heartbeat_ref :: reference() | undefined
}).

%% -type json_object() :: tm_graphql_ws_handler:json_object().
-type input_content_type() :: json | x_www_form_urlencoded.
-type output_content_type() :: json | multipart.
-type options() :: #{
    accept_body => [input_content_type()],
    response_types => [output_content_type()],
    allowed_methods => [post | get],
    json_mod => module(),
    max_body_size => pos_integer(),
    heartbeat => pos_integer() | undefined,
    timeout => timeout() | undefined
}.
%% HTTP handler options
%% * accept_body - what POST body content-types we allow (negotiated via `Content-Type' request hdr)
%% * response_types - in what `Content-Type' the body should be returned (negotiated via `Accept'
%%   request header)
%% If request header is not provided, the first element of the config list will be choosen
-opaque config() :: {module(), any(), options()}.

-type features() :: #{
    method => post | get,
    payload_type => query_string | input_content_type(),
    response_type => output_content_type()
}.

-define(INPUT_CT_MAP, #{
    json => [{<<"application">>, <<"json">>}, {<<"text">>, <<"json">>}],
    x_www_form_urlencoded => [{<<"application">>, <<"x-www-form-urlencoded">>}]
}).
-define(METHOD_MAP, #{
    get => <<"GET">>,
    post => <<"POST">>
}).
-define(OUTPUT_CT_MAP, #{
    json => {<<"application">>, <<"json">>},
    multipart => {<<"multipart">>, <<"mixed">>}
}).

-define(REQ_ID, <<"1">>).

-spec config(module(), any(), options()) -> config().
config(Callback, CallbackOptions, TransportOptions) ->
    {Callback, CallbackOptions, TransportOptions}.

%%
%% Cowboy callbacks
%%

init(Req, {Callback, CallbackOpts, Params0}) ->
    DefaultParams = #{
        accept_body => [json, x_www_form_urlencoded],
        response_types => [json, multipart],
        allowed_methods => [post, get],
        json_mod => jsx,
        max_body_size => 5 * 1024 * 1024,
        timeout => 10 * 60 * 1000
    },
    Params = maps:merge(DefaultParams, Params0),
    case cowboy_graphql:call_connection(Callback, Req, CallbackOpts) of
        {error, Reason} ->
            ?LOG_INFO(
                #{
                    label => callback_error,
                    req => Req,
                    reason => Reason
                },
                #{domain => ?LOG_DOMAIN}
            ),
            JsonMod = maps:get(json_mod, Params),
            {Code, ResBody} = format_error([auth_error, protocol_error, other_error], Reason),
            {ok,
                cowboy_req:reply(
                    Code,
                    #{<<"content-type">> => <<"application/json">>},
                    JsonMod:encode(ResBody),
                    Req
                ),
                []};
        {ok, CbState} ->
            %% We need to translate `cowboy_loop' return tuples to `cowboy_handler' tuples
            case do(Req, Callback, CbState, Params) of
                {ok, Req1, St} ->
                    {cowboy_loop, Req1, reset_heartbeat(start_timeout(St))};
                {stop, Req1, St} ->
                    {ok, Req1, St}
            end
    end.

info({?MODULE, heartbeat}, Req0, St) ->
    response(200, <<"{}">>, false, Req0, reset_heartbeat(St));
info({?MODULE, timeout}, Req0, #state{opts = #{timeout := Timeout}} = St) ->
    {_Code, ErrBody} = format_error(
        [protocol_error],
        cowboy_graphql:protocol_error(http, timeout, <<"Request execution timed out">>, #{
            timeout_ms => Timeout
        })
    ),
    {stop, _, _} = response(
        200, json_encode(ErrBody, St), true, Req0, reset_heartbeat(St#state{error = timeout})
    );
info(Msg, Req0, #state{cb = Callback, cb_state = CallbackState0} = St) ->
    case cowboy_graphql:call_handle_info(Callback, Msg, CallbackState0) of
        {noreply, CallbackState} ->
            {ok, Req0, St#state{cb_state = CallbackState}};
        {reply, Resp, CallbackState1} ->
            response(Resp, Req0, St#state{cb_state = CallbackState1});
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
            {Code, ResBody} = format_error([request_error, other_error], Err),
            {stop,
                response(
                    Code,
                    json_encode(ResBody, St),
                    true,
                    Req0,
                    St
                ),
                St#state{cb_state = CallbackState}}
    end.

do(
    Req0,
    Callback,
    CbState,
    #{
        allowed_methods := AllowedMethods,
        accept_body := Accept,
        response_types := RespTypes,
        json_mod := JsonMod
    } = Params
) ->
    Inputs = maps:from_list(
        lists:flatmap(
            fun(Input) ->
                CTs = maps:get(Input, ?INPUT_CT_MAP),
                [{CT, Input} || CT <- CTs]
            end,
            Accept
        )
    ),
    Outputs = [{maps:get(Name, ?OUTPUT_CT_MAP), Name} || Name <- RespTypes],
    St0 = #state{
        cb = Callback,
        cb_state = CbState,
        json_encode = fun JsonMod:encode/1,
        json_decode = fun JsonMod:decode/1,
        methods = ordsets:from_list([maps:get(M, ?METHOD_MAP) || M <- AllowedMethods]),
        inputs = Inputs,
        outputs = Outputs,
        opts = Params
    },
    try execute(Req0, St0) of
        {reply, Rep, Req, St1} ->
            ?LOG_DEBUG(#{tag => graphql_success, result => Rep}, #{domain => ?LOG_DOMAIN}),
            response(Rep, Req, St1);
        {loop, Req, St1} ->
            {ok, Req, St1}
    catch
        throw:{{callback, St1, Error}, Req1} ->
            %% Error returned from callback module
            ?LOG_NOTICE(
                #{
                    tag => callback_error,
                    req => Req1,
                    reason => Error
                },
                #{domain => ?LOG_DOMAIN}
            ),
            {Code, ResBody} = format_error([protocol_error], Error),
            {stop, response(Code, json_encode(ResBody, St1), true, Req1, St1), St1#state{
                error = Error
            }};
        throw:{{?MODULE, St1, ProtocolError}, Req1} when is_tuple(ProtocolError) ->
            %% Error generated by this module
            ?LOG_NOTICE(
                #{
                    tag => protocol_error,
                    req => Req1,
                    reason => ProtocolError
                },
                #{domain => ?LOG_DOMAIN}
            ),
            {Code, ResBody} = format_error([protocol_error], ProtocolError),
            {stop, response(Code, json_encode(ResBody, St1), true, Req1, St1), St1#state{
                error = ProtocolError
            }};
        Type:Reason:Stack ->
            %% Unexpected crash
            ErrId = erlang:unique_integer(),
            ?LOG_ERROR(
                #{
                    tag => graphql_crash,
                    id => ErrId,
                    type => Type,
                    reason => Reason,
                    stack => Stack
                },
                #{domain => ?LOG_DOMAIN}
            ),
            ResBody = #{
                <<"errors">> =>
                    [
                        cowboy_graphql:graphql_error(
                            <<"internal_error">>, [], #{error_id => integer_to_binary(ErrId)}
                        )
                    ]
            },
            {stop,
                cowboy_req:reply(
                    500,
                    #{<<"content-type">> => <<"application/json">>},
                    json_encode(ResBody, St0),
                    Req0
                ),
                St0#state{error = {crash, Type, {?MODULE, Reason, Stack}}}}
    end.

terminate(normal, _PartialReq, #state{cb = Callback, cb_state = CallbackState, error = Err}) when
    Err =/= undefined
->
    ok = cowboy_graphql:call_terminate(Callback, Err, CallbackState);
terminate(Reason, _PartialReq, #state{cb = Callback, cb_state = CallbackState}) ->
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

execute(Req0, #state{cb = Callback, cb_state = CallbackState0} = St0) ->
    {HttpMethod, PayloadLocation, {RespTypeName, _, _} = RespType} = negotiate(Req0, St0),
    TransportInfo =
        {http, #{
            method => HttpMethod, payload_type => PayloadLocation, response_type => RespTypeName
        }},
    {ok, _Extra, CallbackState1} = cowboy_graphql:call_init(
        Callback, #{}, TransportInfo, CallbackState0
    ),
    {Req1, St1, Payload} = parse_payload(HttpMethod, PayloadLocation, Req0, St0),
    {OpName, Doc, Vars, Ext} = decode(Payload, Req1, St1),
    case
        cowboy_graphql:call_handle_request(
            Callback, ?REQ_ID, OpName, Doc, Vars, Ext, CallbackState1
        )
    of
        {noreply, CallbackState} ->
            %% TODO: long-polling
            %% https://ninenines.eu/docs/en/cowboy/2.9/guide/loop_handlers/
            {loop, Req1, St1#state{cb_state = CallbackState, resp_method = RespType}};
        {reply, Rep, CallbackState} ->
            {reply, Rep, Req1, St1#state{cb_state = CallbackState, resp_method = RespType}};
        {error, Reason, CallbackState} ->
            throw_err(Req1, {callback, St1#state{cb_state = CallbackState}, Reason})
    end.

negotiate(Req, #state{} = St) ->
    {ReqMethod, ReqBodyLoc} = negotiate_req(Req, St),
    RespMethod = negotiate_resp(Req, St),
    {ReqMethod, ReqBodyLoc, RespMethod}.

negotiate_req(
    Req,
    #state{
        opts = #{max_body_size := MaxSize, accept_body := Accepts},
        methods = AllowedMethods,
        inputs = Inputs
    } = St
) ->
    Method = cowboy_req:method(Req),
    lists:member(Method, AllowedMethods) orelse
        throw_err(Req, err(St, method_not_allowed)),
    case Method of
        <<"GET">> ->
            case cowboy_req:qs(Req) of
                <<>> ->
                    throw_err(Req, err(St, missing_query_string));
                Bin when byte_size(Bin) > MaxSize ->
                    throw_err(Req, err(St, request_too_large));
                _ ->
                    {get, query_string}
            end;
        <<"POST">> ->
            case {cowboy_req:has_body(Req), cowboy_req:body_length(Req)} of
                {_, Size} when is_integer(Size), Size > MaxSize ->
                    throw_err(Req, err(St, request_too_large));
                {false, _} ->
                    throw_err(Req, err(St, missing_request_body));
                _ ->
                    ok
            end,
            {post,
                case cowboy_req:parse_header(<<"content-type">>, Req) of
                    {Type, Subtype, _} ->
                        maps:get({Type, Subtype}, Inputs, hd(Accepts));
                    undefined ->
                        hd(Accepts)
                end}
    end.

negotiate_resp(Req, #state{outputs = Outputs}) ->
    %% Simplified "accept" matching; example of the more complex one can be found in
    %% cowboy_rest:content_types_provided/2, but we will use simpler one
    Accepts = cowboy_req:parse_header(<<"accept">>, Req, []),
    PrioAccepts = lists:sort(fun({_, WL, _}, {_, WR, _}) -> WL >= WR end, Accepts),
    Choosen =
        case
            lists:filtermap(
                fun({{T, S, _}, _, _}) ->
                    case lists:keyfind({T, S}, 1, Outputs) of
                        false -> false;
                        {_, _} = Res -> {true, Res}
                    end
                end,
                PrioAccepts
            )
        of
            [{_, _} = Found | _] ->
                Found;
            [] ->
                hd(Outputs)
        end,
    case Choosen of
        {{N, V}, json} ->
            {json, <<N/binary, "/", V/binary>>, undefined};
        {{N, V}, multipart} ->
            Boundary = cow_multipart:boundary(),
            {multipart, <<N/binary, "/", V/binary, ";boundary=", Boundary/binary>>, Boundary}
    end.

parse_payload(get, query_string, Req, St) ->
    try cowboy_req:parse_qs(Req) of
        KV -> {Req, St, maps:from_list(KV)}
    catch
        exit:{request_error, qs, Reason} when is_atom(Reason) ->
            throw_err(
                Req,
                err(
                    St,
                    invalid_query_string,
                    atom_to_binary(Reason, utf8),
                    #{input => cowboy_req:qs(Req)}
                )
            )
    end;
parse_payload(
    post, x_www_form_urlencoded, Req0, #state{opts = #{max_body_size := MaxSize}} = St
) ->
    {ok, KV, Req1} = cowboy_req:read_urlencoded_body(Req0, #{length => MaxSize}),
    {Req1, St, maps:from_list(KV)};
parse_payload(post, json, Req0, #state{opts = #{max_body_size := MaxSize}} = St) ->
    {ok, ReqBody, Req1} = cowboy_req:read_body(Req0, #{length => MaxSize}),
    KV = json_decode(ReqBody, St),
    {Req1, St, KV}.

decode(#{<<"query">> := Doc} = Data, _Req, St) when is_binary(Doc) ->
    Vars = maps:get(<<"variables">>, Data, #{}),
    OpName = maps:get(<<"operationName">>, Data, undefined),
    Extensions = maps:get(<<"extensions">>, Data, #{}),
    DocStr = unicode:characters_to_list(Doc),
    ParseMap = fun
        (V) when is_binary(V) ->
            json_decode(V, St);
        (V) when is_map(V) ->
            V
    end,
    {OpName, DocStr, ParseMap(Vars), ParseMap(Extensions)};
decode(_, Req, St) ->
    throw_err(
        Req,
        err(
            St,
            missing_parameter,
            <<"Parameter 'query' is mandatory">>,
            #{parameter => query}
        )
    ).

-spec response(cowboy_graphql:result(), cowboy_req:req(), #state{}) ->
    {ok, cowboy_req:req(), #state{}}
    | {stop, cowboy_req:req(), #state{}}.
response({?REQ_ID, true, Data, Errors, Extensions}, Req, #state{resp_method = {json, _, _}} = St) ->
    Result0 = cowboy_graphql:put_not_empty(<<"data">>, Data, #{}),
    Result1 = cowboy_graphql:put_not_empty(<<"extensions">>, Extensions, Result0),
    Result = cowboy_graphql:put_not_empty(<<"errors">>, Errors, Result1),
    response(200, json_encode(Result, St), true, Req, St);
response(
    {_, false, _, _, _} = Resp,
    Req,
    #state{resp_method = {json, _, _}, cb = Callback, cb_state = CbState0} = St
) ->
    %% force-cancel the request because `json' method only supports single reply
    {noreply, CbState} = cowboy_graphql:call_handle_cancel(
        Callback, ?REQ_ID, CbState0
    ),
    response(setelement(2, Resp, true), Req, St#state{cb_state = CbState});
response(
    {?REQ_ID, Done, Data, Errors, Extensions}, Req, #state{resp_method = {multipart, _, _}} = St
) ->
    Result0 = cowboy_graphql:put_not_empty(<<"data">>, Data, #{}),
    Result1 = cowboy_graphql:put_not_empty(<<"extensions">>, Extensions, Result0),
    Result = cowboy_graphql:put_not_empty(<<"errors">>, Errors, Result1),
    Body = json_encode(Result, St),
    response(200, Body, Done, Req, St).

-spec response(100..999, iodata(), boolean(), cowboy_req:req(), #state{}) ->
    {ok, cowboy_req:req(), #state{}}
    | {stop, cowboy_req:req(), #state{}}.
response(Code, Body, true, Req, #state{resp_method = {json, Hdr, _}, headers_sent = false} = St) ->
    {stop, cowboy_req:reply(Code, #{<<"content-type">> => Hdr}, Body, Req), St};
response(
    Code,
    Body,
    Done,
    Req0,
    #state{
        resp_method = {multipart, Hdr, Boundary},
        headers_sent = HdrsSent
    } = St
) ->
    {Req1, St1} =
        case HdrsSent of
            true ->
                {Req0, St};
            false ->
                {cowboy_req:stream_reply(Code, #{<<"content-type">> => Hdr}, Req0), St#state{
                    headers_sent = true
                }}
        end,
    Chunk = cow_multipart:part(Boundary, [
        {<<"content-type">>, <<"application/json; charset=utf-8">>}
    ]),
    case Done of
        true ->
            Close = cow_multipart:close(Boundary),
            ok = cowboy_req:stream_body([Chunk, Body | Close], fin, Req1),
            {stop, Req1, St1};
        false ->
            ok = cowboy_req:stream_body([Chunk, Body], nofin, Req1),
            {ok, Req1, St1}
    end;
response(Code, Body, true, Req, #state{resp_method = undefined, headers_sent = false} = St) ->
    %% Error before protocol negotiation is done
    {stop, cowboy_req:reply(Code, #{<<"content-type">> => <<"application/json">>}, Body, Req), St}.

format_error(Allowed, Err) ->
    lists:member(element(1, Err), Allowed) orelse
        ?LOG_ERROR(
            #{label => unexpected_error, error => Err, allowed => Allowed},
            #{domain => ?LOG_DOMAIN}
        ),
    {Code, ErrMap} = format_error(Err),
    {Code, #{<<"errors">> => [ErrMap]}}.

format_error({request_error, _Id, GraphqlError}) ->
    {200, GraphqlError};
format_error({auth_error, Msg, Extra}) ->
    {403, cowboy_graphql:graphql_error(Msg, [], Extra#{code => authentication_error})};
format_error({other_error, Msg, Extra}) ->
    {400, cowboy_graphql:graphql_error(Msg, [], Extra)};
format_error({protocol_error, http, Code, Msg, Extra}) ->
    FullMsg = unicode:characters_to_binary(["Http processing error: ", Msg]),
    {400, cowboy_graphql:graphql_error(FullMsg, [], Extra#{code => Code})}.

err(State, Kind, Msg, Extra) ->
    {
        ?MODULE,
        State,
        cowboy_graphql:protocol_error(http, Kind, Msg, Extra)
    }.

err(State, Tag) when is_atom(Tag) ->
    {
        ?MODULE,
        State,
        cowboy_graphql:protocol_error(http, Tag, atom_to_binary(Tag, utf8), #{})
    }.

throw_err(Req, Err) ->
    throw({Err, Req}).

json_decode(Json, #state{json_decode = Decode}) ->
    Decode(Json).

json_encode(Obj, #state{json_encode = Encode}) ->
    Encode(Obj).

reset_heartbeat(
    #state{
        resp_method = {multipart, _, _},
        opts = #{heartbeat := Timeout},
        heartbeat_ref = OldRef
    } = St
) when is_integer(Timeout) ->
    case is_reference(OldRef) of
        true ->
            erlang:cancel_timer(OldRef);
        false ->
            noop
    end,
    Ref = erlang:send_after(Timeout, self(), {?MODULE, heartbeat}),
    St#state{heartbeat_ref = Ref};
reset_heartbeat(St) ->
    St.

start_timeout(#state{opts = #{timeout := Timeout}} = St) when is_integer(Timeout), Timeout > 0 ->
    %% No need to save the reference since it is not cancellable
    erlang:send_after(Timeout, self(), {?MODULE, timeout}),
    St;
start_timeout(St) ->
    St.
