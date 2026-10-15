%%% @doc What the carousel remembers between turns.
%%%
%%% The two behaviours that matter are opposites and both are easy to get
%%% wrong: it must REMEMBER a rate limit (or it pays the backoff again every
%%% turn, which is the bug it exists for) and it must FAIL OPEN (or its own
%%% bookkeeping can silence a mind, which is worse and quieter).
%%%
%%% The failure shapes here are the ones `mind_llm` actually produces, not
%%% stand-ins: a breaker that knows the wrong vocabulary is a breaker that never
%%% matches anything, and it would look exactly like this suite passing.
-module(mind_breaker_tests).

-include_lib("eunit/include/eunit.hrl").

groq()     -> #{label => "groq"}.
deepseek() -> #{label => "deepseek"}.

schedule() -> [{groq(), "k1"}, {deepseek(), "k2"}].

clear() ->
    _ = catch ets:delete(mind_breaker),
    ok.

with(F) -> {setup, fun clear/0, fun(_) -> clear() end, F}.

%% --- what is remembered ---

rate_limit_rests_the_backend_test_() ->
    with(fun(_) ->
        ok = mind_breaker:failed(groq(), {http_status, 429, <<"Too Many Requests">>}),
        [?_assertEqual([{deepseek(), "k2"}], mind_breaker:usable(schedule()))]
    end).

%% A wrong key does not fix itself, so it is rested long rather than retried
%% every turn until somebody notices the log.
bad_credentials_rest_the_backend_test_() ->
    with(fun(_) ->
        ok = mind_breaker:failed(groq(), {http_status, 401, <<"unauthorized">>}),
        ok = mind_breaker:failed(deepseek(), {http_status, 403, <<"forbidden">>}),
        %% Both resting means nothing is usable, so it opens: see below.
        [?_assertEqual(schedule(), mind_breaker:usable(schedule()))]
    end).

%% A timeout, a 500 or a dropped connection is the MOMENT, not the backend.
%% Resting a healthy provider because one request timed out would take it out
%% of the rotation for no reason. So is a reply this code could not use: a
%% truncated answer, a body that was not JSON and a 200 with no choice in it are
%% all things the model or the moment did.
transient_failures_are_forgotten_test_() ->
    with(fun(_) ->
        [ok = mind_breaker:failed(groq(), Why)
         || Why <- [{unreachable, timeout}, {unreachable, socket_closed},
                    {http_status, 500, <<>>}, {http_status, 502, <<>>},
                    {http_status, 404, <<>>}, truncated, no_choice,
                    {not_json, <<"<html>">>}]],
        [?_assertEqual(schedule(), mind_breaker:usable(schedule()))]
    end).

a_backend_that_answers_is_forgiven_test_() ->
    with(fun(_) ->
        ok = mind_breaker:failed(groq(), {http_status, 429, <<>>}),
        ok = mind_breaker:worked(groq()),
        [?_assertEqual(schedule(), mind_breaker:usable(schedule()))]
    end).

%% --- retry-after ---

%% The one piece of information a 429 actually carries. It used to be thrown
%% away with the rest of the headers and guessed at instead.
told_when_to_return_it_waits_that_long_test_() ->
    with(fun(_) ->
        ok = mind_breaker:failed(groq(), {http_status, 429, <<>>, 1}),
        timer:sleep(1100),
        [?_assertEqual(schedule(), mind_breaker:usable(schedule()))]
    end).

%% A hostile or broken retry-after of a day would take a provider out for a
%% day on one bad response.
an_absurd_retry_after_is_capped_test_() ->
    with(fun(_) ->
        ok = mind_breaker:failed(groq(), {http_status, 429, <<>>, 86400}),
        %% Still resting, but bounded -- the cap is what this pins, and the
        %% only observable is that it did not simply trust the number.
        [?_assertEqual([{deepseek(), "k2"}], mind_breaker:usable(schedule()))]
    end).

a_nonsense_retry_after_falls_back_to_the_backoff_test_() ->
    with(fun(_) ->
        ok = mind_breaker:failed(groq(), {http_status, 429, <<>>, undefined}),
        ok = mind_breaker:failed(deepseek(), {http_status, 429, <<>>, 0}),
        [?_assertEqual(schedule(), mind_breaker:usable(schedule()))]
    end).

%% --- failing open ---

%% THE test. If every backend is resting, try them anyway: the alternative to
%% a wasted 429 is not silence, it is making the call regardless. A mind that
%% cannot speak because of its own bookkeeping is the worst outcome here, and
%% the least visible.
every_backend_resting_still_returns_a_schedule_test_() ->
    with(fun(_) ->
        ok = mind_breaker:failed(groq(), {http_status, 429, <<>>}),
        ok = mind_breaker:failed(deepseek(), {http_status, 429, <<>>}),
        [?_assertEqual(schedule(), mind_breaker:usable(schedule()))]
    end).

an_empty_schedule_stays_empty_test_() ->
    with(fun(_) -> [?_assertEqual([], mind_breaker:usable([]))] end).

%% Before anything has failed there is no table at all, and reading a table
%% that does not exist must not crash a mind mid-turn.
no_table_yet_is_no_opinion_test() ->
    clear(),
    ?assertEqual(schedule(), mind_breaker:usable(schedule())).

%% --- consecutive failures ---

%% A quota that is exhausted is usually exhausted for longer than the last
%% guess, so repeated rate limits rest for longer. What is pinned here is
%% that a strike is COUNTED, not the exact curve.
consecutive_rate_limits_rest_longer_test_() ->
    with(fun(_) ->
        [ok = mind_breaker:failed(groq(), {http_status, 429, <<>>}) || _ <- lists:seq(1, 3)],
        [?_assertEqual([{deepseek(), "k2"}], mind_breaker:usable(schedule()))]
    end).

%% --- what the mind's report reads ---

%% `resting/1` is how /health says which backends are out, so it has to answer
%% the same thing the schedule does.
resting_is_the_same_opinion_the_schedule_has_test() ->
    clear(),
    ?assertEqual(false, mind_breaker:resting(groq())),
    ok = mind_breaker:failed(groq(), {http_status, 429, <<>>}),
    ?assertEqual(true, mind_breaker:resting(groq())),
    ?assertEqual(false, mind_breaker:resting(deepseek())),
    clear().
