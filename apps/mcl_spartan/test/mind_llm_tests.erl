%% @doc The call: the request that goes out, and what comes back.
%%
%% The mind's tests fake this module, so without a test like this the HTTP path
%% would first run for real on a box, which is the wrong place to find out what
%% an endpoint says. A stub on loopback exercises the real request, the real
%% parse and the real token count, and needs neither a key nor a network.
%%
%% The cases set the environment directly and leave it set: every one of them
%% runs under the same small world (one named endpoint, or a named pair), and
%% `mind_providers_tests` is the module that puts the environment back, because
%% it is the one that varies it.
-module(mind_llm_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TABLE, mind_llm_test_requests).

the_call_carries_the_charter_and_the_item_test() ->
    _ = with_endpoint(200, answer(<<"A post.">>, 42)),
    {ok, Reply} = mind_llm:reason(<<"You are a news desk.">>, <<"title: one item">>),
    ?assertEqual(<<"A post.">>, maps:get(body, Reply)),
    ?assertEqual(42, maps:get(tokens, Reply)),
    Request = last_request(),
    %% The method and the path, so an endpoint pointing somewhere else is not a
    %% silent no-op.
    ?assertMatch({_, _}, binary:match(Request, <<"post /v1/chat/completions http/1.1">>)),
    %% The key that was configured, and it is the only place a key appears.
    ?assertMatch({_, _}, binary:match(Request, <<"authorization: bearer test-key">>)),
    %% The model asked for, and the two turns: the charter as the system
    %% message, the item as the user message.
    ?assertMatch({_, _}, binary:match(Request, <<"\"model\":\"test-model\"">>)),
    ?assertMatch({_, _}, binary:match(Request, <<"\"role\":\"system\"">>)),
    ?assertMatch({_, _}, binary:match(Request, <<"you are a news desk.">>)),
    ?assertMatch({_, _}, binary:match(Request, <<"\"role\":\"user\"">>)),
    ?assertMatch({_, _}, binary:match(Request, <<"title: one item">>)),
    %% A reasoning model spends the completion budget on thinking before it
    %% writes, so it is asked to think little and given the ceiling configured.
    ?assertMatch({_, _}, binary:match(Request, <<"\"reasoning_effort\":\"low\"">>)),
    ?assertMatch({_, _}, binary:match(Request, <<"\"max_tokens\":64">>)).

%% The default has to leave a reasoning model room to think AND to write, or the
%% post this service exists to make comes down to how long it thought.
the_default_output_ceiling_leaves_room_to_write_test() ->
    _ = application:unset_env(mcl_spartan, mind_max_tokens),
    ?assertEqual(1024, mind_llm:max_tokens()).

%% ⚠ sys.config substitutes these from the environment, so they arrive as
%% INTEGERS. A reader that only accepted strings took the ceiling and the
%% timeout from the deploy file and ignored both, leaving every deployment on
%% the defaults with nothing saying so.
a_numeric_setting_is_not_ignored_test() ->
    application:set_env(mcl_spartan, mind_max_tokens, 77),
    application:set_env(mcl_spartan, mind_timeout_ms, 12345),
    ?assertEqual(77, mind_llm:max_tokens()),
    ?assertEqual(12345, mind_llm:timeout_ms()),
    application:unset_env(mcl_spartan, mind_max_tokens),
    application:unset_env(mcl_spartan, mind_timeout_ms).

%% ⚠ AND THE OTHER HALF OF THAT: sys.config carries the TEXT ones as STRINGS,
%% which is what the deploy file has. A reader that passed a string through
%% unchanged was handing jsx an Erlang list, which encodes as an ARRAY OF CODE
%% POINTS, not as a JSON string. The live mind asked the endpoint for
%% "model":[111,112,101,...] and the whole request came back refused:
%% "'model' : doesn't match any schema from 'anyOf'". The first deployment
%% found it in the mind's own log, on the first item it heard.
%%
%% The model the endpoint is asked for, in the shape the deploy file gives it.
a_text_setting_from_the_deploy_file_is_a_json_string_test() ->
    _ = with_endpoint(200, answer(<<"A post.">>, 42)),
    %% with_endpoint already set the endpoint as a string, which is the form
    %% sys.config carries; the model is the one this test changes the shape of.
    application:set_env(mcl_spartan, mind_model, "test-model"),
    {ok, _} = mind_llm:reason(<<"charter">>, <<"prompt">>),
    Request = last_request(),
    ?assertMatch({_, _}, binary:match(Request, <<"\"model\":\"test-model\"">>)),
    ?assertEqual(nomatch, binary:match(Request, <<"\"model\":[">>)),
    %% One type out of the reader, whichever form the deploy file used.
    ?assert(is_binary(mind_llm:endpoint())),
    ?assert(is_binary(mind_llm:model())).

%% The same lesson, for a provider whose model comes from the command line
%% rather than from sys.config: a provider setting that arrives as a string and
%% leaves as one would put the code-point array on the wire again.
a_provider_model_from_the_environment_is_a_json_string_test() ->
    _ = with_local_endpoint(200, answer(<<"A post.">>, 42), "local-model"),
    {ok, _} = mind_llm:reason(<<"charter">>, <<"prompt">>),
    Request = last_request(),
    ?assertMatch({_, _}, binary:match(Request, <<"\"model\":\"local-model\"">>)),
    ?assertEqual(nomatch, binary:match(Request, <<"\"model\":[">>)).

%% A reply the endpoint cut off is NOT a post. What comes back is a paragraph
%% ending mid-sentence, and an empty one reads here as "nothing to say", so
%% without this the failure is silent, spends its tokens, and looks like a mind
%% with no opinion.
a_reply_cut_off_by_the_token_limit_is_refused_test() ->
    _ = with_endpoint(200, truncated_answer(<<"A paragraph that stops mid">>)),
    ?assertMatch({error, {all_backends_exhausted, "endpoint", truncated}},
                 mind_llm:reason(<<"charter">>, <<"prompt">>)).

%% What the endpoint reported is what is counted, because the daily cap spends
%% that number.
the_reported_usage_is_the_count_test() ->
    _ = with_endpoint(200, answer(<<"A post.">>, 1234)),
    {ok, Reply} = mind_llm:reason(<<"charter">>, <<"prompt">>),
    ?assertEqual(1234, maps:get(tokens, Reply)).

%% An endpoint that declines to say what the turn cost still costs something,
%% and an under-count here is a cap that does not hold.
an_endpoint_that_reports_no_usage_still_spends_test() ->
    _ = with_endpoint(200, answer_without_usage(<<"A post of some length.">>)),
    {ok, Reply} = mind_llm:reason(<<"charter">>, <<"prompt">>),
    Tokens = maps:get(tokens, Reply),
    ?assert(is_integer(Tokens)),
    ?assert(Tokens > 0).

%% A turn that dies says which backend killed it and why, so the log is the
%% place the next person finds out, rather than a bare "turn failed".
a_refused_call_is_an_error_and_not_an_empty_post_test() ->
    _ = with_endpoint(429, <<"{\"error\":\"rate limited\"}">>),
    ?assertMatch({error, {all_backends_exhausted, "endpoint", {http_status, 429, _, undefined}}},
                 mind_llm:reason(<<"charter">>, <<"prompt">>)).

%% A 429 usually says how long the quota is gone for, and that header is the
%% only thing the breaker has to go on: dropping it means resting for a guess.
a_told_rate_limit_reaches_the_breaker_whole_test() ->
    _ = with_endpoint(429, <<"{\"error\":\"rate limited\"}">>, ["retry-after: 7\r\n"]),
    ?assertMatch({error, {all_backends_exhausted, "endpoint", {http_status, 429, _, 7}}},
                 mind_llm:reason(<<"charter">>, <<"prompt">>)).

a_reply_that_is_not_an_answer_is_refused_test() ->
    _ = with_endpoint(200, <<"{\"nothing\":\"here\"}">>),
    ?assertMatch({error, {all_backends_exhausted, "endpoint", no_choice}},
                 mind_llm:reason(<<"charter">>, <<"prompt">>)).

%% @doc THE POINT OF THE CAROUSEL. A rate-limited provider does not end the
%% turn: the next slot answers, the body that comes back is that slot's, and the
%% tokens that reach the daily budget are the ones the answering slot reported.
%% The breaker remembers the refusal, which is what stops the NEXT turn paying
%% for it again.
a_rate_limited_provider_falls_to_the_next_slot_test() ->
    clear_breaker(),
    _ = with_pool(429, <<"{\"error\":\"rate limited\"}">>,
                  200, answer(<<"A post from the floor.">>, 321)),
    {ok, Reply} = mind_llm:reason(<<"charter">>, <<"prompt">>),
    ?assertEqual(<<"A post from the floor.">>, maps:get(body, Reply)),
    ?assertEqual(321, maps:get(tokens, Reply)),
    ?assertEqual(["endpoint", "local"], providers()),
    ?assertEqual(["endpoint"], resting_providers()).

%% @doc The deliberate deviation from the reference: a turn that dies on its
%% LAST slot is still a failure of that backend, so the breaker rests it. With
%% one provider configured, which is what is live today, the reference left the
%% breaker dead exactly where it matters most and would have rediscovered the
%% same rate limit on every turn.
a_failed_last_slot_is_recorded_test() ->
    clear_breaker(),
    _ = with_endpoint(429, <<"{\"error\":\"rate limited\"}">>),
    ?assertMatch({error, {all_backends_exhausted, "endpoint", _Why}},
                 mind_llm:reason(<<"charter">>, <<"prompt">>)),
    ?assertEqual(["endpoint"], resting_providers()).

%% @doc A provider that does not declare `reasoning_effort` is not sent it. A
%% provider that rejects an unknown field answers 400, which the schedule reads
%% as the moment rather than the backend and fails over from, so a healthy
%% backend would be skipped every turn in silence.
a_provider_that_does_not_take_reasoning_effort_is_not_sent_it_test() ->
    _ = with_local_endpoint(200, answer(<<"A post.">>, 42), "local-model"),
    {ok, _} = mind_llm:reason(<<"charter">>, <<"prompt">>),
    Request = last_request(),
    ?assertEqual(nomatch, binary:match(Request, <<"reasoning_effort">>)),
    ?assertMatch({_, _}, binary:match(Request, <<"post /v1/chat/completions">>)).

%% @doc The keyless floor is called with no credential at all, rather than with
%% a placeholder bearer: the call is the point, and a credential nobody reads is
%% noise in the log of whoever runs the local engine.
a_keyless_provider_is_called_without_an_authorization_header_test() ->
    _ = with_local_endpoint(200, answer(<<"A post.">>, 42), "local-model"),
    {ok, _} = mind_llm:reason(<<"charter">>, <<"prompt">>),
    ?assertEqual(nomatch, binary:match(last_request(), <<"authorization">>)).

providers() ->
    [maps:get(provider, Pool) || Pool <- maps:get(pool, mind_llm:config())].

resting_providers() ->
    [maps:get(provider, Pool) || Pool <- maps:get(pool, mind_llm:config()),
                                 maps:get(resting, Pool)].

clear_breaker() ->
    _ = catch ets:delete(mind_breaker),
    ok.

%%====================================================================
%% The endpoints, on loopback
%%====================================================================

%% One endpoint, named the way W1b's deployment names it. `Extra' is whatever
%% else the answer should carry, which for a 429 is the header that says how
%% long the quota is gone for.
with_endpoint(Status, Body) ->
    with_endpoint(Status, Body, []).

with_endpoint(Status, Body, Extra) ->
    Port = listener({Status, Body, Extra}),
    set_mind(mind_endpoint, url(Port)),
    set_mind(mind_model, <<"test-model">>),
    os:putenv("MCL_MIND_API_KEY", "test-key"),
    os:unsetenv("MCL_MIND_PROVIDERS"),
    os:unsetenv("MCL_MIND_LOCAL_URL"),
    Port.

%% Two of them, named as a pool, with the second as the keyless local floor: the
%% shape a deployment uses to survive one brokered provider failing.
with_pool(FirstStatus, FirstBody, SecondStatus, SecondBody) ->
    FirstPort = listener({FirstStatus, FirstBody, []}),
    SecondPort = listener({SecondStatus, SecondBody, []}),
    set_mind(mind_endpoint, url(FirstPort)),
    set_mind(mind_model, <<"test-model">>),
    os:putenv("MCL_MIND_API_KEY", "test-key"),
    os:putenv("MCL_MIND_PROVIDERS", "endpoint,local"),
    os:putenv("MCL_MIND_LOCAL_URL", url(SecondPort)),
    os:putenv("MCL_MIND_LOCAL_MODEL", "local-model").

%% Only the floor, so the request that goes out is the one the floor makes.
with_local_endpoint(Status, Body, Model) ->
    Port = listener({Status, Body, []}),
    os:putenv("MCL_MIND_PROVIDERS", "local"),
    os:putenv("MCL_MIND_LOCAL_URL", url(Port)),
    os:putenv("MCL_MIND_LOCAL_MODEL", Model),
    os:unsetenv("MCL_MIND_LOCAL_API_KEY"),
    os:unsetenv("MCL_MIND_FALLBACK_PROVIDERS"),
    Port.

set_mind(Key, Value) ->
    _ = application:load(mcl_spartan),
    application:set_env(mcl_spartan, Key, Value),
    application:set_env(mcl_spartan, mind_timeout_ms, 5000),
    application:set_env(mcl_spartan, mind_max_tokens, 64),
    os:unsetenv("MCL_MIND_FALLBACK_PROVIDERS").

url(Port) ->
    "http://127.0.0.1:" ++ integer_to_list(Port) ++ "/v1/chat/completions".

%% A listener on an ephemeral port that answers exactly one request with `Body',
%% and keeps what it was asked so the test can read the call that was made. NOT
%% linked: a test that makes no call leaves it waiting, and a link would take
%% the test down when it gives up.
listener({Status, Body, Extra}) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true},
                                      {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Listen),
    _ = ensure_table(),
    _ = spawn(fun() -> answer_once(Listen, Status, Body, Extra) end),
    Port.

answer_once(Listen, Status, Body, Extra) ->
    answered(gen_tcp:accept(Listen, 5000), Listen, Status, Body, Extra).

answered({ok, Socket}, Listen, Status, Body, Extra) ->
    ets:insert(?TABLE, {last, read_request(Socket, <<>>)}),
    _ = gen_tcp:send(Socket, response(Status, Body, Extra)),
    gen_tcp:close(Socket),
    gen_tcp:close(Listen);
answered({error, _NoCall}, Listen, _Status, _Body, _Extra) ->
    gen_tcp:close(Listen).

%% Headers and the whole declared body, or it is not a complete request.
read_request(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 3000) of
        {ok, Data} -> more(Socket, <<Acc/binary, Data/binary>>);
        {error, _} -> Acc
    end.

more(Socket, Whole) ->
    case complete(Whole) of
        true  -> Whole;
        false -> read_request(Socket, Whole)
    end.

complete(Whole) ->
    case binary:match(Whole, <<"\r\n\r\n">>) of
        nomatch  -> false;
        {Pos, 4} -> byte_size(Whole) >= Pos + 4 + declared_length(Whole, Pos)
    end.

declared_length(Whole, HeaderEnd) ->
    Headers = string:lowercase(binary:part(Whole, 0, HeaderEnd)),
    case binary:match(Headers, <<"content-length: ">>) of
        nomatch -> 0;
        {At, Len} ->
            Rest = binary:part(Headers, At + Len, byte_size(Headers) - At - Len),
            [Number | _] = binary:split(Rest, <<"\r\n">>),
            binary_to_integer(Number)
    end.

last_request() ->
    [{last, Request}] = ets:lookup(?TABLE, last),
    string:lowercase(Request).

ensure_table() ->
    case ets:whereis(?TABLE) of
        undefined -> ets:new(?TABLE, [public, named_table, set]);
        _Existing -> ?TABLE
    end.

response(Status, Body, Extra) ->
    ["HTTP/1.1 ", integer_to_list(Status), " ", reason(Status), "\r\n",
     "content-type: application/json\r\n",
     Extra,
     "content-length: ", integer_to_list(byte_size(Body)), "\r\n",
     "connection: close\r\n\r\n", Body].

reason(200) -> "OK";
reason(429) -> "Too Many Requests";
reason(_)   -> "Error".

answer(Body, Total) ->
    jsx:encode(#{<<"choices">> => [#{<<"message">> => #{<<"content">> => Body}}],
                 <<"usage">> => #{<<"total_tokens">> => Total}}).

answer_without_usage(Body) ->
    jsx:encode(#{<<"choices">> => [#{<<"message">> => #{<<"content">> => Body}}]}).

truncated_answer(Body) ->
    jsx:encode(#{<<"choices">> => [#{<<"message">> => #{<<"content">> => Body},
                                    <<"finish_reason">> => <<"length">>}]}).
