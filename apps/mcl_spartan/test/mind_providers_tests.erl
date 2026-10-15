%%% @doc The pool a mind walks, and the schedule built from it.
%%%
%%% Ported from hecate-spartan's `provider_carousel_tests`, which covered how
%%% the pool is read from the environment, and extended with the part that has
%%% the actual claim in it: the SHAPE OF THE SCHEDULE. One slot per (provider,
%%% key), providers interleaved so a failure falls to a different provider next,
%%% and the fallback floor appended after the whole thing and never mixed in.
%%%
%%% None of this needs a network. A schedule is a list of slots, and inspecting
%%% it is the only way to see the property the schedule exists for.
-module(mind_providers_tests).

-include_lib("eunit/include/eunit.hrl").

-define(LOCAL_URL, "http://127.0.0.1:8000/v1/chat/completions").

%% Every environment variable these tests can set or be affected by.
-define(TOUCHED, ["MCL_MIND_PROVIDERS", "MCL_MIND_FALLBACK_PROVIDERS", "MCL_MIND_LOCAL_URL",
                  "MCL_MIND_API_KEY", "GROQ_API_KEYS", "DEEPSEEK_API_KEYS", "MELIOUS_API_KEY",
                  "MISTRAL_API_KEYS", "MCL_MIND_LOCAL_API_KEY"]).

%% --- which pool a deployment names ---

providers_env_wins_test() ->
    with_env("MCL_MIND_PROVIDERS", "mistral,deepseek,melious", fun() ->
        ?assertEqual(<<"mistral,deepseek,melious">>, mind_llm:provider_labels())
    end).

providers_env_trims_and_drops_blanks_test() ->
    with_env("MCL_MIND_PROVIDERS", " groq , , deepseek ", fun() ->
        ?assertEqual(<<"groq,deepseek">>, mind_llm:provider_labels())
    end).

%% With no pool named, the endpoint W1b deployed is a POOL OF ONE. A mind that
%% is live keeps thinking while the deeper pool is a deployment change rather
%% than a second release.
no_pool_named_is_the_configured_endpoint_test() ->
    with_unset("MCL_MIND_PROVIDERS", fun() ->
        ?assertEqual(<<"endpoint">>, mind_llm:provider_labels())
    end).

fallback_is_its_own_list_test() ->
    with_vars([{"MCL_MIND_FALLBACK_PROVIDERS", "local"}, {"MCL_MIND_LOCAL_URL", ?LOCAL_URL}],
              fun() ->
                  ?assertEqual(<<"local">>, mind_llm:fallback_labels())
              end).

no_fallback_is_the_empty_list_test() ->
    with_vars([], fun() ->
        ?assertEqual(<<>>, mind_llm:fallback_labels())
    end).

%% --- the provider clauses ---

%% Only providers whose keys answer today are here. A ported constant naming a
%% model that has since been retired is a backend that fails every turn and is
%% skipped by the schedule in silence; the old code carried two of those.
the_pooled_providers_are_the_ones_worth_calling_test() ->
    Groq = mind_llm:provider_config("groq"),
    ?assertEqual("https://api.groq.com/openai/v1/chat/completions", maps:get(url, Groq)),
    ?assertEqual("GROQ_API_KEYS", maps:get(keyenv, Groq)),
    ?assertEqual(<<"openai/gpt-oss-20b">>, maps:get(model, Groq)),
    Deepseek = mind_llm:provider_config("deepseek"),
    ?assertEqual("https://api.deepseek.com/v1/chat/completions", maps:get(url, Deepseek)),
    ?assertEqual("DEEPSEEK_API_KEYS", maps:get(keyenv, Deepseek)),
    ?assertEqual(<<"deepseek-chat">>, maps:get(model, Deepseek)),
    ?assertEqual("MELIOUS_API_KEY", maps:get(keyenv, mind_llm:provider_config("melious"))),
    ?assertEqual("MISTRAL_API_KEYS", maps:get(keyenv, mind_llm:provider_config("mistral"))),
    ?assertEqual(undefined, mind_llm:provider_config("cerebras")).

%% A model that moves with the provider's catalog is env-driven, so it can be
%% repointed without a rebuild.
a_model_can_be_moved_without_a_rebuild_test() ->
    with_env("MCL_DEEPSEEK_MODEL", "deepseek-reasoner", fun() ->
        ?assertEqual(<<"deepseek-reasoner">>,
                     maps:get(model, mind_llm:provider_config("deepseek")))
    end).

%% `reasoning_effort` is not part of the compatible subset every provider
%% accepts, so it is declared where the model is a reasoning model and nowhere
%% else: a provider that rejects an unknown field answers 400, which the
%% schedule treats as the moment and fails over from, skipping a healthy
%% backend in silence.
reasoning_effort_is_declared_only_where_it_belongs_test() ->
    ?assertEqual(<<"low">>, maps:get(reasoning_effort, mind_llm:provider_config("groq"))),
    ?assertEqual(<<"low">>, maps:get(reasoning_effort, mind_llm:provider_config("melious"))),
    ?assertEqual(undefined,
                 maps:get(reasoning_effort, mind_llm:provider_config("deepseek"), undefined)),
    ?assertEqual(undefined,
                 maps:get(reasoning_effort, mind_llm:provider_config("mistral"), undefined)).

%% --- the local floor ---

%% A local engine is a deployment fact (which box hosts it, which model it was
%% converted to), so this provider exists only when a deployment names one. A
%% baked-in localhost default would turn a misconfiguration into a silent call
%% to nowhere.
the_local_floor_exists_only_when_a_deployment_names_one_test() ->
    with_unset("MCL_MIND_LOCAL_URL", fun() ->
        ?assertEqual(undefined, mind_llm:provider_config("local"))
    end).

the_local_floor_is_keyless_and_patient_test() ->
    with_env("MCL_MIND_LOCAL_URL", ?LOCAL_URL, fun() ->
        Cfg = mind_llm:provider_config("local"),
        ?assertEqual(?LOCAL_URL, maps:get(url, Cfg)),
        ?assertEqual(true, maps:get(key_optional, Cfg)),
        %% Seconds per token, so it gets its own patience and its own short cap.
        ?assert(maps:get(timeout, Cfg) >= 300000),
        ?assert(maps:get(max_tokens, Cfg) < 500)
    end).

%% --- the schedule ---

%% THE PROPERTY THE SCHEDULE EXISTS FOR. Two keys on one provider and one on
%% another must interleave, so the slot after a failure is a DIFFERENT provider
%% rather than the next key of the one that just failed.
a_second_key_does_not_crowd_out_the_other_provider_test() ->
    with_vars([{"MCL_MIND_PROVIDERS", "groq,deepseek"}, {"GROQ_API_KEYS", "g1,g2"},
               {"DEEPSEEK_API_KEYS", "d1"}],
              fun() ->
                  Plan = mind_llm:plan(),
                  ?assertEqual(["groq", "deepseek", "groq"], labels(Plan)),
                  ?assertEqual([{"deepseek", "d1"}, {"groq", "g1"}, {"groq", "g2"}],
                               lists:sort(backends(Plan)))
              end).

%% One slot per (provider, key): every backend is tried once, and none twice.
every_slot_is_a_different_backend_test() ->
    with_vars([{"MCL_MIND_PROVIDERS", "groq,deepseek,melious"}, {"GROQ_API_KEYS", "g1,g2"},
               {"DEEPSEEK_API_KEYS", "d1"}, {"MELIOUS_API_KEY", "m1"}],
              fun() ->
                  Plan = mind_llm:plan(),
                  ?assertEqual(4, length(Plan)),
                  ?assertEqual(lists:usort(backends(Plan)), lists:sort(backends(Plan))),
                  ?assertEqual(["groq", "deepseek", "melious", "groq"], labels(Plan))
              end).

%% A keyed provider with no key is not in the pool at all: a slot that cannot
%% authenticate spends a call to learn what the log already knows.
a_provider_with_no_key_is_not_pooled_test() ->
    with_vars([{"MCL_MIND_PROVIDERS", "groq,deepseek"}, {"GROQ_API_KEYS", "g1"}],
              fun() ->
                  ?assertEqual(["groq"], labels(mind_llm:plan()))
              end).

%% The pool is a key POOL: several credentials against one provider's per-key
%% quota.
a_pool_of_keys_is_several_slots_test() ->
    with_vars([{"MCL_MIND_PROVIDERS", "groq"}, {"GROQ_API_KEYS", " g1 , g2 ,, g3 "}],
              fun() ->
                  ?assertEqual([{"groq", "g1"}, {"groq", "g2"}, {"groq", "g3"}],
                               lists:sort(backends(mind_llm:plan())))
              end).

%% --- the floor ---

%% The fallback is appended AFTER the whole pool and never shuffled into it: it
%% is the floor, not another provider competing for a normal turn.
the_fallback_comes_last_test() ->
    with_vars([{"MCL_MIND_PROVIDERS", "groq"}, {"GROQ_API_KEYS", "g1"},
               {"MCL_MIND_FALLBACK_PROVIDERS", "local"}, {"MCL_MIND_LOCAL_URL", ?LOCAL_URL}],
              fun() ->
                  ?assertEqual(["groq", "local"], labels(mind_llm:plan()))
              end).

%% A provider already in the pool is not repeated as a fallback: every key of
%% it was just tried, and the first key again is the most likely one to be
%% rate-limited.
a_pooled_provider_is_not_repeated_as_a_fallback_test() ->
    with_vars([{"MCL_MIND_PROVIDERS", "groq"}, {"GROQ_API_KEYS", "g1"},
               {"MCL_MIND_FALLBACK_PROVIDERS", "groq,local"}, {"MCL_MIND_LOCAL_URL", ?LOCAL_URL}],
              fun() ->
                  ?assertEqual(["groq", "local"], labels(mind_llm:plan()))
              end).

%% --- what /health reads ---

the_report_says_which_backends_are_resting_test() ->
    clear_breaker(),
    with_vars([{"MCL_MIND_PROVIDERS", "groq"}, {"GROQ_API_KEYS", "g1,g2"}],
              fun() ->
                  ok = mind_breaker:failed(#{label => "groq"}, {http_status, 429, <<>>}),
                  ?assertEqual([#{provider => "groq", model => <<"openai/gpt-oss-20b">>,
                                  keys => 2, resting => true}],
                               maps:get(pool, mind_llm:config()))
              end),
    clear_breaker().

%% A config dump goes to /health and into logs, so it carries a key COUNT and
%% never a key. The mind's own report is the one place a credential could leak
%% without anybody noticing it had.
the_report_never_carries_a_key_test() ->
    with_vars([{"MCL_MIND_PROVIDERS", "groq"}, {"GROQ_API_KEYS", "secret-g1"}],
              fun() ->
                  Rendered = iolist_to_binary(io_lib:format("~p", [mind_llm:config()])),
                  ?assertEqual(nomatch, binary:match(Rendered, <<"secret-g1">>)),
                  ?assertMatch({_, _}, binary:match(Rendered, <<"keys => 1">>))
              end).

%%====================================================================
%% Helpers
%%====================================================================

labels(Plan) ->
    [maps:get(label, Config) || {Config, _Key} <- Plan].

backends(Plan) ->
    [{maps:get(label, Config), Key} || {Config, Key} <- Plan].

%% Set exactly the variables a case names and clear every other one these tests
%% can see, so one case cannot be decided by what another left behind. Whatever
%% was there is restored, because the mind reads the real environment.
with_vars(Vars, Fun) ->
    Saved = [{Var, os:getenv(Var)} || Var <- ?TOUCHED],
    [os:unsetenv(Var) || Var <- ?TOUCHED],
    [os:putenv(Var, Value) || {Var, Value} <- Vars],
    try Fun() after [restore(Var, Value) || {Var, Value} <- Saved] end.

with_env(Var, Value, Fun) ->
    with_vars([{Var, Value}], Fun).

%% Empty is unset, which is the same rule the readers themselves use.
with_unset(Var, Fun) ->
    with_vars([{Var, ""}], Fun).

restore(Var, false) -> os:unsetenv(Var);
restore(Var, Value) -> os:putenv(Var, Value).

clear_breaker() ->
    _ = catch ets:delete(mind_breaker),
    ok.
