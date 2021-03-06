%%%-------------------------------------------------------------------
%%% @copyright (C) 2011-2017, 2600Hz INC
%%% @doc
%%% API resource
%%% @end
%%% @contributors
%%%   Karl Anderson
%%%   James Aimonetti
%%%   Jon Blanton
%%%-------------------------------------------------------------------
-module(api_resource).

-export([init/3, rest_init/2
        ,terminate/2, rest_terminate/2
        ,known_methods/2
        ,allowed_methods/2
        ,malformed_request/2
        ,is_authorized/2
        ,forbidden/2
        ,valid_content_headers/2
        ,known_content_type/2
        ,valid_entity_length/2
        ,options/2
        ,content_types_provided/2
        ,content_types_accepted/2
        ,languages_provided/2
        ,charsets_provided/2
        ,resource_exists/2
        ,moved_temporarily/2
        ,moved_permanently/2
        ,previously_existed/2
        ,allow_missing_post/2
        ,delete_resource/2
        ,delete_completed/2
        ,is_conflict/2
        ,to_json/2, to_binary/2, to_csv/2, to_pdf/2, send_file/2
        ,from_json/2, from_binary/2, from_form/2
        ,multiple_choices/2
        ,generate_etag/2
        ,expires/2
        ,get_range/2
        ]).

-include("crossbar.hrl").

%%%===================================================================
%%% Startup and shutdown of request
%%%===================================================================
-spec init({'tcp' | 'ssl', 'http'}, cowboy_req:req(), kz_proplist()) ->
                  {'upgrade', 'protocol', 'cowboy_rest'}.
init({'tcp', 'http'}, _Req, _Opts) ->
    {'upgrade', 'protocol', 'cowboy_rest'};
init({'ssl', 'http'}, _Req, _Opts) ->
    {'upgrade', 'protocol', 'cowboy_rest'}.

-spec get_request_id(cowboy_req:req()) -> ne_binary().
get_request_id(Req) ->
    ReqId = case cowboy_req:header(<<"x-request-id">>, Req) of
                {'undefined', _} -> kz_datamgr:get_uuid();
                {UserReqId, _} -> kz_term:to_binary(UserReqId)
            end,
    kz_util:put_callid(ReqId),
    ReqId.

-spec get_profile_id(cowbow_req:req()) -> api_binary().
get_profile_id(Req) ->
    case cowboy_req:header(<<"x-profile-id">>, Req) of
        {'undefined', _} -> 'undefined';
        {ProfId, _} -> kz_term:to_binary(ProfId)
    end.

-spec get_client_ip(inet:ip_address(), cowboy_req:req()) ->
                           ne_binary().
get_client_ip(Peer, Req) ->
    case cowboy_req:header(<<"x-forwarded-for">>, Req) of
        {'undefined', _} -> kz_network_utils:iptuple_to_binary(Peer);
        {ForwardIP, _} -> maybe_allow_proxy_req(kz_network_utils:iptuple_to_binary(Peer), ForwardIP)
    end.

-spec maybe_trace(cowboy_req:req()) -> 'ok'.
-spec maybe_trace(cowboy_req:req(), boolean()) -> 'ok'.
maybe_trace(Req) ->
    maybe_trace(Req
               ,kapps_config:get_is_true(?CONFIG_CAT, <<"allow_tracing">>, 'false')
               ).

maybe_trace(_Req, 'false') -> 'ok';
maybe_trace(Req, 'true') ->
    case cowboy_req:header(<<"x-trace-request">>, Req) of
        {'undefined', _} -> 'ok';
        {ShouldTrace, _} ->
            maybe_start_trace(kz_term:to_boolean(ShouldTrace))
    end.

-spec maybe_start_trace(boolean()) -> 'ok'.
maybe_start_trace('false') -> 'ok';
maybe_start_trace('true') ->
    'ok' = kz_tracers:add_trace(self(), 5*?MILLISECONDS_IN_SECOND),
    lager:info("added trace").

-spec rest_init(cowboy_req:req(), kz_proplist()) ->
                       {'ok', cowboy_req:req(), cb_context:context()}.
rest_init(Req0, Opts) ->
    ReqId = get_request_id(Req0),
    ProfileId = get_profile_id(Req0),
    maybe_trace(Req0),

    {HostUrl, _} = cowboy_req:host_url(Req0),
    {Host, Req1} = cowboy_req:host(Req0),
    {Port, Req2} = cowboy_req:port(Req1),
    {Path, Req3} = find_path(Req2, Opts),

    {QS, Req4} = cowboy_req:qs(Req3),
    {Method, Req5} = cowboy_req:method(Req4),
    {{Peer, _PeerPort}, Req6} = cowboy_req:peer(Req5),
    {Version, Req7} = find_version(Path, Req6),

    ClientIP = get_client_ip(Peer, Req7),

    {Headers, _} = cowboy_req:headers(Req7),

    Setters = [{fun cb_context:set_req_id/2, ReqId}
              ,{fun cb_context:set_req_headers/2, Headers}
              ,{fun cb_context:set_host_url/2, kz_term:to_binary(HostUrl)}
              ,{fun cb_context:set_raw_host/2, kz_term:to_binary(Host)}
              ,{fun cb_context:set_port/2, kz_term:to_integer(Port)}
              ,{fun cb_context:set_raw_path/2, kz_term:to_binary(Path)}
              ,{fun cb_context:set_raw_qs/2, kz_term:to_binary(QS)}
              ,{fun cb_context:set_method/2, kz_term:to_binary(Method)}
              ,{fun cb_context:set_resp_status/2, 'fatal'}
              ,{fun cb_context:set_resp_error_msg/2, <<"init failed">>}
              ,{fun cb_context:set_resp_error_code/2, 500}
              ,{fun cb_context:set_client_ip/2, ClientIP}
              ,{fun cb_context:set_profile_id/2, ProfileId}
              ,{fun cb_context:set_api_version/2, Version}
              ,{fun cb_context:set_magic_pathed/2, props:is_defined('magic_path', Opts)}
              ,{fun cb_context:store/3, 'metrics', metrics()}
              ],

    Context0 = cb_context:setters(cb_context:new(), Setters),

    case api_util:get_req_data(Context0, Req7) of
        {'halt', Req8, Context1} ->
            lager:debug("getting request data failed, halting"),
            {Req9, Context2} = api_util:get_auth_token(Req8, Context1),
            {'ok', Req9, Context2};
        {Context1, Req8} ->
            {Req9, Context2} = api_util:get_auth_token(Req8, Context1),
            {Req10, Context3} = api_util:get_pretty_print(Req9, Context2),
            Event = api_util:create_event_name(Context3, <<"init">>),
            {Context4, _} = crossbar_bindings:fold(Event, {Context3, Opts}),
            Context5 = maybe_decode_start_key(Context4),
            lager:info("~s: ~s?~s from ~s", [Method, Path, QS, ClientIP]),
            {'ok', cowboy_req:set_resp_header(<<"x-request-id">>, ReqId, Req10), Context5}
    end.

-spec maybe_decode_start_key(cb_context:context()) -> cb_context:context().
maybe_decode_start_key(Context) ->
    case cb_context:req_value(Context, <<"start_key">>) of
        'undefined' -> Context;
        Value ->
            QS = cb_context:query_string(Context),
            ReqData = cb_context:req_data(Context),
            ReqJson = cb_context:req_json(Context),

            NewReqData = case kz_json:is_json_object(ReqData) of
                             'true' -> kz_json:delete_key(<<"start_key">>, ReqData);
                             'false' -> ReqData
                         end,
            NewQS = kz_json:set_value(<<"start_key">>, api_util:decode_start_key(Value), QS),

            Setters = [{fun cb_context:set_req_data/2, NewReqData}
                      ,{fun cb_context:set_query_string/2, NewQS}
                      ,{fun cb_context:set_req_json/2, kz_json:delete_key(<<"start_key">>, ReqJson)}
                      ],
            cb_context:setters(Context, Setters)
    end.

-spec metrics() -> {non_neg_integer(), non_neg_integer()}.
metrics() ->
    {kz_util:bin_usage(), kz_util:mem_usage()}.

-spec find_version(ne_binary()) -> ne_binary().
-spec find_version(ne_binary(), cowboy_req:req()) ->
                          {ne_binary(), cowboy_req:req()}.
find_version(Path, Req) ->
    case cowboy_req:binding('version', Req) of
        {'undefined', Req1} -> {find_version(Path), Req1};
        {_Version, _Req1}=Found -> Found
    end.

find_version(Path) ->
    lager:debug("find version in ~s", [Path]),
    case binary:split(Path, <<"/">>, ['global']) of
        [Path] -> ?VERSION_1;
        [<<>>, Ver | _] -> to_version(Ver);
        [Ver | _] -> to_version(Ver)
    end.

-spec maybe_allow_proxy_req(ne_binary(), ne_binary()) -> ne_binary().
maybe_allow_proxy_req(Peer, ForwardIP) ->
    ShouldCheck = kapps_config:get_is_true(?APP_NAME, <<"check_reverse_proxies">>, 'true'),
    maybe_allow_proxy_req(Peer, ForwardIP, ShouldCheck).

-spec maybe_allow_proxy_req(ne_binary(), ne_binary(), boolean()) -> ne_binary().
maybe_allow_proxy_req(_Peer, ForwardIP, 'false') ->
    ForwardIP;
maybe_allow_proxy_req(Peer, ForwardIP, 'true') ->
    case is_proxied(Peer) of
        'true' ->
            lager:info("request is from expected reverse proxy: ~s", [ForwardIP]),
            kz_term:to_binary(ForwardIP);
        'false' ->
            lager:warning("request with \"X-Forwarded-For: ~s\" header, but peer (~s) is not allowed as proxy"
                         ,[ForwardIP, Peer]
                         ),
            Peer
    end.

-spec is_proxied(ne_binary()) -> boolean().
-spec is_proxied(ne_binary(), ne_binaries()) -> boolean().
is_proxied(Peer) ->
    Proxies = kapps_config:get_ne_binaries(?APP_NAME, <<"reverse_proxies">>, [<<"127.0.0.1">>]),
    is_proxied(Peer, Proxies).

is_proxied(_Peer, []) -> 'false';
is_proxied(Peer, [Proxy|Rest]) ->
    kz_network_utils:verify_cidr(Peer, kz_network_utils:to_cidr(Proxy))
        orelse is_proxied(Peer, Rest).

to_version(<<"v", Int/binary>>=Version) ->
    try kz_term:to_integer(Int) of
        _ -> Version
    catch
        _:_ -> ?VERSION_1
    end;
to_version(_) -> ?VERSION_1.

find_path(Req, Opts) ->
    case props:get_value('magic_path', Opts) of
        'undefined' -> cowboy_req:path(Req);
        Magic ->
            lager:debug("found magic path: ~s", [Magic]),
            {Magic, Req}
    end.

-spec terminate(cowboy_req:req(), cb_context:context()) -> 'ok'.
terminate(_Req, _Context) ->
    lager:debug("session finished").

-spec rest_terminate(cowboy_req:req(), cb_context:context()) -> 'ok'.
rest_terminate(Req, Context) ->
    rest_terminate(Req, Context, cb_context:method(Context)).

rest_terminate(Req, Context, ?HTTP_OPTIONS) ->
    lager:info("OPTIONS request fulfilled in ~p ms"
              ,[kz_time:elapsed_ms(cb_context:start(Context))]),
    _ = api_util:finish_request(Req, Context),
    'ok';
rest_terminate(Req, Context, Verb) ->
    {ABin, AMem} = metrics(),
    {BBin, BMem} = cb_context:fetch(Context, 'metrics'),
    lager:info("~s request fulfilled in ~p ms ~s mem ~s bin"
              ,[Verb, kz_time:elapsed_ms(cb_context:start(Context))
               ,pretty_metric(AMem - BMem)
               ,pretty_metric(ABin - BBin)
               ]),
    _ = api_util:finish_request(Req, Context),
    'ok'.

-spec pretty_metric(integer()) -> ne_binary().
-spec pretty_metric(integer(), boolean()) -> ne_binary().
pretty_metric(N) ->
    pretty_metric(N, kapps_config:get_is_true(?CONFIG_CAT, <<"pretty_metrics">>, 'true')).

pretty_metric(N, 'false') ->
    kz_term:to_binary(N);
pretty_metric(N, 'true') when N < 0 ->
    NegN = N * -1,
    PrettyN = kz_util:pretty_print_bytes(NegN),
    <<"-", PrettyN/binary>>;
pretty_metric(N, 'true') ->
    kz_util:pretty_print_bytes(N).

%%%===================================================================
%%% CowboyHTTPRest API Callbacks
%%%===================================================================
-spec known_methods(cowboy_req:req(), cb_context:context()) ->
                           {http_methods(), cowboy_req:req(), cb_context:context()}.
known_methods(Req, Context) ->
    case cb_context:resp_status(Context) of
        'halt' ->
            lager:debug("error during init, returning error response"),
            {'halt', Req, Context};
        _Status ->
            lager:debug("run: known_methods"),
            {?ALLOWED_METHODS
            ,Req
            ,cb_context:set_allowed_methods(cb_context:set_allow_methods(Context, ?ALLOWED_METHODS)
                                           ,?ALLOWED_METHODS
                                           )
            }
    end.

-spec allowed_methods(cowboy_req:req(), cb_context:context()) ->
                             {http_methods() | 'halt', cowboy_req:req(), cb_context:context()}.
allowed_methods(Req, Context) ->
    lager:debug("run: allowed_methods"),

    case api_util:is_early_authentic(Req, Context) of
        {'true', Req1, Context1} ->
            authed_allowed_methods(Req1, Context1);
        {'halt', _Req1, _Context1}=HALT ->
            lager:error("request is not authorized, halting"),
            HALT
    end.

-spec authed_allowed_methods(cowboy_req:req(), cb_context:context()) ->
                                    {http_methods() | 'halt', cowboy_req:req(), cb_context:context()}.
authed_allowed_methods(Req, Context) ->
    lager:debug("run: authed_allowed_methods"),

    Methods = cb_context:allowed_methods(Context),
    Tokens = api_util:path_tokens(Context),

    case api_util:parse_path_tokens(Context, Tokens) of
        [_|_] = Nouns ->
            %% Because we allow tunneling of verbs through the request,
            %% we have to check and see if we need to override the actual
            %% HTTP method with the tunneled version
            determine_http_verb(Req, cb_context:set_req_nouns(Context, Nouns));
        [] ->
            {Methods, Req, cb_context:set_allow_methods(Context, Methods)};
        {'halt', Context1} ->
            api_util:halt(Req, Context1)
    end.

-spec determine_http_verb(cowboy_req:req(), cb_context:context()) ->
                                 {http_methods() | 'halt', cowboy_req:req(), cb_context:context()}.
determine_http_verb(Req0, Context) ->
    {Method, Req1} = cowboy_req:method(Req0),
    ReqVerb = api_util:get_http_verb(Method, Context),
    find_allowed_methods(Req1, cb_context:set_req_verb(Context, ReqVerb)).

find_allowed_methods(Req0, Context) ->
    [{Mod, Params}|_] = cb_context:req_nouns(Context),

    Event = api_util:create_event_name(Context, <<"allowed_methods">>),
    Responses = crossbar_bindings:map(<<Event/binary, ".", Mod/binary>>, Params),

    {Method, Req1} = cowboy_req:method(Req0),
    AllowMethods = api_util:allow_methods(Responses
                                         ,cb_context:req_verb(Context)
                                         ,kz_term:to_binary(Method)
                                         ),
    maybe_add_cors_headers(Req1, cb_context:set_allow_methods(Context, AllowMethods)).

-spec maybe_add_cors_headers(cowboy_req:req(), cb_context:context()) ->
                                    {http_methods() | 'halt', cowboy_req:req(), cb_context:context()}.
maybe_add_cors_headers(Req0, Context) ->
    case api_util:is_cors_request(Req0) of
        {'true', Req1} ->
            lager:debug("adding cors headers"),
            check_preflight(api_util:add_cors_headers(Req1, Context), Context);
        {'false', Req1} ->
            maybe_allow_method(Req1, Context)
    end.

-spec check_preflight(cowboy_req:req(), cb_context:context()) ->
                             {http_methods(), cowboy_req:req(), cb_context:context()}.
check_preflight(Req, Context) ->
    check_preflight(Req, Context, cb_context:req_verb(Context)).

check_preflight(Req, Context, ?HTTP_OPTIONS) ->
    lager:debug("allowing OPTIONS request for CORS preflight"),
    {[?HTTP_OPTIONS], Req, Context};
check_preflight(Req, Context, _Verb) ->
    maybe_allow_method(Req, Context).

maybe_allow_method(Req, Context) ->
    maybe_allow_method(Req, Context, cb_context:allow_methods(Context), cb_context:req_verb(Context)).

maybe_allow_method(Req, Context, [], _Verb) ->
    lager:debug("no allow methods"),
    api_util:halt(Req, cb_context:add_system_error('not_found', Context));
maybe_allow_method(Req, Context, [Verb]=Methods, Verb) ->
    {Methods, Req, Context};
maybe_allow_method(Req, Context, Methods, Verb) ->
    case lists:member(Verb, Methods) of
        'true' -> {Methods, Req, Context};
        'false' ->
            api_util:halt(Req, cb_context:add_system_error('invalid_method', Context))
    end.

-spec malformed_request(cowboy_req:req(), cb_context:context()) ->
                               {boolean(), cowboy_req:req(), cb_context:context()}.
-spec malformed_request(cowboy_req:req(), cb_context:context(), http_method()) ->
                               {boolean(), cowboy_req:req(), cb_context:context()}.
malformed_request(Req, Context) ->
    malformed_request(Req, Context, cb_context:req_verb(Context)).

malformed_request(Req, Context, ?HTTP_OPTIONS) ->
    {'false', Req, Context};
malformed_request(Req, Context, _ReqVerb) ->
    case props:get_value(<<"accounts">>, cb_context:req_nouns(Context)) of
        [AccountId] ->
            Context1 = cb_accounts:validate_resource(Context, AccountId),
            case cb_context:resp_status(Context1) of
                'success' -> {'false', Req, Context1};
                _RespStatus -> api_util:halt(Req, Context1)
            end;
        _Other ->
            {'false', Req, Context}
    end.

-spec is_authorized(cowboy_req:req(), cb_context:context()) ->
                           {'true' | {'false', <<>>}, cowboy_req:req(), cb_context:context()} |
                           api_util:halt_return().
is_authorized(Req, Context) ->
    api_util:is_authentic(Req, Context).

-spec forbidden(cowboy_req:req(), cb_context:context()) ->
                       {'false', cowboy_req:req(), cb_context:context()}.
forbidden(Req0, Context0) ->
    case api_util:is_permitted(Req0, Context0) of
        {'halt', _, _}=Reply -> Reply;
        {IsPermitted, Req1, Context1} ->
            {not IsPermitted, Req1, Context1}
    end.

-spec valid_content_headers(cowboy_req:req(), cb_context:context()) ->
                                   {'true', cowboy_req:req(), cb_context:context()}.
valid_content_headers(Req, Context) ->
    {'true', Req, Context}.

-spec known_content_type(cowboy_req:req(), cb_context:context()) ->
                                {boolean(), cowboy_req:req(), cb_context:context()}.
-spec known_content_type(cowboy_req:req(), cb_context:context(), http_method()) ->
                                {boolean(), cowboy_req:req(), cb_context:context()}.
known_content_type(Req, Context) ->
    known_content_type(Req, Context, cb_context:req_verb(Context)).

known_content_type(Req, Context, ?HTTP_OPTIONS) ->
    {'true', Req, Context};
known_content_type(Req, Context, ?HTTP_GET) ->
    {'true', Req, Context};
known_content_type(Req, Context, ?HTTP_DELETE) ->
    {'true', Req, Context};
known_content_type(Req, Context, _ReqVerb) ->
    Req2 = case cowboy_req:header(<<"content-type">>, Req) of
               {'undefined', Req1} ->
                   cowboy_req:set_resp_header(<<"X-RFC2616">>
                                             ,<<"Section 14.17 (Try it, you'll like it)">>
                                             ,Req1
                                             );
               {_, Req1} -> Req1
           end,
    api_util:is_known_content_type(Req2, Context).

-spec valid_entity_length(cowboy_req:req(), cb_context:context()) ->
                                 {'true', cowboy_req:req(), cb_context:context()}.
valid_entity_length(Req, Context) ->
    {'true', Req, Context}.

-spec options(cowboy_req:req(), cb_context:context()) ->
                     {'ok', cowboy_req:req(), cb_context:context()}.
options(Req0, Context) ->
    case api_util:is_cors_request(Req0) of
        {'true', Req1} ->
            lager:debug("is CORS request"),
            Req2 = api_util:add_cors_headers(Req1, Context),
            Req3 = cowboy_req:set_resp_body(<<>>, Req2),
            {'ok', Req3, Context};
        {'false', Req1} ->
            lager:debug("is not CORS request"),
            {'ok', Req1, Context}
    end.

-type content_type_callbacks() :: [{{ne_binary(), ne_binary(), kz_proplist()}, atom()} |
                                   {ne_binary(), atom()}
                                  ].
-spec content_types_provided(cowboy_req:req(), cb_context:context()) ->
                                    {content_type_callbacks(), cowboy_req:req(), cb_context:context()}.
content_types_provided(Req, Context0) ->
    lager:debug("run: content_types_provided"),

    [{Mod, Params}|_] = cb_context:req_nouns(Context0),
    Event = api_util:create_event_name(Context0, <<"content_types_provided.", Mod/binary>>),
    Payload = [Context0 | Params],

    Context1 = crossbar_bindings:fold(Event, Payload),

    content_types_provided(Req, Context1, cb_context:content_types_provided(Context1)).

content_types_provided(Req, Context, []) ->
    Def = ?CONTENT_PROVIDED,
    content_types_provided(Req, cb_context:set_content_types_provided(Context, Def), Def);
content_types_provided(Req, Context, CTPs) ->
    CTP =
        lists:foldr(fun({Fun, L}, Acc) ->
                            lists:foldr(fun({Type, SubType}, Acc1) ->
                                                [{{Type, SubType, []}, Fun} | Acc1];
                                           ({_,_,_}=EncType, Acc1) ->
                                                [ {EncType, Fun} | Acc1 ];
                                           (CT, Acc1) when is_binary(CT) ->
                                                [{CT, Fun} | Acc1]
                                        end, Acc, L)
                    end, [], CTPs),
    {CTP, Req, Context}.

-spec content_types_accepted(cowboy_req:req(), cb_context:context()) ->
                                    {content_type_callbacks(), cowboy_req:req(), cb_context:context()}.
content_types_accepted(Req0, Context0) ->
    lager:debug("run: content_types_accepted"),

    [{Mod, Params} | _] = cb_context:req_nouns(Context0),
    Event = api_util:create_event_name(Context0, <<"content_types_accepted.", Mod/binary>>),
    Payload = [Context0 | Params],
    Context1 = crossbar_bindings:fold(Event, Payload),

    case cowboy_req:parse_header(<<"content-type">>, Req0) of
        {'undefined', <<>>, Req1} ->
            lager:debug("no content type on request, checking defaults"),
            default_content_types_accepted(Req1, Context1);
        {'ok', 'undefined', Req1} ->
            lager:debug("no content type on request, checking defaults"),
            default_content_types_accepted(Req1, Context1);
        {'error', 'badarg'} ->
            lager:debug("content type failed to be processed, checking defaults"),
            default_content_types_accepted(Req0, Context1);
        {'ok', CT, Req1} ->
            lager:debug("checking content type '~p' against accepted", [CT]),
            content_types_accepted(CT, Req1, Context1)
    end.

-spec default_content_types_accepted(cowboy_req:req(), cb_context:context()) ->
                                            {content_types_funs(), cowboy_req:req(), cb_context:context()}.
default_content_types_accepted(Req, Context) ->
    CTA = [ {'*', Fun}
            || {Fun, L} <- cb_context:content_types_accepted(Context),
               lists:any(fun({Type, SubType}) ->
                                 api_util:content_type_matches(?CROSSBAR_DEFAULT_CONTENT_TYPE
                                                              ,{Type, SubType, []}
                                                              );
                            ({_,_,_}=ModCT) ->
                                 api_util:content_type_matches(?CROSSBAR_DEFAULT_CONTENT_TYPE, ModCT)
                         end, L) % check each type against the default
          ],
    lager:debug("default cta: ~p", [CTA]),
    {CTA, Req, Context}.

-type content_type_fun() :: {content_type(), atom()}.
-type content_types_funs() :: [content_type_fun()].

-spec content_types_accepted(content_type(), cowboy_req:req(), cb_context:context()) ->
                                    {content_types_funs(), cowboy_req:req(), cb_context:context()}.
-spec content_types_accepted(content_type(), cowboy_req:req(), cb_context:context(), crossbar_content_handlers()) ->
                                    {content_types_funs(), cowboy_req:req(), cb_context:context()}.
content_types_accepted(CT, Req, Context) ->
    content_types_accepted(CT, Req, Context, cb_context:content_types_accepted(Context)).

content_types_accepted(CT, Req, Context, []) ->
    lager:debug("no content-types accepted, using defaults"),
    content_types_accepted(CT, Req, cb_context:set_content_types_accepted(Context, ?CONTENT_ACCEPTED));
content_types_accepted(CT, Req, Context, Accepted) ->
    CTA = lists:foldl(fun(I, Acc) ->
                              content_types_accepted_fold(I, Acc, CT)
                      end
                     ,[]
                     ,Accepted
                     ),
    lager:debug("cta: ~p", [CTA]),
    {CTA, Req, Context}.

-spec content_types_accepted_fold(crossbar_content_handler(), content_types_funs(), content_type()) ->
                                         content_types_funs().
content_types_accepted_fold({Fun, L}, Acc, CT) ->
    lists:foldl(fun(CTA, Acc1) ->
                        content_type_accepted_fold(CTA, Acc1, Fun, CT)
                end
               ,Acc
               ,L
               ).

-spec content_type_accepted_fold(any(), content_type_fun(), atom(), content_type()) ->
                                        content_type_fun().
content_type_accepted_fold({Type, SubType}, Acc, Fun, CT) ->
    case api_util:content_type_matches(CT, {Type, SubType, []}) of
        'true' -> [{CT, Fun} | Acc];
        'false' -> Acc
    end;
content_type_accepted_fold({_,_,_}=EncType, Acc, Fun, _CT) ->
    [{EncType, Fun} | Acc].

-spec languages_provided(cowboy_req:req(), cb_context:context()) ->
                                {ne_binaries(), cowboy_req:req(), cb_context:context()}.
languages_provided(Req0, Context0) ->
    lager:debug("run: languages_provided"),

    [{Mod, Params} | _] = cb_context:req_nouns(Context0),
    Event = api_util:create_event_name(Context0, <<"languages_provided.", Mod/binary>>),
    Payload = [Context0 | Params],
    Context1 = crossbar_bindings:fold(Event, Payload),

    case cowboy_req:parse_header(<<"accept-language">>, Req0) of
        {'ok', 'undefined', Req1} ->
            {cb_context:languages_provided(Context1), Req1, Context1};
        {'ok', [{A,_}|_]=_Accepted, Req1} ->
            lager:debug("adding first accept-lang header language: ~s", [A]),
            {cb_context:languages_provided(Context1) ++ [A], Req1, Context1}
    end.

-spec charsets_provided(cowboy_req:req(), cb_context:context()) -> 'no_call'.
charsets_provided(_Req, _Context) ->
    'no_call'.

-spec resource_exists(cowboy_req:req(), cb_context:context()) ->
                             {boolean(), cowboy_req:req(), cb_context:context()}.
resource_exists(Req, Context) ->
    resource_exists(Req, Context, cb_context:req_nouns(Context)).

resource_exists(Req, Context, [{<<"404">>,_}|_]) ->
    lager:debug("failed to tokenize request, returning 404"),
    {'false', Req, Context};
resource_exists(Req, Context, _Nouns) ->
    lager:debug("run: resource_exists"),
    case api_util:does_resource_exist(Context) of
        'true' ->
            does_request_validate(Req, Context);
        'false' ->
            lager:debug("requested resource does not exist"),
            {'false', Req, Context}
    end.

-spec does_request_validate(cowboy_req:req(), cb_context:context()) ->
                                   {boolean(), cowboy_req:req(), cb_context:context()}.
does_request_validate(Req, Context0) ->
    lager:debug("requested resource exists, validating it"),
    Context1 = cb_context:store(Context0, 'req', Req),
    Context2 = api_util:validate(Context1),
    Verb = cb_context:req_verb(Context2),
    case api_util:succeeded(Context2) of
        'true' when Verb =/= ?HTTP_PUT ->
            lager:debug("requested resource update validated"),
            {'true', Req, Context2};
        'true' ->
            lager:debug("requested resource creation validated"),
            {'false', Req, Context2};
        'false' ->
            lager:debug("failed to validate resource"),
            Msg = case cb_context:resp_error_msg(Context2) of
                      'undefined' ->
                          Data = cb_context:resp_data(Context2),
                          kz_json:get_value(<<"message">>, Data, <<"validation failed">>);
                      Message -> Message
                  end,
            api_util:halt(Req, cb_context:set_resp_error_msg(Context2, Msg))
    end.

-spec moved_temporarily(cowboy_req:req(), cb_context:context()) ->
                               {'false', cowboy_req:req(), cb_context:context()}.
moved_temporarily(Req, Context) ->
    lager:debug("run: moved_temporarily"),
    {'false', Req, Context}.

-spec moved_permanently(cowboy_req:req(), cb_context:context()) ->
                               {'false', cowboy_req:req(), cb_context:context()}.
moved_permanently(Req, Context) ->
    lager:debug("run: moved_permanently"),
    {'false', Req, Context}.

-spec previously_existed(cowboy_req:req(), cb_context:context()) ->
                                {'false', cowboy_req:req(), cb_context:context()}.
previously_existed(Req, State) ->
    lager:debug("run: previously_existed"),
    {'false', Req, State}.

%% If we're tunneling PUT through POST,
%% we need to allow POST to create a nonexistent resource
%% AKA, 201 Created header set
-spec allow_missing_post(cowboy_req:req(), cb_context:context()) ->
                                {boolean(), cowboy_req:req(), cb_context:context()}.
allow_missing_post(Req0, Context) ->
    lager:debug("run: allow_missing_post when req_verb = ~s", [cb_context:req_verb(Context)]),
    {Method, Req1} = cowboy_req:method(Req0),
    {Method =:= ?HTTP_POST, Req1, Context}.

-spec delete_resource(cowboy_req:req(), cb_context:context()) ->
                             {boolean() | 'halt', cowboy_req:req(), cb_context:context()}.
delete_resource(Req, Context) ->
    lager:debug("run: delete_resource"),
    api_util:execute_request(Req, Context).

-spec delete_completed(cowboy_req:req(), cb_context:context()) ->
                              {boolean(), cowboy_req:req(), cb_context:context()}.
delete_completed(Req, Context) ->
    lager:debug("run: delete_completed"),
    api_util:create_push_response(Req, Context).

-spec is_conflict(cowboy_req:req(), cb_context:context()) ->
                         {boolean(), cowboy_req:req(), cb_context:context()}.
is_conflict(Req, Context) ->
    is_conflict(Req, Context, cb_context:resp_error_code(Context)).

is_conflict(Req, Context, 409) ->
    lager:debug("request resulted in conflict"),
    {'true', Req, Context};
is_conflict(Req, Context, _RespCode) ->
    lager:debug("run: is_conflict: false"),
    {'false', Req, Context}.

-spec from_binary(cowboy_req:req(), cb_context:context()) ->
                         {boolean(), cowboy_req:req(), cb_context:context()}.
from_binary(Req0, Context0) ->
    lager:debug("run: from_binary"),
    case api_util:execute_request(Req0, Context0) of
        {'true', Req1, Context1} ->
            Event = api_util:create_event_name(Context1, <<"from_binary">>),
            _ = crossbar_bindings:map(Event, {Req1, Context1}),
            create_from_response(Req1, Context1);
        Else -> Else
    end.

-spec from_json(cowboy_req:req(), cb_context:context()) ->
                       {boolean(), cowboy_req:req(), cb_context:context()}.
from_json(Req0, Context0) ->
    lager:debug("run: from_json"),
    case api_util:execute_request(Req0, Context0) of
        {'true', Req1, Context1} ->
            Event = api_util:create_event_name(Context1, <<"from_json">>),
            _ = crossbar_bindings:map(Event, {Req1, Context1}),
            create_from_response(Req1, Context1);
        Else -> Else
    end.

-spec from_form(cowboy_req:req(), cb_context:context()) ->
                       {boolean(), cowboy_req:req(), cb_context:context()}.
from_form(Req0, Context0) ->
    lager:debug("run: from_form"),
    case api_util:execute_request(Req0, Context0) of
        {'true', Req1, Context1} ->
            Event = api_util:create_event_name(Context1, <<"from_form">>),
            _ = crossbar_bindings:map(Event, {Req1, Context1}),
            create_from_response(Req1, Context1);
        Else -> Else
    end.

-spec create_from_response(cowboy_req:req(), cb_context:context()) ->
                                  {boolean(), cowboy_req:req(), cb_context:context()}.
-spec create_from_response(cowboy_req:req(), cb_context:context(), api_binary()) ->
                                  {boolean(), cowboy_req:req(), cb_context:context()}.
create_from_response(Req, Context) ->
    create_from_response(Req, Context, cb_context:req_header(Context, <<"accept">>)).

create_from_response(Req, Context, 'undefined') ->
    create_from_response(Req, Context, <<"*/*">>);
create_from_response(Req, Context, Accept) ->
    CTPs = [F || {F, _} <- cb_context:content_types_provided(Context)],
    DefaultFun = case CTPs of
                     [] -> 'to_json';
                     [F|_] -> F
                 end,
    case to_fun(Context, Accept, DefaultFun) of
        'to_json' -> api_util:create_push_response(Req, Context);
        'send_file' -> api_util:create_push_response(Req, Context, fun api_util:create_resp_file/2);
        _ ->
            %% sending json for now until we implement other types
            api_util:create_push_response(Req, Context)
    end.

-spec to_json(cowboy_req:req(), cb_context:context()) ->
                     {iolist() | ne_binary() | 'halt', cowboy_req:req(), cb_context:context()}.
to_json(Req, Context) ->
    to_json(Req, Context, accept_override(Context)).

to_json(Req0, Context0, 'undefined') ->
    case cb_context:fetch(Context0, 'is_chunked') of
        'true' -> to_chunk(<<"to_json">>, Req0, Context0);
        _ ->
            lager:debug("run: to_json"),
            Event = to_fun_event_name(<<"to_json">>, Context0),
            {Req1, Context1} = crossbar_bindings:fold(Event, {Req0, Context0}),
            api_util:create_pull_response(Req1, Context1)
    end;
to_json(Req, Context, <<"csv">>) ->
    lager:debug("overridding json with csv builder"),
    to_csv(Req, Context);
to_json(Req, Context, <<"pdf">>) ->
    lager:debug("overridding json with pdf builder"),
    to_pdf(Req, Context);
to_json(Req, Context, Accept) ->
    case to_fun(Context, Accept, 'to_json') of
        'to_json' -> to_json(Req, Context, 'undefined');
        Fun ->
            lager:debug("calling ~s instead of to_json to render response", [Fun]),
            (?MODULE):Fun(Req, Context)
    end.

-spec to_binary(cowboy_req:req(), cb_context:context()) ->
                       {binary() | 'halt', cowboy_req:req(), cb_context:context()}.
to_binary(Req, Context) ->
    to_binary(Req, Context, accept_override(Context)).

to_binary(Req, Context, 'undefined') ->
    lager:debug("run: to_binary"),
    RespData = cb_context:resp_data(Context),
    Event = api_util:create_event_name(Context, <<"to_binary">>),
    _ = crossbar_bindings:map(Event, {Req, Context}),
    %% Handle HTTP range header
    case cb_context:req_header(Context, <<"range">>) of
        'undefined' ->
            {RespData, api_util:set_resp_headers(Req, Context), Context};
        RangeHeader ->
            RangeData={Content, Start, End, Length, FileLength} = get_range(RespData, RangeHeader),
            ErrorCode = resp_error_code_for_range(RangeData),
            Setters = [{fun cb_context:set_resp_data/2, Content}
                      ,{fun cb_context:set_resp_error_code/2, ErrorCode}
                      ,{fun cb_context:add_resp_headers/2
                       ,[{<<"Content-Range">>, kz_term:to_binary(io_lib:fwrite("bytes ~B-~B/~B", [Start, End, FileLength]))}
                        ,{<<"Accept-Ranges">>, <<"bytes">>}
                        ]
                       }
                      ],
            NewContext = cb_context:setters(Context, Setters),
            %% Respond, possibly with 206
            {'ok', Req1} = cowboy_req:reply(kz_term:to_binary(ErrorCode), cb_context:resp_headers(NewContext), Content, Req),
            {'halt', Req1, NewContext}
    end;

to_binary(Req, Context, Accept) ->
    lager:debug("request has overridden accept header: ~s", [Accept]),
    case to_fun(Context, Accept, 'to_binary') of
        'to_binary' -> to_binary(Req, Context, 'undefined');
        Fun ->
            lager:debug("calling ~s instead of to_binary to render response", [Fun]),
            (?MODULE):Fun(Req, Context)
    end.

-type range_response() :: {ne_binary(), pos_integer(), pos_integer(), pos_integer(), pos_integer()}.

-spec get_range(ne_binary(), ne_binary()) -> range_response().
get_range(Data, RangeHeader) ->
    FileLength = size(Data),
    lager:debug("received range header ~p for file size ~p", [RangeHeader, FileLength]),
    {Start, End} = case cowboy_http:range(RangeHeader) of
                       {<<"bytes">>, [{S, 'infinity'}]} -> {S, FileLength};
                       {<<"bytes">>, [{S, E}]} when E < FileLength -> {S, E + 1};
                       _Thing ->
                           lager:info("invalid range specification ~p", [RangeHeader]),
                           {0, FileLength}
                   end,
    ContentLength = End - Start,
    <<_:Start/binary, Content:ContentLength/binary, _/binary>> = Data,
    {Content, Start, End - 1, ContentLength, FileLength}.

-spec resp_error_code_for_range(range_response()) -> 200 | 206.
resp_error_code_for_range({_Content, _Start, _End, FileLength, FileLength}) -> 200;
resp_error_code_for_range({_Content, _Start, _End, _Length, _FileLength}) -> 206.

-spec send_file(cowboy_req:req(), cb_context:context()) -> api_util:pull_file_response_return().
send_file(Req, Context) ->
    lager:debug("run: send_file"),
    api_util:create_pull_response(Req, Context, fun api_util:create_resp_file/2).

-spec to_fun(cb_context:context(), ne_binary(), atom()) -> atom().
-spec to_fun(cb_context:context(), ne_binary(), ne_binary(), atom()) -> atom().
to_fun(Context, Accept, Default) ->
    case binary:split(Accept, <<"/">>) of
        [Major, Minor] -> to_fun(Context, Major, Minor, Default);
        _ -> Default
    end.

to_fun(Context, Major, Minor, Default) ->
    case [F || {F, CTPs} <- cb_context:content_types_provided(Context),
               accept_matches_provided(Major, Minor, CTPs)
         ]
    of
        [] -> Default;
        [F|_] -> F
    end.

-spec accept_matches_provided(ne_binary(), ne_binary(), kz_proplist()) -> boolean().
accept_matches_provided(Major, Minor, CTPs) ->
    lists:any(fun({Pri, Sec}) ->
                      Pri =:= Major
                          andalso ((Sec =:= Minor)
                                   orelse (Minor =:= <<"*">>)
                                  )
              end, CTPs
             ).

-spec to_csv(cowboy_req:req(), cb_context:context()) ->
                    {iolist(), cowboy_req:req(), cb_context:context()}.
to_csv(Req0, Context0) ->
    case cb_context:fetch(Context0, 'is_chunked') of
        'true' -> to_chunk(<<"to_csv">>, Req0, Context0);
        _ ->
            lager:debug("run: to_csv"),
            Event = to_fun_event_name(<<"to_csv">>, Context0),
            {Req1, Context1} = crossbar_bindings:fold(Event, {Req0, Context0}),
            api_util:create_pull_response(Req1, Context1, fun api_util:create_csv_resp_content/2)
    end.

-spec to_pdf(cowboy_req:req(), cb_context:context()) ->
                    {binary(), cowboy_req:req(), cb_context:context()}.
-spec to_pdf(cowboy_req:req(), cb_context:context(), binary()) ->
                    {binary(), cowboy_req:req(), cb_context:context()}.
to_pdf(Req, Context) ->
    lager:debug("run: to_pdf"),
    Event = to_fun_event_name(<<"to_pdf">>, Context),
    {Req1, Context1} = crossbar_bindings:fold(Event, {Req, Context}),
    to_pdf(Req1, Context1, cb_context:resp_data(Context1)).

to_pdf(Req, Context, <<>>) ->
    to_pdf(Req, Context, kz_pdf:error_empty());
to_pdf(Req, Context, RespData) ->
    RespHeaders = [{<<"Content-Type">>, <<"application/pdf">>}
                  ,{<<"Content-Disposition">>, <<"attachment; filename=\"file.pdf\"">>}
                   | cb_context:resp_headers(Context)
                  ],
    {RespData
    ,api_util:set_resp_headers(Req, cb_context:set_resp_headers(Context, RespHeaders))
    ,Context
    }.

-spec to_chunk(ne_binary(), cowboy_req:req(), cb_context:context()) ->
                      {iolist() | ne_binary() | 'halt', cowboy_req:req(), cb_context:context()}.
to_chunk(ToFun, Req, Context) ->
    EventName = to_fun_event_name(ToFun, Context),
    next_chunk_fold(#{start_key => 'undefined'
                     ,last_key => 'undefined'
                     ,total_queried => 0
                     ,previous_chunk_length => 0
                     ,chunking_started => 'false'
                     ,chunking_finished => 'false'
                     ,cowboy_req => Req
                     ,context => Context
                     ,chunk_response_type => ToFun
                     ,event_name => EventName
                     }).

-spec next_chunk_fold(map()) -> {iolist() | ne_binary() | 'halt', cowboy_req:req(), cb_context:context()}.
next_chunk_fold(#{chunking_finished := 'true'
                 ,chunking_started := StartedChunk
                 ,context := Context
                 }=ChunkMap) ->
    finish_chunked_response(ChunkMap#{context => reset_context_between_chunks(Context, StartedChunk)});
next_chunk_fold(#{chunking_started := StartedChunk
                 ,context := Context0
                 }=ChunkMap0) ->
    Context1 = cb_context:store(Context0, 'chunking_started', StartedChunk),
    ChunkMap1 = #{context := Context2
                 ,cowboy_req := Req0
                 ,event_name := Event
                 } = crossbar_view:next_chunk(ChunkMap0#{context := Context1}),

    case api_util:succeeded(Context2)
        andalso crossbar_bindings:fold(Event, {Req0, Context2})
    of
        'false' ->
            finish_chunked_response(ChunkMap1#{context => reset_context_between_chunks(Context2, StartedChunk)});
        {Req1, Context3} ->
            case api_util:succeeded(Context3) of
                'true' ->
                    process_chunk(ChunkMap1#{cowboy_req := Req1, context := Context3});
                'false' ->
                    finish_chunked_response(ChunkMap1#{context => reset_context_between_chunks(Context3, StartedChunk)})
            end
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Check folded 'to_json' response and send this chunk result.
%%
%% === Sending chunk response from the module directly ===
%% If you're sending the chunk yourself in the module 'to_json', return
%% a non_neg_integer of how many of queried items did you sent.
%% (Obviously it should be same size as passed JObjs or less).
%%
%% The init_chunk_stream/1 is helping you to initializing chunk
%% response by sending HTTP headers and start the response envelope.
%%
%% When an error occurred (e.g. a db request error) and you want to
%% stop sending chunks, set the error in Context. If the chunk is already
%% started it will be closed by the regular JSON envelope or CSV.
%%
%% If chunk is not started yet, a regular Crossbar error will be generated
%% (a JSON non-chunked response). So don't forget to add appropriate error
%% to the Context.
%%
%% === Let api_resource sends chunk response ===
%% Simply set response in Context's `resp_data`, either as a list of JObjs
%% or list of CSV binary (depends on response type)
%%
%% Note: The JObjs in Context's response data are in the correct order,
%% if you're changing the JObjs (looping over, change/replace) do not forget
%% to reverse it to the correct order again (unless you have a customized
%%  sort order).
%%
%% Note: For CSV, you have to check if chunk is started, if not
%%       create the header and add it to the first element
%%       (<<Headers/binary, "\r\n", FirstRow/binary>>) of you're response.
%% @end
%%--------------------------------------------------------------------
-spec process_chunk(map()) -> {iolist() | ne_binary() | 'halt', cowboy_req:req(), cb_context:context()}.
process_chunk(#{context := Context
               ,cowboy_req := Req
               ,chunk_response_type := ToFun
               ,event_name := EventName
               ,chunking_started := IsStarted
               }=ChunkMap) ->
    case api_util:succeeded(Context)
        andalso cb_context:resp_data(Context)
    of
        'false' ->
            finish_chunked_response(ChunkMap#{context => reset_context_between_chunks(Context, IsStarted)});
        SentLength when is_integer(SentLength) ->
            next_chunk_fold(ChunkMap#{context => reset_context_between_chunks(Context, 'true')
                                     ,chunking_started => 'true'
                                     ,previous_chunk_length => SentLength
                                     }
                           );
        Resp when is_list(Resp) ->
            {StartedChunk, Req1} = send_chunk_response(ToFun, Req, Context),
            next_chunk_fold(ChunkMap#{context => reset_context_between_chunks(Context, StartedChunk)
                                     ,cowboy_req => Req1
                                     ,chunking_started => StartedChunk
                                     ,previous_chunk_length => length(Resp)
                                     }
                           );
        _Other ->
            lager:debug("event ~s returned unsupported chunk response, halting here", [EventName]),
            finish_chunked_response(ChunkMap#{context => reset_context_between_chunks(Context, IsStarted)}) %% TOFU: halt
    end.

-spec reset_context_between_chunks(cb_context:context(), boolean()) -> cb_context:context().
reset_context_between_chunks(Context, StartedChunk) ->
    cb_context:setters(Context
                      ,[{fun cb_context:set_resp_data/2, []}
                       ,{fun cb_context:set_doc/2, kz_json:new()}
                       ,{fun cb_context:store/3, 'chunking_started', StartedChunk}
                       ]
                      ).

-spec send_chunk_response(ne_binary(), cowboy_req:req(), cb_context:context()) ->
                                 {boolean(), cowboy_req:req()}.
send_chunk_response(<<"to_json">>, Req, Context) ->
    api_util:create_json_chunk_response(Req, Context);
send_chunk_response(<<"to_csv">>, Req, Context) ->
    api_util:create_csv_chunk_response(Req, Context).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% If chunked is started close data array and send envelope as the
%% last chunk.
%% Otherwise return {Req, Context} to allow api_util/api_resource
%% handling  the errors in the Context.
%% @end
%%--------------------------------------------------------------------
-spec finish_chunked_response(map()) -> {iolist() | ne_binary() | 'halt', cowboy_req:req(), cb_context:context()}.
%% chunk is not started, return whatever error's or response data in Context
finish_chunked_response(#{chunking_started := 'false'
                         ,context := Context
                         ,cowboy_req := Req
                         }) ->
    api_util:create_pull_response(Req, Context);
%% Chunk is already started, halting,
finish_chunked_response(#{chunk_response_type := <<"to_csv">>
                         ,context := Context
                         ,cowboy_req := Req
                         }) ->
    {'halt', Req, Context};
%% Chunk is already started closing JSON envelope,
finish_chunked_response(#{total_queried := TotalQueried
                         ,chunking_started := 'true'
                         ,cowboy_req := Req
                         ,context := Context
                         ,last_key := NextStartKey
                         ,start_key := StartKey
                         }) ->
    DeleteKeys = [<<"start_key">>, <<"page_size">>, <<"next_start_key">>],
    Paging = kz_json:set_values([{<<"start_key">>, StartKey}
                                ,{<<"page_size">>, TotalQueried}
                                ,{<<"next_start_key">>, NextStartKey}
                                ]
                               ,kz_json:delete_keys(DeleteKeys, cb_context:resp_envelope(Context))
                               ),
    api_util:close_chunk_json_envelope(Req, cb_context:set_resp_envelope(Context, Paging)),
    {'halt', Req, Context}.

-spec to_fun_event_name(ne_binary(), cb_contextL:context()) -> ne_binary().
to_fun_event_name(ToThing, Context) ->
    [{Mod, _Params}|_] = cb_context:req_nouns(Context),
    Verb = cb_context:req_verb(Context),
    api_util:create_event_name(Context, [ToThing, kz_term:to_lower_binary(Verb), Mod]).

-spec accept_override(cb_context:context()) -> api_binary().
accept_override(Context) ->
    cb_context:req_value(Context, <<"accept">>).

-spec multiple_choices(cowboy_req:req(), cb_context:context()) ->
                              {'false', cowboy_req:req(), cb_context:context()}.
multiple_choices(Req, Context) ->
    {'false', Req, Context}.

-spec generate_etag(cowboy_req:req(), cb_context:context()) ->
                           {api_ne_binary(), cowboy_req:req(), cb_context:context()}.
generate_etag(Req0, Context0) ->
    Event = api_util:create_event_name(Context0, <<"etag">>),
    {Req1, Context1} = crossbar_bindings:fold(Event, {Req0, Context0}),
    case cb_context:resp_etag(Context1) of
        'automatic' ->
            {Content, _} = api_util:create_resp_content(Req1, Context1),
            Tag = kz_term:to_hex_binary(crypto:hash('md5', Content)),
            {list_to_binary([$", Tag, $"]), Req1, cb_context:set_resp_etag(Context1, Tag)};
        'undefined' ->
            {'undefined', Req1, cb_context:set_resp_etag(Context1, 'undefined')};
        Tag ->
            {list_to_binary([$", Tag, $"]), Req1, cb_context:set_resp_etag(Context1, Tag)}
    end.

-spec expires(cowboy_req:req(), cb_context:context()) ->
                     {kz_datetime(), cowboy_req:req(), cb_context:context()}.
expires(Req, Context) ->
    Event = api_util:create_event_name(Context, <<"expires">>),
    crossbar_bindings:fold(Event, {cb_context:resp_expires(Context), Req, Context}).
