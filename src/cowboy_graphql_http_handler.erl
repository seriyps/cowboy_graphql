%%% @author Sergey <me@seriyps.ru>
%%% @copyright (C) 2021, Sergey
%%% @doc
%%% Cowboy HTTP handler for graphql API
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
    methods :: ordsets:ordset(binary()),
    inputs :: #{{binary(), binary()} => input_content_type()},
    opts :: options(),
    error :: undefined | tuple(),
    req :: cowboy_req:req()
}).

%% -type json_object() :: tm_graphql_ws_handler:json_object().
-type input_content_type() :: json | x_www_form_urlencoded.
-type options() :: #{
    accept_body => [input_content_type()],
    allowed_methods => [post | get],
    json_mod => module(),
    max_body_size => pos_integer()
}.
-opaque config() :: {module(), any(), options()}.

-type features() :: #{
    method => post | get,
    payload_type => query_string | input_content_type()
}.

-define(INPUT_CT_MAP, #{
    json => [{<<"application">>, <<"json">>}, {<<"text">>, <<"json">>}],
    x_www_form_urlencoded => [{<<"application">>, <<"x-www-form-urlencoded">>}]
}).
-define(METHOD_MAP, #{
    get => <<"GET">>,
    post => <<"POST">>
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
        allowed_methods => [post, get],
        json_mod => jsx,
        max_body_size => 5 * 1024 * 1024
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
            do(Req, Callback, CbState, Params)
    end.

info(Msg, Req0, #state{cb = Callback, cb_state = CallbackState0} = St) ->
    case cowboy_graphql:call_handle_info(Callback, Msg, CallbackState0) of
        {noreply, CallbackState} ->
            {ok, Req0, St#state{cb_state = CallbackState}};
        {reply, {?REQ_ID, Done, Data, Errors, Extensions}, CallbackState1} ->
            Result0 = cowboy_graphql:put_not_empty(<<"data">>, Data, #{}),
            Result1 = cowboy_graphql:put_not_empty(<<"extensions">>, Extensions, Result0),
            Result = cowboy_graphql:put_not_empty(<<"errors">>, Errors, Result1),
            CallbackState =
                case Done of
                    true ->
                        CallbackState1;
                    false ->
                        {noreply, CallbackState_} = cowboy_graphql:call_handle_cancel(
                            Callback, ?REQ_ID, CallbackState1
                        ),
                        CallbackState_
                end,
            Req = cowboy_req:reply(
                200,
                #{<<"content-type">> => <<"application/json">>},
                json_encode(Result, St),
                Req0
            ),
            {stop, Req, St#state{cb_state = CallbackState}};
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
                cowboy_req:reply(
                    Code,
                    #{<<"content-type">> => <<"application/json">>},
                    json_encode(ResBody, St),
                    Req0
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
    St0 = #state{
        cb = Callback,
        cb_state = CbState,
        json_encode = fun JsonMod:encode/1,
        json_decode = fun JsonMod:decode/1,
        methods = ordsets:from_list([maps:get(M, ?METHOD_MAP) || M <- AllowedMethods]),
        inputs = Inputs,
        opts = Params,
        req = Req0
    },
    RespHeaders = #{<<"content-type">> => <<"application/json">>},
    try execute(St0) of
        {ok, ResBody, #state{req = Req1} = St1} ->
            ?LOG_DEBUG(#{tag => graphql_success, result => ResBody}, #{domain => ?LOG_DOMAIN}),
            {ok, cowboy_req:reply(200, RespHeaders, json_encode(ResBody, St1), Req1), St1};
        {loop, #state{req = Req1} = St1} ->
            {cowboy_loop, Req1, St1}
    catch
        throw:{callback, #state{req = Req1} = St1, Error} ->
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
            {ok, cowboy_req:reply(Code, RespHeaders, json_encode(ResBody, St1), Req1), St1#state{
                error = Error
            }};
        throw:{?MODULE, #state{req = Req1} = St1, ProtocolError} when is_tuple(ProtocolError) ->
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
            {ok, cowboy_req:reply(Code, RespHeaders, json_encode(ResBody, St1), Req1), St1#state{
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
            {ok, cowboy_req:reply(500, RespHeaders, json_encode(ResBody, St0), Req0), St0#state{
                error = {crash, Type, {?MODULE, Reason, Stack}}
            }}
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

execute(#state{cb = Callback, cb_state = CallbackState0} = St0) ->
    {HttpMethod, PayloadLocation} = negotiate(St0),
    TransportInfo = {http, #{method => HttpMethod, payload_type => PayloadLocation}},
    {ok, _Extra, CallbackState1} = cowboy_graphql:call_init(
        Callback, #{}, TransportInfo, CallbackState0
    ),
    {St1, Payload} = parse_payload(HttpMethod, PayloadLocation, St0),
    {OpName, Doc, Vars, Ext} = decode(Payload, St1),
    Id = ?REQ_ID,
    case cowboy_graphql:call_handle_request(Callback, Id, OpName, Doc, Vars, Ext, CallbackState1) of
        {noreply, CallbackState} ->
            %% TODO: long-polling
            %% https://ninenines.eu/docs/en/cowboy/2.9/guide/loop_handlers/
            {loop, St1#state{cb_state = CallbackState}};
        {reply, {Id, true, Data, Errors, Extensions}, CallbackState} ->
            Result0 = cowboy_graphql:put_not_empty(<<"data">>, Data, #{}),
            Result1 = cowboy_graphql:put_not_empty(<<"extensions">>, Extensions, Result0),
            Result = cowboy_graphql:put_not_empty(<<"errors">>, Errors, Result1),
            {ok, Result, St1#state{cb_state = CallbackState}};
        {error, Reason, CallbackState} ->
            throw({callback, St1#state{cb_state = CallbackState}, Reason})
    end.

negotiate(
    #state{
        opts = #{max_body_size := MaxSize, accept_body := Accepts},
        methods = AllowedMethods,
        inputs = Inputs,
        req = Req
    } = St
) ->
    Method = cowboy_req:method(Req),
    lists:member(Method, AllowedMethods) orelse
        throw(err(St, method_not_allowed)),
    case Method of
        <<"GET">> ->
            case cowboy_req:qs(Req) of
                <<>> ->
                    throw(err(St, missing_query_string));
                Bin when byte_size(Bin) > MaxSize ->
                    throw(err(St, request_too_large));
                _ ->
                    {get, query_string}
            end;
        <<"POST">> ->
            case {cowboy_req:has_body(Req), cowboy_req:body_length(Req)} of
                {_, Size} when is_integer(Size), Size > MaxSize ->
                    throw(err(St, request_too_large));
                {false, _} ->
                    throw(err(St, missing_request_body));
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

parse_payload(get, query_string, #state{req = Req} = St) ->
    try cowboy_req:parse_qs(Req) of
        KV -> {St, maps:from_list(KV)}
    catch
        exit:{request_error, qs, Reason} when is_atom(Reason) ->
            throw(
                err(
                    St,
                    invalid_query_string,
                    atom_to_binary(Reason, utf8),
                    #{input => cowboy_req:qs(Req)}
                )
            )
    end;
parse_payload(
    post, x_www_form_urlencoded, #state{req = Req0, opts = #{max_body_size := MaxSize}} = St
) ->
    {ok, KV, Req1} = cowboy_req:read_urlencoded_body(Req0, #{length => MaxSize}),
    {St#state{req = Req1}, maps:from_list(KV)};
parse_payload(post, json, #state{req = Req0, opts = #{max_body_size := MaxSize}} = St) ->
    {ok, ReqBody, Req1} = cowboy_req:read_body(Req0, #{length => MaxSize}),
    KV = json_decode(ReqBody, St),
    {St#state{req = Req1}, KV}.

decode(#{<<"query">> := Doc} = Data, St) when is_binary(Doc) ->
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
decode(_, St) ->
    throw(
        err(
            St,
            missing_parameter,
            <<"Parameter 'query' is mandatory">>,
            #{parameter => query}
        )
    ).

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

json_decode(Json, #state{json_decode = Decode}) ->
    Decode(Json).

json_encode(Obj, #state{json_encode = Encode}) ->
    Encode(Obj).
