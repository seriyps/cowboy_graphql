-module(cowboy_graphql).

-export([
    graphql_error/3,
    request_validation_error/2,
    auth_error/2,
    other_error/2,
    http_config/3,
    ws_config/3
]).

-export([
    call_connection/3,
    call_init/4,
    call_handle_request/7,
    call_handle_cancel/3,
    call_handle_info/3,
    call_terminate/3
]).

%% Internal helpers
-export([put_not_empty/3, protocol_error/4]).

-export_type([
    result/0,
    error/0,
    request_validation_error/0,
    auth_error/0,
    protocol_error/0,
    other_error/0,
    graphql_error/0
]).
-export_type([
    json_object/0,
    json/0
]).

-type json() :: json_object() | json_array() | json_scalar().
-type json_object() :: #{json_string() => json()}.
-type json_array() :: [json()].
-type json_scalar() :: json_string() | integer() | float() | boolean() | null.
-type json_string() :: unicode:unicode_binary().

-type request_id() :: binary().
-type handler_state() :: any().

-type error() ::
    request_validation_error()
    | auth_error()
    | protocol_error()
    | other_error().
%% Only types of error which are allowed to be returned from callbacks.

-type request_validation_error() :: {request_error, request_id(), graphql_error()}.
%% Errors in GraphQL execution which happened before the actual execution have started,
%% eg. during syntax / semantics / datatype validation.
%% Errors generated during GraphQL "field resolve" phase are returned as `{ok, #{errors => [..]}}'

-type auth_error() :: {auth_error, Msg :: unicode:chardata() | atom(), Extra :: json_object()}.
%% Authentication errors. Should only happen in `connect' and `init' callbacks.

-type protocol_error() ::
    {protocol_error, Transport :: http | ws, Code :: atom(), Msg :: unicode:chardata(),
        Extra :: json_object()}.
%% Errors in transport protocols (malformed HTTP / WS requests and packets).
%% Normally generated internally by protocol handlers, but may be produced by `connect' callback as
%% result of validation of `Req' parameter.

-type other_error() :: {other_error, Msg :: unicode:chardata(), Extra :: json_object()}.
%% Errors not matching any other category.

-type error_location() :: #{
    line => pos_integer(),
    column => pos_integer()
}.
-type graphql_error() :: #{
    message := unicode:unicode_binary(),
    locations => [error_location()],
    path => [unicode:unicode_binary() | non_neg_integer()],
    extensions => json_object()
}.
-type result() :: {
    Id :: request_id(),
    Done :: boolean(),
    Data :: json_object() | undefined,
    Errors :: [graphql_error()],
    Extensions :: json_object()
}.

-type transport_info() ::
    {ws, cowboy_graphql_ws_handler:features()}
    | {http, cowboy_graphql_http_handler:features()}.

-callback connection(cowboy_req:req(), Params :: any()) ->
    {ok, handler_state()}
    | {error, auth_error() | protocol_error() | other_error()}.
%% Is called when the HTTP/WS connection is just happened, before body is fetched.
%% Not guaranteed to be executed from the same process as all the other callbacks.
%% Use it to create the initial state and maybe analyze some data from cowboy's request object,
%% perform authentication.
%% Don't use cowboy_req methods that modify the request (eg, don't read the body!).
%% Better not to start any timers / spawn processes / open resources / use process dict etc.

-callback init(
    Params :: json_object(),
    TransportInfo :: transport_info(),
    State :: handler_state()
) ->
    {ok, Params :: json_object(), handler_state()}
    | {error, auth_error() | other_error(), handler_state()}.
%% Is called when `connection_init' is received via WebSocket or immediately after `connection/2'
%% when over HTTP.

-callback handle_request(
    Id :: request_id(),
    OperationName :: binary() | undefined,
    Query :: unicode:chardata(),
    Variables :: json_object(),
    Extensions :: json_object(),
    State :: handler_state()
) ->
    {noreply, handler_state()}
    | {reply, result() | [result()], handler_state()}
    | {error, request_validation_error() | other_error(), handler_state()}.
%% Is called when GraphQL request (query / mutation / subscription) is received. Callback
%% supposed to execute the request and either return the response immediately OR run it in
%% background / initialize subscription and return `noreply'

-callback handle_cancel(Id :: binary(), handler_state()) ->
    {noreply, handler_state()}
    | {error, other_error(), handler_state()}.
%% Is called when operation is cancelled by the client. Callback is supposed to abort the execution
%% of the running query / mutation or stop the subscription identified by ID.

-callback handle_info(Msg :: any(), State :: handler_state()) ->
    {noreply, handler_state()}
    | {reply, result() | [result()], handler_state()}
    | {error, other_error(), handler_state()}.
%% Is called when Erlang process, executing the request, received a regular Erlang message.
%% For example, payload from subscription channel.

-callback terminate(
    Reason :: normal | atom() | tuple(),
    State :: handler_state()
) ->
    ok.
%% Is called when client have disconnected or about to disconnect, current erlang process is
%% about to terminate. Not guaranteed to be called!
%% Reason - see [[https://ninenines.eu/docs/en/cowboy/2.9/manual/cowboy_websocket/]]

%% =========================
%% APIs
%%

%% @doc Generate HTTP handler's cowboy_router "InitialState".
%%
%% Usage:
%% ```
%% Routes = [
%%   ...,
%%   {"/api/graphql/http",
%%    cowboy_graphql_http_handler,
%%    cowboy_graphql:http_config(my_graphql_handler, MyOpts, #{max_body_size => 5 * 1024 * 1024})},
%%   ...
%% ]
%% '''
%%
%% See [[https://ninenines.eu/docs/en/cowboy/2.9/manual/cowboy_router/]]
-spec http_config(module(), any(), cowboy_graphql_http_handler:options()) ->
    cowboy_graphql_http_handler:config().
http_config(Callback, CallbackOpts, TransportOpts) ->
    cowboy_graphql_http_handler:config(Callback, CallbackOpts, TransportOpts).

%% @doc Generate WebSocket handler's cowboy_router "InitialState".
%%
%% Usage:
%% ```
%% Routes = [
%%   ...,
%%   {"/api/graphql/websocket",
%%    cowboy_graphql_ws_handler,
%%    cowboy_graphql:ws_config(my_graphql_handler, MyOpts, #{max_body_size => 5 * 1024 * 1024})},
%%   ...
%% ]
%% '''
%%
%% See [[https://ninenines.eu/docs/en/cowboy/2.9/manual/cowboy_router/]]
-spec ws_config(module(), any(), cowboy_graphql_ws_handler:options()) ->
    cowboy_graphql_ws_handler:config().
ws_config(Callback, CallbackOpts, TransportOpts) ->
    cowboy_graphql_ws_handler:config(Callback, CallbackOpts, TransportOpts).

%% @doc Creates an `execution_error()' structure
-spec graphql_error(unicode:chardata(), [error_location()], map()) -> graphql_error().
graphql_error(Message, Locations, Extensions) when
    is_list(Message) orelse is_binary(Message),
    is_list(Locations),
    is_map(Extensions)
->
    Err0 = #{message => unicode:characters_to_binary(Message)},
    Err1 =
        case Locations of
            [] ->
                Err0;
            _ ->
                Err0#{
                    locations =>
                        lists:map(
                            fun(Loc) when is_map(Loc) ->
                                maps:with([line, column], Loc)
                            end,
                            Locations
                        )
                }
        end,
    case map_size(Extensions) of
        0 ->
            Err1;
        _ ->
            Str = fun
                (L) when is_list(L) -> unicode:characters_to_binary(L);
                (A) when is_atom(A) -> atom_to_binary(A, utf8);
                (B) when is_binary(B) -> B
            end,
            Err1#{
                extensions =>
                    maps:from_list([{Str(K), V} || {K, V} <- maps:to_list(Extensions)])
            }
    end.

-spec request_validation_error(request_id(), graphql_error()) -> request_validation_error().
request_validation_error(Id, #{message := _} = Extra) ->
    {request_error, Id, Extra}.

-spec auth_error(unicode:chardata(), map()) -> auth_error().
auth_error(Msg, Extra) ->
    {auth_error, Msg, Extra}.

-spec other_error(unicode:chardata(), map()) -> other_error().
other_error(Msg, Extra) ->
    {other_error, Msg, Extra}.

-spec protocol_error(ws | http, atom(), unicode:chardata(), map()) -> protocol_error().
protocol_error(Transport, Code, Msg, Extra) when
    is_atom(Code),
    Transport == ws orelse Transport == http
->
    {protocol_error, Transport, Code, Msg, Extra}.

%%
%% Internal helpers
%%

%% @private
-spec put_not_empty(json_string(), json() | undefined, json_object()) -> json_object().
put_not_empty(Key, What, Where) ->
    case is_empty(What) of
        true ->
            Where;
        false ->
            Where#{Key => What}
    end.

is_empty(Map) when map_size(Map) =:= 0 ->
    true;
is_empty([]) ->
    true;
is_empty(undefined) ->
    true;
is_empty(null) ->
    true;
is_empty(_) ->
    false.

%%
%% Behaviour helpers
%%

%% @private
-spec call_connection(Mod :: module(), cowboy_req:req(), Params :: any()) ->
    {ok, handler_state()}
    | {error, auth_error() | protocol_error() | other_error()}.
call_connection(Mod, Req, Params) ->
    Mod:connection(Req, Params).

%% @private
-spec call_init(
    Mod :: module(),
    Params :: json_object(),
    TransportInfo :: transport_info(),
    State :: handler_state()
) ->
    {ok, Params :: json_object(), handler_state()}
    | {error, auth_error() | other_error(), handler_state()}.
call_init(Mod, Params, TransportInfo, State) ->
    Mod:init(Params, TransportInfo, State).

%% @private
-spec call_handle_request(
    Mod :: module(),
    Id :: binary(),
    OperationName :: binary() | undefined,
    Query :: unicode:chardata(),
    Variables :: json_object(),
    Extensions :: json_object(),
    State :: handler_state()
) ->
    {noreply, handler_state()}
    | {reply, result() | [result()], handler_state()}
    | {error, request_validation_error() | other_error(), handler_state()}.
call_handle_request(Mod, Id, OperationName, Query, Variables, Extensions, State) ->
    Mod:handle_request(Id, OperationName, Query, Variables, Extensions, State).

%% @private
-spec call_handle_cancel(Mod :: module(), Id :: binary(), handler_state()) ->
    {noreply, handler_state()}
    | {error, other_error(), handler_state()}.
call_handle_cancel(Mod, Id, State) ->
    Mod:handle_cancel(Id, State).

%% @private
-spec call_handle_info(Mod :: module(), Msg :: any(), State :: handler_state()) ->
    {noreply, handler_state()}
    | {reply, result() | [result()], handler_state()}
    | {error, other_error(), handler_state()}.
call_handle_info(Mod, Msg, State) ->
    Mod:handle_info(Msg, State).

%% @private
-spec call_terminate(
    Mod :: module(),
    Reason :: normal | atom() | tuple(),
    State :: handler_state()
) ->
    ok.
call_terminate(Mod, Reason, State) ->
    Mod:terminate(Reason, State).
