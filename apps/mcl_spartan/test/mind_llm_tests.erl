%% @doc The one call: the request that goes out, and what comes back.
%%
%% The mind's tests fake this module, so without a test like this the HTTP path
%% would first run for real on a box, which is the wrong place to find out what
%% an endpoint says. A stub on loopback exercises the real request, the real
%% parse and the real token count, and needs neither a key nor a network.
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
%% post this increment exists to make comes down to how long it thought.
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

%% A reply the endpoint cut off is NOT a post. What comes back is a paragraph
%% ending mid-sentence, and an empty one reads here as "nothing to say", so
%% without this the failure is silent, spends its tokens, and looks like a mind
%% with no opinion.
a_reply_cut_off_by_the_token_limit_is_refused_test() ->
    _ = with_endpoint(200, truncated_answer(<<"A paragraph that stops mid">>)),
    ?assertEqual({error, truncated}, mind_llm:reason(<<"charter">>, <<"prompt">>)).

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

a_refused_call_is_an_error_and_not_an_empty_post_test() ->
    _ = with_endpoint(429, <<"{\"error\":\"rate limited\"}">>),
    ?assertMatch({error, {http_status, 429, _}}, mind_llm:reason(<<"charter">>, <<"prompt">>)).

a_reply_that_is_not_an_answer_is_refused_test() ->
    _ = with_endpoint(200, <<"{\"nothing\":\"here\"}">>),
    ?assertEqual({error, no_choice}, mind_llm:reason(<<"charter">>, <<"prompt">>)).

%%====================================================================
%% The endpoint, on loopback
%%====================================================================

%% A listener on an ephemeral port that answers exactly one request with `Body',
%% and keeps what it was asked so the test can read the call that was made. NOT
%% linked: a test that makes no call leaves it waiting, and a link would take
%% the test down when it gives up.
with_endpoint(Status, Body) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true},
                                      {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Listen),
    _ = ensure_table(),
    Server = spawn(fun() -> answer_once(Listen, Status, Body) end),
    _ = application:load(mcl_spartan),
    application:set_env(mcl_spartan, mind_endpoint,
                        "http://127.0.0.1:" ++ integer_to_list(Port) ++ "/v1/chat/completions"),
    application:set_env(mcl_spartan, mind_model, <<"test-model">>),
    application:set_env(mcl_spartan, mind_api_key, <<"test-key">>),
    application:set_env(mcl_spartan, mind_timeout_ms, 5000),
    application:set_env(mcl_spartan, mind_max_tokens, 64),
    #{port => Port, server => Server, listen => Listen}.

answer_once(Listen, Status, Body) ->
    answered(gen_tcp:accept(Listen, 5000), Listen, Status, Body).

answered({ok, Socket}, Listen, Status, Body) ->
    ets:insert(?TABLE, {last, read_request(Socket, <<>>)}),
    _ = gen_tcp:send(Socket, response(Status, Body)),
    gen_tcp:close(Socket),
    gen_tcp:close(Listen);
answered({error, _NoCall}, Listen, _Status, _Body) ->
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

response(Status, Body) ->
    ["HTTP/1.1 ", integer_to_list(Status), " ", reason(Status), "\r\n",
     "content-type: application/json\r\n",
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
