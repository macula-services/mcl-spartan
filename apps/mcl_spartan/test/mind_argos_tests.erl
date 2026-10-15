%% @doc What the mind has seen of each model, and what it says about it.
%%
%% The record is only half the point. The other half is that a model which has
%% gone missing is SAID OUT LOUD, so the loud line is asserted here rather than
%% assumed: a fact nobody is told about is a fact nobody acts on, and the line
%% is the difference between this module and the silence it exists to end.
-module(mind_argos_tests).

-include_lib("eunit/include/eunit.hrl").

%% The logger calls this module as a handler, so it has to be part of its
%% interface rather than an internal detail.
-export([log/2]).

%%====================================================================
%% What is recorded
%%====================================================================

%% A success is a DATE and the end of the run: the record says when the model
%% last answered, and it stops counting.
a_success_is_dated_and_clears_the_run_test() ->
    fresh(),
    ok = mind_argos:failed(<<"nvidia">>, <<"m1">>, {http_status, 500, <<>>}, 1),
    ok = mind_argos:failed(<<"nvidia">>, <<"m1">>, {http_status, 500, <<>>}, 2),
    ok = mind_argos:succeeded(<<"nvidia">>, <<"m1">>),
    Seen = seen(<<"nvidia">>, <<"m1">>),
    ?assertEqual(0, maps:get(consecutive, Seen)),
    ?assert(within(maps:get(last_success_at, Seen), 5)),
    %% The failure that happened is still dated, and still has its class: a
    %% success clears the RUN, not the history.
    ?assertEqual(server, maps:get(class, Seen)),
    ?assert(maps:get(last_failure_at, Seen) =< maps:get(last_success_at, Seen)).

%% ⚠ A MODEL THAT IS GONE IS NOT A GENERIC FAILURE. 404 and 410 are the one
%% class that means the model is not there any more, and they are the reason
%% this record exists: the breaker cannot hold them, because its memory is rate
%% limits and credentials.
a_missing_model_is_recorded_as_gone_test() ->
    fresh(),
    ok = mind_argos:failed(<<"nvidia">>, <<"retired">>, {http_status, 404, <<"not found">>}, 1),
    ?assertEqual(gone, maps:get(class, seen(<<"nvidia">>, <<"retired">>))),
    ok = mind_argos:failed(<<"cerebras">>, <<"also-retired">>, {http_status, 410, <<"gone">>}, 1),
    ?assertEqual(gone, maps:get(class, seen(<<"cerebras">>, <<"also-retired">>))).

%% The classes the pool already talks in, so the two records can be read side by
%% side without translating between them. A rate limit is NOT a missing model,
%% and reading one as the other would retire a working model.
every_failure_is_classified_in_the_pool_s_own_vocabulary_test() ->
    fresh(),
    Cases = [{rate_limited, {http_status, 429, <<>>}},
             {rate_limited, {http_status, 429, <<>>, 7}},
             {credential, {http_status, 401, <<>>}},
             {credential, {http_status, 403, <<>>}},
             {server, {http_status, 500, <<>>}},
             {server, {http_status, 503, <<>>}},
             {timeout, {unreachable, timeout}},
             {unreachable, {unreachable, econnrefused}},
             {parse, truncated},
             {parse, no_choice},
             {parse, {not_json, <<"<html>">>}},
             {other, something_we_have_never_seen}],
    [?assertEqual(Expected, class_after(Why)) || {Expected, Why} <- Cases].

class_after(Why) ->
    Model = unicode:characters_to_binary(io_lib:format("~p", [Why])),
    ok = mind_argos:failed(<<"p">>, Model, Why, 1),
    maps:get(class, seen(<<"p">>, Model)).

%% One provider, several models: the record is keyed on the PAIR, because that
%% is the granularity the fact has. A provider retiring one model says nothing
%% about its others, and this is the whole reason the breaker could not hold it.
one_model_going_does_not_touch_its_neighbours_test() ->
    fresh(),
    ok = mind_argos:failed(<<"nvidia">>, <<"m1">>, {http_status, 410, <<>>}, 1),
    ok = mind_argos:succeeded(<<"nvidia">>, <<"m2">>),
    ?assertEqual(gone, maps:get(class, seen(<<"nvidia">>, <<"m1">>))),
    ?assertEqual(undefined, maps:get(class, seen(<<"nvidia">>, <<"m2">>))),
    ?assertEqual(0, maps:get(consecutive, seen(<<"nvidia">>, <<"m2">>))).

%%====================================================================
%% Saying it loudly
%%====================================================================

a_model_that_is_gone_is_said_loudly_test() ->
    fresh(),
    Lines = with_logger(fun() ->
                            ok = mind_argos:failed(<<"nvidia">>, <<"retired">>,
                                                   {http_status, 404, <<>>}, 1),
                            ok = mind_argos:failed(<<"nvidia">>, <<"retired">>,
                                                   {http_status, 404, <<>>}, 2)
                        end),
    %% ONCE, at the first, and not again while it stays gone: a line per turn
    %% forever would be the noise the record exists to cut through.
    ?assertEqual(1, length(Lines)),
    ?assert(match(Lines, "retired")),
    ?assert(match(Lines, "nvidia")),
    %% And it says the thing that matters: the pool still calls it.
    ?assert(match(Lines, "still calls it")).

%% ⚠ THE THREE ARE THREE TURNS, and that is the whole of the assertion: the
%% schedule holds one slot per (provider, key), so the same pair can be walked
%% three times inside ONE turn by a provider with three keys. Counting those
%% would say "3 turns in a row" about a single bad moment, which is the lie this
%% test exists to stop, so the repeats within a turn are pinned separately below.
three_failures_in_a_row_are_said_loudly_once_test() ->
    fresh(),
    Lines = with_logger(fun() ->
                            [ok = mind_argos:failed(<<"groq">>, <<"m">>, {http_status, 500, <<>>}, Turn)
                             || Turn <- [1, 2, 3]],
                            ok = mind_argos:failed(<<"groq">>, <<"m">>, {http_status, 500, <<>>}, 4)
                        end),
    ?assertEqual(1, length(Lines)),
    ?assert(match(Lines, "3 turns in a row")).

%% ⚠ THE SAME PAIR, TRIED ONCE PER KEY, IS ONE FAILURE AND NOT THREE. This is
%% what a provider with a key pool actually does: every_backend_once/1 builds one
%% slot per (provider, key), so three keys walk {Provider, Model} three times in
%% one turn. Before this was pinned, one 503 moment reached the threshold and said
%% "has failed 3 turns in a row" while the mind had had exactly one bad turn.
repeats_of_one_pair_within_a_turn_are_one_failure_test() ->
    fresh(),
    Lines = with_logger(fun() ->
                            [ok = mind_argos:failed(<<"nvidia">>, <<"m">>, {http_status, 503, <<>>}, 7)
                             || _ <- lists:seq(1, 3)]
                        end),
    ?assertEqual(1, maps:get(consecutive, seen(<<"nvidia">>, <<"m">>))),
    %% And nothing is said: one turn is a moment, not a run.
    ?assertEqual([], Lines).

%% The turn a pair failed in is remembered, and the NEXT turn counts: a repeat
%% inside one turn is one failure, a repeat across turns is two.
a_failure_in_a_later_turn_counts_again_test() ->
    fresh(),
    ok = mind_argos:failed(<<"groq">>, <<"m">>, {http_status, 500, <<>>}, 11),
    ok = mind_argos:failed(<<"groq">>, <<"m">>, {http_status, 500, <<>>}, 11),
    ?assertEqual(1, maps:get(consecutive, seen(<<"groq">>, <<"m">>))),
    ok = mind_argos:failed(<<"groq">>, <<"m">>, {http_status, 500, <<>>}, 12),
    ?assertEqual(2, maps:get(consecutive, seen(<<"groq">>, <<"m">>))).

%% A success ends the run, and the turn marker goes with it: a failure after a
%% success is the first of a new run even when it lands in the same turn, rather
%% than a repeat of the run that has just been cleared. The failure BEFORE the
%% success is what makes this discriminating: without the marker being cleared,
%% the third call here would look like the repeat of a run already ended and
%% would leave the count at zero.
a_failure_after_a_success_in_the_same_turn_starts_a_new_run_test() ->
    fresh(),
    ok = mind_argos:failed(<<"groq">>, <<"m">>, {http_status, 500, <<>>}, 9),
    ok = mind_argos:succeeded(<<"groq">>, <<"m">>),
    ok = mind_argos:failed(<<"groq">>, <<"m">>, {http_status, 500, <<>>}, 9),
    ?assertEqual(1, maps:get(consecutive, seen(<<"groq">>, <<"m">>))).

%% ⚠ A LATCH SPENT ON SOMETHING ELSE MUST NOT BUY SILENCE FOR THIS. Three 5xx
%% say their piece and latch; a 410 arriving after them is a model going away,
%% and it is the loudest fact this record has. Before this was pinned, that 410
%% was exactly what the latch swallowed: the mind would have gone quiet about the
%% one thing it exists to say.
a_model_that_goes_gone_after_a_run_of_servers_is_still_said_test() ->
    fresh(),
    Lines = with_logger(fun() ->
                            [ok = mind_argos:failed(<<"groq">>, <<"m">>, {http_status, 500, <<>>}, Turn)
                             || Turn <- [1, 2, 3]],
                            ok = mind_argos:failed(<<"groq">>, <<"m">>, {http_status, 410, <<>>}, 4)
                        end),
    %% Two lines: the run of servers says its piece at the third, and the 410
    %% adds its own rather than being folded into a latch already spent.
    ?assertEqual(2, length(Lines)),
    ?assert(match(Lines, "GONE")),
    ?assertEqual(gone, maps:get(class, seen(<<"groq">>, <<"m">>))).

%% And only the TRANSITION is said. A model that is gone stays quiet after it has
%% said so, or a retired id would be one line per turn forever, which is the
%% noise the latch is there to prevent.
a_model_that_stays_gone_is_said_once_test() ->
    fresh(),
    Lines = with_logger(fun() ->
                            [ok = mind_argos:failed(<<"groq">>, <<"m">>, {http_status, 410, <<>>}, Turn)
                             || Turn <- [1, 2, 3]]
                        end),
    ?assertEqual(1, length(Lines)).

%% A success ends the outage, so the NEXT run of failures is a new one and is
%% said again: a mind that went quiet for an hour should not stay quiet about
%% the next one.
a_success_lets_the_next_run_be_said_again_test() ->
    fresh(),
    Lines = with_logger(fun() ->
                            [ok = mind_argos:failed(<<"groq">>, <<"m">>, {http_status, 500, <<>>}, Turn)
                             || Turn <- [1, 2, 3]],
                            ok = mind_argos:succeeded(<<"groq">>, <<"m">>),
                            [ok = mind_argos:failed(<<"groq">>, <<"m">>, {http_status, 500, <<>>}, Turn)
                             || Turn <- [4, 5, 6]]
                        end),
    ?assertEqual(2, length(Lines)).

%% VISIBILITY, NOT RESTING. This is the seam where the two could be confused, so
%% it is asserted here: a 404 is recorded as gone and the provider it belongs to
%% is NOT rested, because resting a provider over one retired MODEL would take
%% that provider's working models down with it.
a_gone_model_does_not_rest_its_provider_test() ->
    fresh(),
    _ = catch ets:delete(mind_breaker),
    Provider = #{label => "nvidia"},
    ok = mind_argos:failed(<<"nvidia">>, <<"retired">>, {http_status, 404, <<>>}, 1),
    ?assertEqual(false, mind_breaker:resting(Provider)),
    ?assertEqual([{Provider, "k"}], mind_breaker:usable([{Provider, "k"}])).

%%====================================================================
%% The file: dates on disk, counters in memory
%%====================================================================

%% A dated fact that forgets its date on a restart is not dated. The dates come
%% back off the file; the run does not, because a run does not survive the
%% process that was having it.
the_dates_survive_a_restart_and_the_counters_do_not_test() ->
    fresh(),
    [ok = mind_argos:failed(<<"nvidia">>, <<"m">>, {http_status, 410, <<>>}, Turn)
     || Turn <- [1, 2, 3]],
    Before = seen(<<"nvidia">>, <<"m">>),
    restarted(),
    After = seen(<<"nvidia">>, <<"m">>),
    ?assertEqual(maps:get(last_failure_at, Before), maps:get(last_failure_at, After)),
    ?assertEqual(gone, maps:get(class, After)),
    ?assertEqual(0, maps:get(consecutive, After)).

%% ⚠ A FILE THAT CANNOT BE READ IS NO RECORD, NEVER A CRASH. A mind that cannot
%% think because it cannot read its own notes is worse in every direction than a
%% mind that has forgotten them, which is the same bargain the day's ledger
%% makes.
a_corrupt_file_reads_as_no_record_test() ->
    fresh(),
    ok = file:write_file(path(), <<"not a term at all">>),
    restarted(),
    %% Nothing recorded before it was corrupted comes back, and the mind carries
    %% on: the date it writes next is the first thing the record has.
    ok = mind_argos:succeeded(<<"nvidia">>, <<"m">>),
    Seen = seen(<<"nvidia">>, <<"m">>),
    ?assertEqual(undefined, maps:get(last_failure_at, Seen)),
    ?assertEqual(undefined, maps:get(class, Seen)),
    ?assertEqual(0, maps:get(consecutive, Seen)),
    ?assert(within(maps:get(last_success_at, Seen), 5)).

a_missing_file_reads_as_no_record_test() ->
    fresh(),
    _ = file:delete(path()),
    restarted(),
    ?assertEqual([], [Row || Row <- mind_argos:report(), maps:get(model, Row) =:= <<"m">>]).

%% Every write goes through a temporary and a rename, so a reader sees the old
%% file or the new one and never half of either. What this pins is the
%% consequence a test can see: no temporary is left behind.
no_temporary_is_left_behind_test() ->
    fresh(),
    ok = mind_argos:succeeded(<<"groq">>, <<"m">>),
    ?assertNot(filelib:is_regular(path() ++ ".tmp")),
    ?assert(filelib:is_regular(path())).

%%====================================================================
%% Helpers
%%====================================================================

%% A clean slate: no table, no file, and a data directory of this test's own.
fresh() ->
    _ = catch ets:delete(mind_argos),
    _ = application:load(mcl_spartan),
    application:set_env(mcl_spartan, data_dir, data_dir()),
    _ = file:del_dir_r(data_dir()),
    ok = filelib:ensure_path(data_dir()),
    ok.

%% A process that was restarted: what is in memory is gone, what is on disk is
%% still there.
restarted() ->
    _ = catch ets:delete(mind_argos),
    ok.

seen(Provider, Model) ->
    [Row] = [R || R <- mind_argos:report(),
                  maps:get(provider, R) =:= Provider, maps:get(model, R) =:= Model],
    Row.

within(undefined, _Seconds) -> false;
within(At, Seconds) -> erlang:system_time(second) - At =< Seconds.

path() -> filename:join(data_dir(), "mind_argos.term").

data_dir() -> filename:join(tmpdir(), "mcl_spartan_argos_test").

tmpdir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Dir   -> Dir
    end.

%% A logger handler that forwards error events to this process, so the loud line
%% is READ by the test rather than assumed by it.
with_logger(Fun) ->
    _ = drain(),
    ok = logger:add_handler(argos_test, ?MODULE, #{level => error,
                                                   config => #{told => self()}}),
    try
        _ = Fun(),
        drain()
    after
        _ = logger:remove_handler(argos_test)
    end.

%% The handler, called by the logger. It has to be in this module because eunit
%% has no fixture for a handler module, and it does nothing but hand the event
%% to whoever asked for it.
-spec log(logger:log_event(), map()) -> ok.
%% The logger hands a custom handler its own configuration map, and whether that
%% is the `config' value or the whole handler map depends on the caller, so both
%% shapes are accepted here. Getting this wrong is silent: the event is simply
%% dropped, and the test that reads the loud line passes on an empty list or
%% fails for a reason that looks like the code's fault rather than the fixture's.
log(Event, #{config := #{told := Told}}) ->
    Told ! {logged, Event},
    ok;
log(Event, #{told := Told}) ->
    Told ! {logged, Event},
    ok;
log(_Event, _NoAddressee) ->
    ok.

drain() ->
    receive
        {logged, Event} -> [text(Event) | drain()]
    after 0 ->
        []
    end.

%% The report clause comes FIRST: a report is a two-tuple like a format string
%% and a list of arguments, so the general clause would swallow it.
text(#{msg := {report, Report}}) -> lists:flatten(io_lib:format("~p", [Report]));
text(#{msg := {Format, Args}}) -> lists:flatten(io_lib:format(Format, Args));
text(_Other) -> "".

match(Lines, Needle) ->
    lists:any(fun(Line) -> binary:match(unicode:characters_to_binary(Line),
                                        unicode:characters_to_binary(Needle)) =/= nomatch
              end, Lines).
