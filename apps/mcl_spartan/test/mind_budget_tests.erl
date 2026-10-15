%% @doc The ledger: a hard daily cap, and what happens when it is not read.
-module(mind_budget_tests).

-include_lib("eunit/include/eunit.hrl").

budget_test_() ->
    {setup, fun open/0, fun close/1,
     fun(_Dir) ->
         [fun spending_is_counted/0,
          fun the_cap_is_the_cap/0,
          fun a_kept_ledger_is_read_back/0,
          fun yesterday_is_not_today/0,
          fun a_new_day_hands_the_allowance_back/0,
          fun an_unreadable_ledger_is_a_fresh_day/0]
     end}.

spending_is_counted() ->
    ok = save(#{day => mind_budget:day(), spent => 0}),
    Budget = mind_budget:load(),
    ?assertEqual(0, maps:get(spent, Budget)),
    Spent = mind_budget:spend(mind_budget:spend(Budget, 120), 30),
    ?assertEqual(150, maps:get(spent, Spent)),
    ?assertNot(mind_budget:resting(Spent)).

%% A cap of zero is not a licence to spend: the boundary is INCLUSIVE, because
%% the number that matters is the one already spent.
the_cap_is_the_cap() ->
    application:set_env(mcl_spartan, daily_token_cap, 100),
    ?assertNot(mind_budget:resting(#{day => mind_budget:day(), spent => 99})),
    ?assert(mind_budget:resting(#{day => mind_budget:day(), spent => 100})),
    ?assert(mind_budget:resting(#{day => mind_budget:day(), spent => 101})),
    Report = mind_budget:report(#{day => mind_budget:day(), spent => 100}),
    ?assertEqual(100, maps:get(cap, Report)),
    ?assertEqual(100, maps:get(spent, Report)),
    ?assert(maps:get(resting, Report)).

%% The point of the file: a restart does not hand the mind a fresh allowance.
a_kept_ledger_is_read_back() ->
    Today = mind_budget:day(),
    ok = mind_budget:save(#{day => Today, spent => 4321}),
    ?assertEqual(#{day => Today, spent => 4321}, mind_budget:load()).

%% The day key is UTC days since the epoch, so the allowance turns over at one
%% moment wherever the box is.
yesterday_is_not_today() ->
    ok = mind_budget:save(#{day => mind_budget:day() - 1, spent => 4321}),
    ?assertEqual(0, maps:get(spent, mind_budget:load())).

%% THE SAME ROLLOVER THE GATE APPLIES, on a ledger handed to it rather than read
%% from the file: a mind that is up across midnight gets its allowance back
%% without a restart, and a ledger from today is left alone.
a_new_day_hands_the_allowance_back() ->
    Today = mind_budget:day(),
    Yesterday = #{day => Today - 1, spent => 4321},
    ?assertEqual(#{day => Today, spent => 0}, mind_budget:today(Yesterday)),
    ?assertEqual(Yesterday#{day => Today}, mind_budget:today(Yesterday#{day => Today})).

%% A budget that cannot be read is a fresh day rather than a crash: the worst
%% case is one day counted twice, and the alternative is a mind that cannot
%% think because it cannot read its own ledger.
an_unreadable_ledger_is_a_fresh_day() ->
    ok = file:write_file(mind_budget:path(), <<"this is not a term">>),
    ?assertEqual(0, maps:get(spent, mind_budget:load())),
    ok = file:write_file(mind_budget:path(), <<131, 104, 1, 97, 1, 97, 1>>),
    ?assertEqual(0, maps:get(spent, mind_budget:load())).

%%====================================================================

open() ->
    Dir = filename:join([tmpdir(), "mcl_spartan_budget_test"]),
    _ = file:del_dir_r(Dir),
    ok = filelib:ensure_path(Dir),
    _ = application:load(mcl_spartan),
    application:set_env(mcl_spartan, data_dir, Dir),
    application:set_env(mcl_spartan, daily_token_cap, 1000),
    Dir.

close(Dir) ->
    [application:unset_env(mcl_spartan, Key) || Key <- [data_dir, daily_token_cap]],
    _ = file:del_dir_r(Dir),
    ok.

save(Budget) -> mind_budget:save(Budget).

tmpdir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Dir   -> Dir
    end.
