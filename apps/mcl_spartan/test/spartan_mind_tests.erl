%% @doc The mind: one turn per story, a clock, and a daily cap.
%%
%% The endpoint and the square are faked, because a unit test cannot call Groq
%% or write to a real mesh. Everything between them is real: the gates, the
%% prompt built from the fact, the post built from the answer, and the ledger
%% on disk. A test that faked those too would assert that the code does what it
%% says rather than that it does what the design needs.
%%
%% WHAT THE FAKES WRITE GOES IN A TABLE, NOT IN A MESSAGE. eunit runs each test
%% in its own process, so a mock that sends what it saw to `self()' sends it to
%% whoever set the mock up, and the test that then reads its own mailbox finds
%% nothing. The table is the one place both ends can see.
%%
%% EACH TEST FORGETS WHAT THE LAST ONE DID and uses its own item id: the mind is
%% one long-lived process across this module, exactly as it is in the service,
%% so its memory of taken items is shared state, and a test that ignored that
%% would be asserting the order the tests happen to run in.
%%
%% ⚠ AND THE TURN IS A CAST, SO THE OUTCOME IS A COUNTER, NOT A RETURN VALUE.
%% The wire hands a fact over without waiting (the pool made a turn as long as
%% every provider's patience added together, which is longer than a wire
%% subscriber may block), so a test reads what happened the way the service does:
%% from the mind's own report. `delta/1' is that read, and it is also the barrier,
%% because a call from this process lands behind the cast this process just made.
-module(spartan_mind_tests).

-include_lib("eunit/include/eunit.hrl").

-define(POSTS, spartan_mind_test_posts).
-define(COUNTERS, [turns, published, silent, duplicates, clocked, rested, refused, failed]).

mind_test_() ->
    {setup, fun open/0, fun close/1,
     fun(_Context) ->
         [fun refused_without_an_id/0,
          fun one_post_for_one_item/0,
          fun a_second_delivery_is_a_duplicate/0,
          fun the_clock_holds_the_next_story/0,
          fun a_failed_turn_still_takes_the_item/0,
          fun a_failed_turn_starts_the_clock/0,
          fun a_failed_turn_is_charged/0,
          fun the_cap_makes_it_rest/0,
          fun the_cap_rolls_over_at_midnight/0,
          fun what_it_spent_is_on_disk/0,
          fun a_fact_that_arrived_inside_the_clock_is_dropped_when_it_is_read/0,
          fun a_slow_turn_does_not_hold_the_wire/0]
     end}.

%%====================================================================
%% The tests
%%====================================================================

refused_without_an_id() ->
    ok = forget(),
    ok = answering(<<"A post.">>, 10),
    ?assertEqual(#{refused => 1}, delta(#{title => {text, <<"no id">>}})),
    ?assertEqual(0, meck:num_calls(mind_llm, reason, 2)),
    ?assertEqual(0, published_count()).

one_post_for_one_item() ->
    ok = forget(),
    ok = answering(<<"A post about the match.">>, 12),
    ?assertEqual(#{turns => 1, published => 1}, delta(fact(<<"a1">>))),
    ?assertEqual(#{turns => 1, published => 1}, delta(fact(<<"a2">>))),
    ?assertEqual(2, published_count()),
    {Topic, Payload} = next_published(),
    ?assertEqual(<<"io.macula/mcl-spartan/agora/wire/agora_post_published_v1">>, Topic),
    %% The post is what the mind said, attributed to the mind, and threaded on
    %% the item it was handed.
    ?assertMatch(#{event_type := <<"agora_post_published_v1">>,
                   from := {text, <<"spartan">>},
                   body := {text, <<"A post about the match.">>},
                   kind := {text, <<"opening">>},
                   in_reply_to := <<>>}, Payload),
    ?assert(is_binary(maps:get(post_id, Payload))),
    ?assert(maps:get(posted_at, Payload) > 0),
    %% The card is the fact, copied. item_id is the thread, so it is the field
    %% that has to be there.
    Stimulus = maps:get(stimulus, Payload),
    ?assertEqual({text, <<"a1">>}, maps:get(item_id, Stimulus)),
    ?assertEqual({text, <<"france24">>}, maps:get(source, Stimulus)),
    ?assertEqual([{text, <<"sport">>}], maps:get(topics, Stimulus)),
    %% Absent fields stay absent rather than arriving blank.
    ?assertNot(maps:is_key(image_url, Stimulus)).

a_second_delivery_is_a_duplicate() ->
    ok = forget(),
    ok = answering(<<"A post.">>, 10),
    ?assertEqual(#{turns => 1, published => 1}, delta(fact(<<"b1">>))),
    ?assertEqual(#{duplicates => 1}, delta(fact(<<"b1">>))),
    ?assertEqual(1, meck:num_calls(mind_llm, reason, 2)),
    ?assertEqual(1, published_count()).

%% The clock is a ceiling on spend, not a schedule: a story that arrives inside
%% it is counted and dropped, never queued.
the_clock_holds_the_next_story() ->
    ok = forget(),
    application:set_env(mcl_spartan, opening_clock_ms, 60000),
    %% A fresh mind, because the clock reads the mind's own last turn: the last
    %% story the test before this one opened is still inside the window.
    _ = restarted(),
    ok = answering(<<"A post.">>, 10),
    ?assertEqual(#{turns => 1, published => 1}, delta(fact(<<"c1">>))),
    ?assertEqual(#{clocked => 1}, delta(fact(<<"c2">>))),
    ?assertEqual(1, meck:num_calls(mind_llm, reason, 2)),
    %% Back off, so the tests after this one are about their own subject.
    application:set_env(mcl_spartan, opening_clock_ms, 0).

%% A turn that fails still spent the mind's attention, so the item is taken
%% whether or not anything came back: otherwise a flapping endpoint is handed
%% the same story again on every fact.
a_failed_turn_still_takes_the_item() ->
    ok = forget(),
    meck:expect(mind_llm, reason,
                fun(_Charter, _Prompt) ->
                    {error, {all_backends_exhausted, "endpoint",
                             {http_status, 500, <<"oops">>}}, 0}
                end),
    ?assertEqual(#{failed => 1}, delta(fact(<<"d1">>))),
    ?assertEqual(1, meck:num_calls(mind_llm, reason, 2)),
    ?assertEqual(#{duplicates => 1}, delta(fact(<<"d1">>))),
    ?assertEqual(1, meck:num_calls(mind_llm, reason, 2)),
    ?assertEqual(0, published_count()).

%% ⚠ A TURN THAT FAILED IS NOT A FREE TURN. A pool that truncates every reply
%% spends at every slot it tried, and the number mind_llm reports for the failure
%% is what the day's allowance loses. Without this the cap counted the turns that
%% worked and called the failures free, which is a cap a failing pool spends
%% straight through.
a_failed_turn_is_charged() ->
    ok = forget(),
    application:set_env(mcl_spartan, daily_token_cap, 1000),
    ok = mind_budget:save(#{day => mind_budget:day(), spent => 0}),
    _ = restarted(),
    meck:expect(mind_llm, reason,
                fun(_Charter, _Prompt) ->
                    {error, {all_backends_exhausted, "nvidia", truncated}, 321}
                end),
    ?assertEqual(#{failed => 1}, delta(fact(<<"i1">>))),
    #{budget := Budget} = spartan_mind:report(),
    ?assertEqual(321, maps:get(spent, Budget)),
    %% And the ledger on disk agrees, so the charge survives a restart too.
    ?assertEqual(321, maps:get(spent, mind_budget:report(mind_budget:load()))).

the_cap_makes_it_rest() ->
    ok = forget(),
    application:set_env(mcl_spartan, daily_token_cap, 5),
    #{spent := Spent} = mind_budget:report(mind_budget:load()),
    ok = mind_budget:save(#{day => mind_budget:day(), spent => Spent + 5}),
    _ = restarted(),
    ?assertEqual(#{rested => 1}, delta(fact(<<"e1">>))),
    ?assertEqual(0, meck:num_calls(mind_llm, reason, 2)),
    ?assertEqual(0, published_count()).

%% A failed turn STARTS THE CLOCK. Without this, an endpoint answering 429 (or
%% hanging) hands every item in a batch its own call, serialised behind one
%% timeout each, which holds the subscriber and keeps the 429 going.
a_failed_turn_starts_the_clock() ->
    ok = forget(),
    application:set_env(mcl_spartan, opening_clock_ms, 60000),
    _ = restarted(),
    meck:expect(mind_llm, reason,
                fun(_Charter, _Prompt) ->
                    {error, {all_backends_exhausted, "endpoint",
                             {http_status, 429, <<"slow down">>, undefined}}, 0}
                end),
    ?assertEqual(#{failed => 1}, delta(fact(<<"h1">>))),
    ?assertEqual(#{clocked => 1}, delta(fact(<<"h2">>))),
    ?assertEqual(1, meck:num_calls(mind_llm, reason, 2)),
    application:set_env(mcl_spartan, opening_clock_ms, 0).

%% The cap is DAILY. A mind that is still up at midnight gets its allowance back
%% without a restart: without the rollover in the gate, "daily" would mean "for
%% the life of the container".
the_cap_rolls_over_at_midnight() ->
    ok = forget(),
    application:set_env(mcl_spartan, daily_token_cap, 5),
    ok = mind_budget:save(#{day => mind_budget:day() - 1, spent => 500}),
    _ = restarted(),
    ok = answering(<<"A post.">>, 10),
    ?assertEqual(#{turns => 1, published => 1}, delta(fact(<<"g1">>))),
    #{budget := Budget} = spartan_mind:report(),
    ?assertEqual(10, maps:get(spent, Budget)).

what_it_spent_is_on_disk() ->
    ok = forget(),
    application:set_env(mcl_spartan, daily_token_cap, 1000),
    ok = mind_budget:save(#{day => mind_budget:day(), spent => 0}),
    _ = restarted(),
    ok = answering(<<"A post.">>, 12),
    ?assertEqual(#{turns => 1, published => 1}, delta(fact(<<"f1">>))),
    #{budget := Budget} = spartan_mind:report(),
    ?assertEqual(12, maps:get(spent, Budget)),
    %% And the ledger on disk says the same, which is what makes the cap
    %% survive a restart instead of being a speed bump.
    ?assertEqual(12, maps:get(spent, mind_budget:report(mind_budget:load()))).

%% @doc ⚠ THE CLOCK GATES WHEN A FACT ARRIVED, NOT WHEN IT WAS READ. A turn can
%% now outlast the opening clock, so a fact handed over during one is read after
%% the clock has already elapsed. Gated on the reading, it opens a turn of its
%% own, and so does the next, and the next: one paid turn after another, which is
%% the spend spiral the clock exists to stop, with the mailbox as its only bound.
%%
%% THE CLOCK HERE IS SHORTER THAN THE TURN ON PURPOSE. With a clock longer than
%% the turn, a fact read afterwards would be dropped by the old arithmetic too,
%% and the test would pass without the fix.
a_fact_that_arrived_inside_the_clock_is_dropped_when_it_is_read() ->
    ok = forget(),
    application:set_env(mcl_spartan, opening_clock_ms, 500),
    _ = restarted(),
    meck:expect(mind_llm, reason,
                fun(_Charter, _Prompt) ->
                    timer:sleep(1000),
                    {ok, #{body => <<"A slow post.">>, tokens => 5}}
                end),
    %% ONE turn, from the fact that arrived outside the clock; the fact handed
    %% over while that turn was running is CLOCKED when the mind finally reads
    %% it, which is the whole point. (The turn it did take published, hence the
    %% third counter.)
    ?assertEqual(#{turns => 1, published => 1, clocked => 1},
                 counted(fun() -> ok = spartan_mind:think(fact(<<"k1">>)),
                                 ok = spartan_mind:think(fact(<<"k2">>))
                         end)),
    application:set_env(mcl_spartan, opening_clock_ms, 0).

%% @doc ⚠ THE TURN IS OFF THE WIRE SUBSCRIBER. A pool makes a turn as long as
%% every provider's patience added together, and the subscriber used to make that
%% turn synchronously and be restarted for it, dropping whatever facts it was
%% holding. What is pinned is the subscriber returning while the mind is still
%% thinking, and the fact still being dealt with afterwards.
%%
%% The margin is deliberately loose: this asserts "does not wait", not a latency
%% budget, and a loaded box is allowed to be slow.
a_slow_turn_does_not_hold_the_wire() ->
    ok = forget(),
    meck:expect(mind_llm, reason,
                fun(_Charter, _Prompt) ->
                    timer:sleep(1000),
                    {ok, #{body => <<"A slow post.">>, tokens => 5}}
                end),
    Started = erlang:monotonic_time(millisecond),
    {noreply, Wire} = on_news_item_reported_maybe_open_a_turn:handle_event(
                        <<"io.macula/mcl-news/news/wire/news_item_reported_v1">>,
                        fact(<<"j1">>), #{}, #{offered => 0, refused => 0}),
    Waited = erlang:monotonic_time(millisecond) - Started,
    ?assertEqual(#{offered => 1, refused => 0}, Wire),
    ?assert(Waited < 800),
    %% And the turn it handed over still runs to the end.
    #{published := Published} = spartan_mind:report(),
    ?assert(Published >= 1).

%%====================================================================
%% Setup
%%====================================================================

open() ->
    Dir = data_dir(),
    _ = file:del_dir_r(Dir),
    ok = filelib:ensure_path(Dir),
    _ = application:load(mcl_spartan),
    application:set_env(mcl_spartan, data_dir, Dir),
    application:set_env(mcl_spartan, mind_name, <<"spartan">>),
    application:set_env(mcl_spartan, daily_token_cap, 1000),
    %% THE CLOCK IS OFF BY DEFAULT HERE, and on only in the test that is about
    %% it. It is a real gate, so leaving it on would make every other test
    %% assert the clock instead of what it is for: a mind opens one turn per
    %% minute, which is the service's behaviour and not a test's convenience.
    application:set_env(mcl_spartan, opening_clock_ms, 0),
    _ = ets:new(?POSTS, [public, named_table, set]),
    meck:new(mind_llm, [passthrough, no_link]),
    meck:new(mcl_om_pubsub, [passthrough, no_link]),
    meck:expect(mcl_om_pubsub, publish, fun(Topic, Payload, _Opts) -> posted(Topic, Payload) end),
    _ = restarted(),
    #{dir => Dir}.

%% A fresh mind, so a test that changes the cap or the ledger gets one that
%% reads them: the mind reads both at init, on purpose, because both are state.
restarted() ->
    stopped(),
    {ok, Pid} = spartan_mind:start_link(),
    Pid.

stopped() ->
    case whereis(spartan_mind) of
        undefined -> ok;
        Pid       -> gen_server:stop(Pid)
    end.

close(#{dir := Dir}) ->
    stopped(),
    meck:unload(mind_llm),
    meck:unload(mcl_om_pubsub),
    [application:unset_env(mcl_spartan, Key)
     || Key <- [data_dir, mind_name, daily_token_cap, opening_clock_ms]],
    _ = file:del_dir_r(Dir),
    ok.

data_dir() ->
    filename:join([tmpdir(), "mcl_spartan_mind_test"]).

tmpdir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Dir   -> Dir
    end.

%%====================================================================
%% Helpers
%%====================================================================

%% A fact as mcl-news publishes one: every string tagged as CBOR text, times in
%% milliseconds, and the item id that threads the story.
fact(ItemId) ->
    #{item_id => {text, ItemId},
      source => {text, <<"france24">>},
      title => {text, <<"PSG put on a show at Manchester City">>},
      body => {text, <<"PSG put on a show at Manchester City">>},
      url => {text, <<"https://example.test/psg">>},
      topics => [{text, <<"sport">>}],
      topic_class => {text, <<"sport">>},
      published_at => 1785215553616,
      fetched_at => 1792043408599}.

%% The endpoint answers. Returns ok rather than the expectation itself, so a
%% test can bind it and the call still reads like a line of setup.
answering(Body, Tokens) ->
    meck:expect(mind_llm, reason,
                fun(_Charter, _Prompt) -> {ok, #{body => Body, tokens => Tokens}} end),
    ok.

posted(Topic, Payload) ->
    ets:insert(?POSTS, {posts, posts() ++ [{Topic, Payload}]}),
    ok.

posts() ->
    case ets:lookup(?POSTS, posts) of
        [{posts, Posted}] -> Posted;
        []                -> []
    end.

published_count() ->
    length(posts()).

next_published() ->
    [First | _Rest] = posts(),
    First.

%% What the previous test published and what it asked the endpoint, so each
%% test reads its own run rather than the module's.
forget() ->
    ets:insert(?POSTS, {posts, []}),
    meck:reset(mind_llm),
    ok.

%% What ONE fact moved, in the mind's own counts. The mind is one long-lived
%% process across this module, exactly as it is in the service, so a test that
%% read the totals would be asserting the order the tests happen to run in.
%%
%% Asking for the report is also the barrier: the turn is a cast, and a call from
%% this process lands behind the cast this process just made.
delta(Item) ->
    counted(fun() -> ok = spartan_mind:think(Item) end).

%% The same, for a group of facts handed over together, which is what the clock
%% test needs: the second cast has to land while the first turn is still running.
counted(Offer) ->
    Before = spartan_mind:report(),
    ok = Offer(),
    moved(maps:with(?COUNTERS, Before), maps:with(?COUNTERS, spartan_mind:report())).

moved(Before, After) ->
    maps:fold(fun(Key, Now, Acc) ->
                  case Now - maps:get(Key, Before, 0) of
                      0 -> Acc;
                      Moved -> Acc#{Key => Moved}
                  end
              end, #{}, After).
