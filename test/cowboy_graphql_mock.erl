-module(cowboy_graphql_mock).
-behaviour(cowboy_graphql).

-export([start/1, stop/0, port/0, publish/4, publish_request_error/3, sync/1]).

-export([connection/2, init/3, handle_request/6, handle_cancel/2, handle_info/2, terminate/2]).

-record(state, {extra, headers, subscriptions = [], transport_info}).

port() ->
    8881.

start(Opts) ->
    Routes = lists:map(fun routes/1, maps:get(transports, Opts, [{http, #{}}, {ws, #{}}])),
    Dispatch = cowboy_router:compile([{'_', Routes}]),
    {ok, _} = cowboy:start_clear(
        ?MODULE,
        #{
            max_connections => 128,
            socket_opts => [{port, port()}]
        },
        #{env => #{dispatch => Dispatch}}
    ).

routes({http, Opts}) ->
    {"/api/:on_connect", cowboy_graphql_http_handler,
        cowboy_graphql:http_config(?MODULE, [opts], Opts#{json_mod => jsx})};
routes({ws, Opts}) ->
    {"/api/:on_connect/websocket", cowboy_graphql_ws_handler,
        cowboy_graphql:ws_config(?MODULE, [opts], Opts#{json_mod => jsx})}.

stop() ->
    cowboy:stop_listener(?MODULE).

publish(Conn, Id, Extra, Done) ->
    whereis(Conn) ! {?FUNCTION_NAME, self(), Id, Extra, Done},
    receive
        {ack, Id} ->
            ok
    after 5000 ->
        error(timeout)
    end.

publish_request_error(Conn, Id, Msg) ->
    whereis(Conn) ! {?FUNCTION_NAME, self(), Id, Msg},
    receive
        {ack, Id} ->
            ok
    after 5000 ->
        error(timeout)
    end.

sync(Conn) ->
    Ref = erlang:monitor(process, Conn),
    whereis(Conn) ! {sync, self(), Ref},
    receive
        {sync, Ref} ->
            erlang:demonitor(Ref),
            ok;
        Other ->
            error({bad_msg, Other})
    after 5000 ->
        error(timeout)
    end.

%%
%% Callbacks
%%

connection(Req, [opts]) ->
    case cowboy_req:binding(on_connect, Req) of
        <<"ok--", Extra/binary>> ->
            Headers = cowboy_req:headers(Req),
            {ok, #state{extra = Extra, headers = Headers}};
        <<"auth-error--", Reason/binary>> ->
            {error, cowboy_graphql:auth_error(Reason, #{})};
        <<"error--", Reason/binary>> ->
            {error, cowboy_graphql:other_error(Reason, #{})}
    end.

init(#{}, TransportInfo, #state{} = St) ->
    {ok, #{}, St#state{transport_info = TransportInfo}}.

handle_request(Id, <<"subscribe">>, Query, Vars, Extensions, #state{subscriptions = Subs} = St) ->
    RegAtom = binary_to_atom(unicode:characters_to_binary(Query)),
    true = register(RegAtom, self()),
    {noreply, St#state{subscriptions = [{Id, Query, Vars, Extensions} | Subs]}};
handle_request(Id, <<"echo">>, Query, Vars, Extensions, #state{} = St) ->
    Result =
        {Id, true,
            #{
                <<"query">> => unicode:characters_to_binary(Query),
                <<"vars">> => Vars,
                <<"extensions">> => Extensions
            },
            [], #{}},
    {reply, Result, St};
handle_request(Id, <<"data-and-errors">>, Query, Vars, Extensions, St) ->
    Result =
        {Id, true,
            #{
                <<"query">> => unicode:characters_to_binary(Query),
                <<"vars">> => Vars,
                <<"extensions">> => Extensions
            },
            [cowboy_graphql:graphql_error(Query, [], Vars)], #{}},
    {reply, Result, St};
handle_request(Id, <<"error-request-validation">>, Query, Vars, _Extensions, St) ->
    GQLError = cowboy_graphql:graphql_error(Query, [], Vars),
    Err = cowboy_graphql:request_validation_error(Id, GQLError),
    {error, Err, St};
handle_request(_Id, <<"error-other">>, Query, Vars, _Extensions, St) ->
    Err = cowboy_graphql:other_error(Query, Vars),
    {error, Err, St};
handle_request(Id, <<"crash">>, Query, _Vars, _Extensions, _St) ->
    error({Id, Query}).

handle_cancel(Id, #state{subscriptions = Subs0} = St) ->
    Subs = lists:keydelete(Id, 1, Subs0),
    {noreply, St#state{subscriptions = Subs}}.

handle_info({publish, From, Id, Extra, Done}, #state{subscriptions = Subs} = St) ->
    {value, {Id, Query, Vars, Extensions}} = lists:keysearch(Id, 1, Subs),
    Result =
        {Id, Done,
            #{
                <<"query">> => unicode:characters_to_binary(Query),
                <<"vars">> => Vars,
                <<"extensions">> => Extensions,
                <<"extra">> => Extra
            },
            [], #{}},
    From ! {ack, Id},
    {reply, Result, St};
handle_info({publish_request_error, From, Id, Msg}, #state{subscriptions = Subs} = St) ->
    {value, {Id, Query, Vars, Extensions}} = lists:keysearch(Id, 1, Subs),
    GQLError = cowboy_graphql:graphql_error(
        Msg, [], #{
            query => unicode:characters_to_binary(Query),
            vars => Vars,
            exts => Extensions
        }
    ),
    Err = cowboy_graphql:request_validation_error(Id, GQLError),
    From ! {ack, Id},
    {error, Err, St};
handle_info({sync, From, Ref}, St) ->
    From ! {sync, Ref},
    {noreply, St};
handle_info(_Msg, St) ->
    {noreply, St}.

terminate(normal, _State) ->
    ok;
terminate(R, _State) when
    element(1, R) == remote andalso element(2, R) == 1000;
    element(1, R) == request_error
->
    ok;
terminate(_Reason, #state{}) ->
    ok.
