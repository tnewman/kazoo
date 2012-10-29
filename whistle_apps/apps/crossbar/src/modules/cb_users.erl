%%%-------------------------------------------------------------------
%%% @copyright (C) 2011-2012, VoIP INC
%%% @doc
%%% Users module
%%%
%%% Handle client requests for user documents
%%%
%%% @end
%%% @contributors
%%%   Karl Anderson
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(cb_users).

-export([create_user/1]).
-export([init/0
         ,allowed_methods/0, allowed_methods/1
         ,resource_exists/0, resource_exists/1
         ,validate/1, validate/2
         ,put/1
         ,post/2
         ,delete/2
        ]).

-include("include/crossbar.hrl").

-define(SERVER, ?MODULE).

-define(CB_LIST, <<"users/crossbar_listing">>).
-define(LIST_BY_USERNAME, <<"users/list_by_username">>).

%%%===================================================================
%%% API
%%%===================================================================

%% SUPPORT FOR THE DEPRECIATED CB_SIGNUPS...
create_user(Context) ->
    case validate_request(undefined, Context#cb_context{req_verb = <<"put">>}) of
        #cb_context{resp_status=success}=C1 -> ?MODULE:put(C1);
        Else -> Else
    end.

init() ->
    _ = crossbar_bindings:bind(<<"v1_resource.allowed_methods.users">>, ?MODULE, allowed_methods),
    _ = crossbar_bindings:bind(<<"v1_resource.resource_exists.users">>, ?MODULE, resource_exists),
    _ = crossbar_bindings:bind(<<"v1_resource.validate.users">>, ?MODULE, validate),
    _ = crossbar_bindings:bind(<<"v1_resource.execute.put.users">>, ?MODULE, put),
    _ = crossbar_bindings:bind(<<"v1_resource.execute.post.users">>, ?MODULE, post),
    _ = crossbar_bindings:bind(<<"v1_resource.execute.delete.users">>, ?MODULE, delete).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function determines the verbs that are appropriate for the
%% given Nouns.  IE: '/accounts/' can only accept GET and PUT
%%
%% Failure here returns 405
%% @end
%%--------------------------------------------------------------------
-spec allowed_methods/0 :: () -> http_methods().
-spec allowed_methods/1 :: (path_tokens()) -> http_methods().
allowed_methods() ->
    ['GET', 'PUT'].
allowed_methods(_) ->
    ['GET', 'POST', 'DELETE'].

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function determines if the provided list of Nouns are valid.
%%
%% Failure here returns 404
%% @end
%%--------------------------------------------------------------------
-spec resource_exists/0 :: () -> 'true'.
-spec resource_exists/1 :: (path_tokens()) -> 'true'.
resource_exists() -> true.
resource_exists(_) -> true.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function determines if the parameters and content are correct
%% for this request
%%
%% Failure here returns 400
%% @end
%%--------------------------------------------------------------------
-spec validate/1 :: (#cb_context{}) -> #cb_context{}.
-spec validate/2 :: (#cb_context{}, path_token()) -> #cb_context{}.
validate(#cb_context{req_verb = <<"get">>}=Context) ->
    load_user_summary(Context);
validate(#cb_context{req_verb = <<"put">>}=Context) ->
    validate_request(undefined, Context).

validate(#cb_context{req_verb = <<"get">>}=Context, UserId) ->
    load_user(UserId, Context);
validate(#cb_context{req_verb = <<"post">>}=Context, UserId) ->
    validate_request(UserId, Context);
validate(#cb_context{req_verb = <<"delete">>}=Context, UserId) ->
    load_user(UserId, Context).

-spec post/2 :: (#cb_context{}, path_token()) -> #cb_context{}.
post(Context, _) ->
    crossbar_doc:save(Context).

-spec put/1 :: (#cb_context{}) -> #cb_context{}.
put(Context) ->
    crossbar_doc:save(Context).

-spec delete/2 :: (#cb_context{}, path_token()) -> #cb_context{}.
delete(Context, _) ->
    crossbar_doc:delete(Context).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Attempt to load list of accounts, each summarized.  Or a specific
%% account summary.
%% @end
%%--------------------------------------------------------------------
-spec load_user_summary/1 :: (#cb_context{}) -> #cb_context{}.
load_user_summary(Context) ->
    crossbar_doc:load_view(?CB_LIST, [], Context, fun normalize_view_results/2).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Load a user document from the database
%% @end
%%--------------------------------------------------------------------
-spec load_user/2 :: (ne_binary(), #cb_context{}) -> #cb_context{}.
load_user(UserId, Context) ->
    crossbar_doc:load(UserId, Context).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% 
%% @end
%%--------------------------------------------------------------------
-spec validate_request/2 :: ('undefined'|ne_binary(), #cb_context{}) -> #cb_context{}.
validate_request(UserId, Context) ->
    prepare_username(UserId, Context).

prepare_username(UserId, #cb_context{req_data=JObj}=Context) ->
    case wh_json:get_ne_value(<<"username">>, JObj) of
        undefined -> check_user_schema(UserId, Context);
        Username ->
            JObj1 = wh_json:set_value(<<"username">>, wh_util:to_lower_binary(Username), JObj),
            check_user_schema(UserId, Context#cb_context{req_data=JObj1})
    end.

check_user_schema(UserId, Context) ->
    OnSuccess = fun(C) -> on_successful_validation(UserId, C) end,
    cb_context:validate_request_data(<<"users">>, Context, OnSuccess).

on_successful_validation(undefined, #cb_context{doc=Doc}=Context) ->
    Props = [{<<"pvt_type">>, <<"user">>}],
    maybe_validate_username(undefined, Context#cb_context{doc=wh_json:set_values(Props, Doc)});
on_successful_validation(UserId, #cb_context{}=Context) -> 
    maybe_validate_username(UserId, crossbar_doc:load_merge(UserId, Context)).

maybe_validate_username(UserId, #cb_context{doc=JObj}=Context) ->
    NewUsername = wh_json:get_ne_value(<<"username">>, JObj),
    CurrentUsername = case cb_context:fetch(db_doc, Context) of
                          undefined -> undefined;
                          CurrentJObj -> 
                              wh_json:get_ne_value(<<"username">>, CurrentJObj)
                      end,
    case wh_util:is_empty(NewUsername)
        orelse CurrentUsername =:= NewUsername
        orelse username_doc_id(NewUsername, Context)
    of
        %% username is unchanged
        true -> maybe_rehash_creds(UserId, NewUsername, Context);
        %% updated username that doesnt exist
        undefined -> 
            manditory_rehash_creds(UserId, NewUsername, Context);
        %% updated username to existing, collect any further errors...
        _Else ->
            C = cb_context:add_validation_error(<<"username">>
                                                   ,<<"unique">>
                                                   ,<<"Username is not unique for this account">>
                                                   ,Context),
            manditory_rehash_creds(UserId, NewUsername, C)
    end.

maybe_rehash_creds(UserId, Username, #cb_context{doc=JObj}=Context) ->
    case wh_json:get_ne_value(<<"password">>, JObj) of
        %% No username or hash, no creds for you!
        undefined when Username =:= undefined -> 
            HashKeys = [<<"pvt_md5_auth">>, <<"pvt_sha1_auth">>],
            Context#cb_context{doc=wh_json:delete_keys(HashKeys, JObj)};
        %% Username without password, creds status quo
        undefined -> Context;
        %% Got a password, hope you also have a username...
        Password -> rehash_creds(UserId, Username, Password, Context)
    end.

manditory_rehash_creds(UserId, Username, #cb_context{doc=JObj}=Context) ->
    case wh_json:get_ne_value(<<"password">>, JObj) of
        undefined -> 
            cb_context:add_validation_error(<<"password">>
                                                ,<<"required">>
                                                ,<<"The password must be provided when updating the username">>
                                                ,Context);
        Password -> rehash_creds(UserId, Username, Password, Context)
    end.

rehash_creds(_, undefined, _, Context) ->
    cb_context:add_validation_error(<<"username">>
                                        ,<<"required">>
                                        ,<<"The username must be provided when updating the password">>
                                        ,Context);
rehash_creds(_, Username, Password, #cb_context{doc=JObj}=Context) ->
    lager:debug("password set on doc, updating hashes for ~s", [Username]),
    {MD5, SHA1} = cb_modules_util:pass_hashes(Username, Password),
    JObj1 = wh_json:set_values([{<<"pvt_md5_auth">>, MD5}
                                ,{<<"pvt_sha1_auth">>, SHA1}
                               ], JObj),
    Context#cb_context{doc=wh_json:delete_key(<<"password">>, JObj1)}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will determine if the username in the request is
%% unique or belongs to the request being made
%% @end
%%--------------------------------------------------------------------
-spec username_doc_id/2 :: ('undefined' | ne_binary(), #cb_context{}) -> 'undefined' | ne_binary().
username_doc_id(Username, Context) ->
    Username = wh_util:to_lower_binary(Username),
    JObj = case crossbar_doc:load_view(?LIST_BY_USERNAME, [{<<"key">>, Username}], Context) of
               #cb_context{resp_status=success, doc=[J]} -> J;
               _ -> wh_json:new()
           end,
    wh_json:get_value(<<"id">>, JObj).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Normalizes the resuts of a view
%% @end
%%--------------------------------------------------------------------
-spec(normalize_view_results/2 :: (Doc :: wh_json:json_object(), Acc :: wh_json:json_objects()) -> wh_json:json_objects()).
normalize_view_results(JObj, Acc) ->
    [wh_json:get_value(<<"value">>, JObj)|Acc].
