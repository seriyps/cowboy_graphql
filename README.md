cowboy_graphql
=====

Generic graphql HTTP and websocket transports for Cowboy.

It supports following transport protocols:

* HTTP POST application/x-www-form-urlencoded
* HTTP [POST application/json](https://github.com/graphql/graphql-over-http/blob/main/spec/GraphQLOverHTTP.md#post)
* HTTP [GET with data passed as URL query string](https://github.com/graphql/graphql-over-http/blob/main/spec/GraphQLOverHTTP.md#get)
* WebSocket [graphql_ws](https://github.com/enisdenjo/graphql-ws/blob/master/PROTOCOL.md)
* WebSocket [apollo](https://github.com/apollographql/subscriptions-transport-ws/blob/master/PROTOCOL.md)

It supports both request-response as well as subscriptions.
It does not dictate the specific GraphQL executor implementation (however,
https://github.com/jlouis/graphql-erlang is assumed).

The idea is to define a `cowboy_graphql` behaviour callback module and the same code can be used for
any transport protocol.


Callback module
-----

The `cowboy_graphql` behaviour module have to implement following callbacks.

### `connection`

```erlang
connection(cowboy_req:req(), Params :: any()) ->
    {ok, handler_state()}
    | {error, auth_error() | protocol_error() | other_error()}.
```

Function is called when the initial HTTP request is received (HTTP headers for HTTP or
`Connection: Upgrade; Upgrade: websocket` request for HTTP).

This callback can be used to, eg, perform the authentication, inspect the HTTP headers, peer IP etc.

This module initiates the static fields in the state, however it is not guaranteed to be executed in
the same process as all the other callbacks. So, don't start timers/monitors in this callback.

### `init`

```erlang
init(Params :: json_object(), TransportInfo :: transport_info(), State :: handler_state()) ->
    {ok, Params :: json_object(), handler_state()}
    | {error, auth_error() | other_error(), handler_state()}.
```

Function is called when the connection is established (for HTTP - imediately after `connection`,
for WebSocket - when `ConnectionInit` message is received).

This callback can be used to set-up all the timers/monitors, register the process in process
registry etc.

### `handle_request`

```erlang
handle_request(
  request_id(),
  OperationName :: binary() | undefined,
  Query :: unicode:chardata(),
  Variables :: json_object(),
  Extensions :: json_object(),
  State :: handler_state()) ->
     {noreply, handler_state()}
   | {reply, result() | [result()], handler_state()}
   | {error, request_validation_error() | other_error(), handler_state()}.

-type result() :: {
    Id :: request_id(),
    Done :: boolean(),
    Data :: json_object() | undefined,
    Errors :: [graphql_error()],
    Extensions :: json_object()
}.
```

Is called when GraphQL query or subscription is received (for HTTP - we read and parse body,
for WebSocket - when `Subscribe` message received).

The actual GraphQL request should be parsed, validated and executed here.

This callback may either:
* return the result immediately
* initiate the subscription or execute request asynchronously (storing the `request_id()` as
  correlation key) and return the result(s) from `handle_info`

The `Done` flag of the `result()` signals whether the query is done producing results (should be
always `true` for `query` and `mutation`) or more results could be produced (for `subscription`).

### `handle_cancel`

```erlang
handle_cancel(Id :: binary(), handler_state()) ->
    {noreply, handler_state()}
    | {error, other_error(), handler_state()}.
```

Is called when client requested the subscription cancellation (for HTTP - see `handle_info`,
for WebSocket - when client sends `Complete`).

### `handle_info`

```erlang
handle_info(Msg :: any(), State :: handler_state()) ->
    {noreply, handler_state()}
    | {reply, result() | [result()], handler_state()}
    | {error, other_error(), handler_state()}.

```

Is called when the Erlang process that represents the connection receives regular messages from
other processes (eg, from pub-sub system).

**For HTTP transport** `reply` or `error` can be returned only once. If the `result()` has
`Done` flag set to `false`, `handle_cancel/2` will be called immediately for HTTP.
But we may add streaming over [SSE](https://html.spec.whatwg.org/multipage/server-sent-events.html)
later (if client signals `Accept: text/event-stream`).

### `terminate`

```erlang
-callback terminate(
    Reason :: normal | atom() | tuple(),
    State :: handler_state()
) -> ok.
```

Called when connection is about to be closed.

Cowboy configuration
-----

HTTP and WebSocket handlers should reside on different URLs.
Any protocol can be disabled.

```erlang
start() ->
  CallbackMod = my_cowboy_graphql_impl,
  Opts = #{..},  % options passed to `connection(_, Opts)`
  Routes = [
    {"/api/http", cowboy_graphql_http_handler,
        cowboy_graphql:http_config(
            CallbackMod, Opts, #{json_mod => jsx,
                                 accept_body => [json, x_www_form_urlencoded],
                                 allowed_methods => [post, get],
                                 max_body_size => 5 * 1024 * 1024})};
    {"/api/websocket", cowboy_graphql_ws_handler,
        cowboy_graphql:ws_config(
            CallbackMod, Opts, #{json_mod => jsx,
                                 protocols => [graphql_ws, apollo],
                                 max_frame_size => 5 * 1024 * 1024})}
  ],
  Dispatch = cowboy_router:compile([{'_', Routes}]),
  {ok, _} = cowboy:start_clear(
      ?MODULE,
      #{
          max_connections => 1024,
          socket_opts => [{port, 8080}]
      },
      #{env => #{dispatch => Dispatch}}
  ).

```
