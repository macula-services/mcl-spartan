%%% @doc A Spartan mind: hears the wire, reasons once about one story, speaks
%%% if it has something to say.
%%%
%%% IDLE AT ZERO COST UNTIL SOMETHING ARRIVES. It is not on a clock and it does
%%% not poll: a supervised gen_server that sits quiet until the wire hands it a
%%% fact, then takes at most one turn about it. That is the whole design, and it
%%% is why a society of these is affordable where a busy loop is not.
%%%
%%% FOUR GATES BEFORE ANY MONEY MOVES, and they are ordered cheapest first:
%%%
%%%   refused    the fact has no item_id, so there is nothing to thread on
%%%   duplicate  this item was already taken, and one item opens one turn
%%%   clock      the opening clock has not run out since the last turn
%%%   resting    the day's token allowance is spent
%%%
%%% THE CLOCK IS A CEILING ON SPEND, NOT A SCHEDULE. A fact that arrives inside
%%% it is counted and dropped rather than queued: a queue would spend the same
%%% money later, and being late to a story is a smaller fault than paying twice
%%% for it.
%%%
%%% AND THE QUEUE IS THE MAILBOX, NOT A WORK LIST. The wire hands a fact over
%%% without waiting (see think/1), so a fact that arrives while a turn is running
%%% waits in this process's own queue and is then answered by these gates in
%%% microseconds. What the design forbids is a fact held back for a LATER paid
%%% turn, and the clock above is what forbids it.
%%%
%%% THE ITEM IS MARKED AS TAKEN BEFORE THE CALL, not after. A turn that fails
%%% leaves that item taken, so a flapping endpoint cannot be handed the same
%%% story every time it manages to answer.
-module(spartan_mind).

-behaviour(gen_server).

-export([start_link/0, think/1, health/0, report/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(OPENING_CLOCK_DEFAULT_MS, 60000).
-define(OPENED_WINDOW, 2000).

-record(mind, {name                    :: binary(),
               charter                 :: binary(),
               budget                  :: mind_budget:budget(),
               opened = []             :: [binary()],
               opened_set = #{}        :: #{binary() => true},
               last_turn_ms            :: integer() | undefined,
               turns = 0               :: non_neg_integer(),
               published = 0           :: non_neg_integer(),
               silent = 0              :: non_neg_integer(),
               duplicates = 0          :: non_neg_integer(),
               clocked = 0             :: non_neg_integer(),
               rested = 0              :: non_neg_integer(),
               refused = 0             :: non_neg_integer(),
               failed = 0              :: non_neg_integer()}).

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Offer one fact from the wire to the mind.
%%
%% ⚠ THIS IS A CAST, AND IT WAS A CALL. It is made from the wire subscriber's own
%% process, so a synchronous turn held that subscriber for as long as the turn
%% took, and the pool made that unbounded: a walk can spend every provider's
%% patience one after another, and the local floor is patient enough on its own
%% to outlast any caller. A subscriber that takes too long is restarted and the
%% facts it was holding are gone, which is the one failure this service cannot
%% see, because a dropped fact and a quiet wire look exactly alike.
%%
%% The mind serialises itself instead: facts queue behind the turn in progress
%% and are decided by the gates below, which cost a comparison rather than a
%% call, so the queue drains as fast as it forms. What the turn did with the fact
%% is in the mind's own report, which is where the outcome was always readable.
%%
%% ⚠ THE ARRIVAL IS STAMPED HERE, NOT WHEN THE FACT IS LOOKED AT, and that is
%% what keeps the clock a clock. A walk can outlast the opening clock, so a fact
%% handed over during one is dequeued after the clock has already elapsed: gated
%% on the time it was READ, every fact that queued behind a slow turn would open
%% a paid turn of its own, one after another, which is the spend spiral the clock
%% exists to stop and the mailbox the only bound on it. Gated on the time it
%% ARRIVED, a fact that arrived before or during that turn is inside the clock
%% and is dropped, however long the mind took to get to it.
-spec think(map()) -> ok.
think(Item) ->
    gen_server:cast(?MODULE, {think, Item, erlang:monotonic_time(millisecond)}).

%% @doc Whether the mind is well. Being out of budget is not unwell: a resting
%% mind is green, and its report is where that is visible.
-spec health() -> ok | {degraded, term()}.
health() ->
    try gen_server:call(?MODULE, report, 2000) of
        _Report -> ok
    catch
        _:_ -> {degraded, {mind_not_running, ?MODULE}}
    end.

%% @doc The mind's own account of itself: what it is, what it cost, and what it
%% has done since boot. The counters are the answer to "is it working", which
%% nothing else here can give.
-spec report() -> map().
report() ->
    gen_server:call(?MODULE, report, 2000).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @private
init([]) ->
    process_flag(trap_exit, true),
    {ok, #mind{name = mcl_spartan_service:mind_name(),
               charter = mcl_spartan_service:charter(),
               budget = mind_budget:load()}}.

%% @private One fact, one turn, and nobody waiting on the answer: the caller is
%% the wire subscriber, which has to stay responsive while a turn runs, and the
%% mind's own counters are where the outcome lands.
handle_cast({think, Item, Arrived}, St) ->
    {_Outcome, St1} = turn(Item, Arrived, St),
    {noreply, St1};
handle_cast(_Msg, St) -> {noreply, St}.

handle_call(report, _From, St) ->
    {reply, report_of(St), St};
handle_call(_Other, _From, St) ->
    {reply, {error, unknown_request}, St}.
handle_info(_Info, St) -> {noreply, St}.
terminate(_Reason, _St) -> ok.

%%====================================================================
%% The turn
%%====================================================================

%% @private The four gates, cheapest first.
turn(Item, Arrived, St) ->
    case agora_stimulus:of_fact(Item) of
        {error, missing_item_id} ->
            {refused, St#mind{refused = St#mind.refused + 1}};
        {ok, Stimulus} ->
            offered(agora_stimulus:item_id(Stimulus), Stimulus, Arrived, St)
    end.

offered(ItemId, Stimulus, Arrived, St) ->
    case maps:is_key(ItemId, St#mind.opened_set) of
        true  -> {duplicate, St#mind{duplicates = St#mind.duplicates + 1}};
        false -> clocked(ItemId, Stimulus, Arrived, St)
    end.

clocked(ItemId, Stimulus, Arrived, St) ->
    case inside_clock(Arrived, St) of
        true  -> {clock, St#mind{clocked = St#mind.clocked + 1}};
        false -> budgeted(ItemId, Stimulus, St)
    end.

budgeted(ItemId, Stimulus, St) ->
    %% THE LEDGER IS ROLLED HERE, NOT ONLY AT BOOT. A mind that is up across
    %% midnight would otherwise carry yesterday's spend into today and rest for
    %% the rest of its life, which is a cap for the life of a container wearing
    %% a daily cap's name.
    Budget = mind_budget:today(St#mind.budget),
    Woken = woken(St, Budget),
    case mind_budget:resting(Budget) of
        true  -> rested(Woken);
        false -> reasoned(ItemId, Stimulus, taken(ItemId, Woken))
    end.

%% A new day is a new allowance, and the notice about resting belongs to the day
%% it was said on: with the counter reset here, a mind that rests again after
%% midnight says so again instead of staying quietly tired for good.
woken(St, Budget) ->
    case maps:get(day, Budget) =:= maps:get(day, St#mind.budget) of
        true  -> St#mind{budget = Budget};
        false -> St#mind{budget = Budget, rested = 0}
    end.

%% @private A mind out of budget is not broken, it is resting, which the design
%% insists is a normal state. It says so ONCE, when it starts resting: a line
%% per story would be the noise the cap exists to stop.
rested(#mind{rested = 0} = St) ->
    logger:notice("[spartan] the day's token allowance is spent; this mind is resting"),
    {resting, St#mind{rested = 1}};
rested(St) ->
    {resting, St#mind{rested = St#mind.rested + 1}}.

%% @private The one thing a mind is FOR. Everything above is what keeps it from
%% doing this too often.
%%
%% THE CLOCK STARTS HERE, BEFORE THE CALL, AND ON BOTH OUTCOMES. A turn that
%% fails still spent the mind's attention: with the clock started only on a
%% successful turn, an endpoint answering 429 or hanging would hand every item
%% in a batch its own serialised call, which keeps the 429 going and holds the
%% subscriber for a timeout each time.
reasoned(ItemId, Stimulus, St) ->
    St1 = turned(St),
    case mind_llm:reason(St1#mind.charter, prompt(Stimulus)) of
        {ok, #{body := Body, tokens := Tokens}} ->
            spoke(ItemId, Body, Tokens, Stimulus, St1);
        {error, Reason, Tokens} ->
            failed(ItemId, Reason, Tokens, St1)
    end.

%% ⚠ A TURN THAT FAILED IS NOT A FREE TURN, and it is charged here. A pool that
%% truncates every reply spends at every slot it tried, and a turn that gave up
%% after three providers spent at all three. Charging only the turns that worked
%% is a cap a failing pool spends straight through, which is the opposite of what
%% a cap is for. The cost is the one mind_llm reports for the failure, which is
%% zero for a provider that refused the request outright.
failed(ItemId, Reason, Tokens, St) ->
    St1 = charged(Tokens, St),
    logger:warning("[spartan] turn failed for item ~s: ~p", [ItemId, Reason]),
    {{failed, Reason}, St1#mind{failed = St1#mind.failed + 1}}.

spoke(ItemId, Body, Tokens, Stimulus, St) ->
    St1 = charged(Tokens, St#mind{turns = St#mind.turns + 1}),
    spoke_of(ItemId, maybe_publish_to_agora:maybe_publish(St1#mind.name, Body, Stimulus), St1).

%% What a turn cost, written after every turn that spent anything, so a restart
%% costs at most one turn rather than the whole day.
charged(0, St) ->
    St;
charged(Tokens, St) ->
    Budget = mind_budget:spend(St#mind.budget, Tokens),
    ok = mind_budget:save(Budget),
    St#mind{budget = Budget}.

spoke_of(ItemId, {published, PostId}, St) ->
    logger:info("[spartan] ~s posted ~s about item ~s (~p tokens today)",
                [St#mind.name, PostId, ItemId, maps:get(spent, mind_budget:report(St#mind.budget))]),
    {{published, PostId}, St#mind{published = St#mind.published + 1}};
spoke_of(ItemId, {silent, empty_body}, St) ->
    logger:info("[spartan] ~s had nothing to say about item ~s", [St#mind.name, ItemId]),
    {silent, St#mind{silent = St#mind.silent + 1}};
spoke_of(ItemId, {error, Reason}, St) ->
    logger:warning("[spartan] post for item ~s did not reach the square: ~p", [ItemId, Reason]),
    {{post_failed, Reason}, St#mind{failed = St#mind.failed + 1}}.

%%====================================================================
%% State
%%====================================================================

%% The clock starts when a turn is TAKEN, not when it succeeds: a failed turn
%% still spent the mind's attention, and letting it retry immediately is the
%% spend spiral the clock exists to stop.
turned(St) ->
    St#mind{last_turn_ms = erlang:monotonic_time(millisecond)}.

%% ⚠ THE QUESTION IS WHEN THE FACT ARRIVED, NOT WHEN IT WAS READ, and the two
%% differ by however long the last turn took. A fact stamped before the last turn
%% started gives a NEGATIVE interval, which is inside the clock: a fact that was
%% already waiting when the mind got to it opens nothing.
inside_clock(_Arrived, #mind{last_turn_ms = undefined}) -> false;
inside_clock(Arrived, #mind{last_turn_ms = Last}) ->
    Arrived - Last < opening_clock_ms().

opening_clock_ms() ->
    application:get_env(mcl_spartan, opening_clock_ms, ?OPENING_CLOCK_DEFAULT_MS).

%% The window is bounded, because an unbounded memory of every story ever seen
%% is a leak in a process meant to live for months. Rebuilt on restart, the
%% same way mcl-news rebuilds its reported-item window: a redelivery of an item
%% from before the restart opens one extra turn, which the clock bounds anyway.
taken(ItemId, #mind{opened = Opened, opened_set = Set} = St) ->
    {Kept, Key} = trimmed(Opened ++ [ItemId]),
    St#mind{opened = Kept, opened_set = maps:put(ItemId, true, forgotten(Set, Key))}.

trimmed(Opened) when length(Opened) =< ?OPENED_WINDOW -> {Opened, undefined};
trimmed(Opened) ->
    {Head, _} = lists:split(length(Opened) - ?OPENED_WINDOW, Opened),
    case Head of
        [] -> {Opened, undefined};
        [Oldest | _] -> {lists:nthtail(length(Head), Opened), Oldest}
    end.

forgotten(Set, undefined) -> Set;
forgotten(Set, Oldest)    -> maps:remove(Oldest, Set).

report_of(#mind{} = St) ->
    #{name => St#mind.name,
      turns => St#mind.turns,
      published => St#mind.published,
      silent => St#mind.silent,
      duplicates => St#mind.duplicates,
      clocked => St#mind.clocked,
      rested => St#mind.rested,
      refused => St#mind.refused,
      failed => St#mind.failed,
      opened => map_size(St#mind.opened_set),
      budget => mind_budget:report(St#mind.budget),
      llm => mind_llm:config()}.

%% The prompt is what the wire handed over, as prose: the sensor's own `body'
%% line, which already carries the headline, the class, the source and the
%% country, and then the two things it does not carry, the link and the tags.
%% Sending title and summary again would be the same words twice in a prompt
%% whose length is instruction-following budget spent on our own prose.
prompt(Stimulus) ->
    unicode:characters_to_binary(
      [line(K, Stimulus) || K <- [body, url, topics]]).

line(Key, Stimulus) ->
    case value(Key, Stimulus) of
        undefined -> "";
        Value     -> io_lib:format("~s: ~ts~n", [atom_to_list(Key), Value])
    end.

%% Absent and empty are the same thing here: a line saying "topics: " is a line
%% of prompt spent on nothing.
value(Key, Stimulus) ->
    text(mcl_om_wire:field(Key, Stimulus)).

text(undefined)                                -> undefined;
text(Text) when is_binary(Text), Text =/= <<>> -> Text;
text([])                                       -> undefined;
text(List) when is_list(List)                  -> joined([T || T <- List, is_binary(T)]);
text(_Other)                                   -> undefined.

joined([])     -> undefined;
joined(Texts)  -> lists:join(", ", Texts).
