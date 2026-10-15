%%% @doc What the carousel remembers between turns.
%%%
%%% WITHOUT THIS THE SCHEDULE HAS NO MEMORY. Every turn rediscovers, from
%%% scratch, that a rate-limited provider is rate-limited, and pays the full
%%% backoff to find out again. The reference implementation lost about
%%% twenty-six seconds of every turn doing exactly that against an endpoint
%%% that had already answered 429 six times, while a fallback answering 200 sat
%%% at the end of the schedule waiting to be reached.
%%%
%%% A 429 IS NOT A BLIP. It is a statement about the next few minutes, and it
%%% often carries `retry-after` saying exactly how many. This records the
%%% statement so the next turn can believe it.
%%%
%%% == What is remembered, and what is not ==
%%%
%%% Only rate limits and auth failures, because only those are properties of
%%% the BACKEND rather than of the moment:
%%%
%%%   429  rate limited  -- rest it, for `retry-after` or a growing backoff
%%%   401  bad key       -- rest it long, and say so loudly: a key that is
%%%                         wrong is wrong until a person changes it
%%%   403  forbidden     -- likewise
%%%
%%% A timeout, a 500, a dropped connection, a reply that would not parse and a
%%% reply the endpoint cut off are the MOMENT, not the backend, and are
%%% forgotten on the spot: resting a healthy provider because one request timed
%%% out would take it out of the rotation for no reason.
%%%
%%% == It fails OPEN ==
%%%
%%% If every backend is resting, `usable/1` returns the whole schedule anyway.
%%% A mind that cannot speak because its own bookkeeping says so would be the
%%% worst outcome here and the least visible: the alternative to a wasted 429 is
%%% not silence, it is trying anyway.
%%%
%%% == One entry per provider, not per key ==
%%%
%%% A key belongs to a provider and a provider's quota is usually per key, so
%%% the rest is held against the PROVIDER: the schedule is built with several
%%% keys per provider precisely so that the next key is the next slot, and
%%% resting one key while walking straight into the next key of the same
%%% provider would spend the same wasted call with more steps.
-module(mind_breaker).

-export([usable/1, failed/2, worked/1, resting/1]).

-define(TABLE, mind_breaker).

%% A rate limit that does not say when to come back rests for this long,
%% doubling on each consecutive failure up to the cap. Short enough that a
%% freed quota is picked up within a turn or two.
-define(BASE_REST_MS, 30_000).
-define(MAX_REST_MS, 600_000).

%% A wrong key does not fix itself. Rest it long, and let the log say why.
-define(AUTH_REST_MS, 900_000).

-type key()  :: string() | undefined.
-type slot() :: {map(), key()}.

-export_type([slot/0]).

%% @doc The schedule, minus backends that are resting.
%%
%% Everything, if that would leave nothing: the point of the breaker is to skip
%% a wasted call, never to refuse to make one.
-spec usable([slot()]) -> [slot()].
usable(Schedule) ->
    open(Schedule, [Slot || Slot <- Schedule, not resting_slot(Slot)]).

open(Schedule, []) -> Schedule;
open(_Schedule, Usable) -> Usable.

%% @doc Whether this provider is resting right now, for the mind's own report.
-spec resting(map()) -> boolean().
resting(Config) ->
    resting_slot({Config, undefined}).

%% @doc Record what a backend just did. Only backend-shaped failures stick.
-spec failed(map(), term()) -> ok.
%% The backend said when to come back. Believe it, within reason: a hostile or
%% broken `retry-after` of an hour would take a provider out of the rotation for
%% an hour on one bad response.
failed(Config, {http_status, 429, _Body, Seconds}) when is_integer(Seconds), Seconds > 0 ->
    rest(Config, rate_limited_told, min(Seconds * 1000, ?MAX_REST_MS));
failed(Config, {http_status, 429, _Body, _NotTold}) ->
    rest(Config, rate_limited, next_rest(Config));
failed(Config, {http_status, 429, _Body}) ->
    rest(Config, rate_limited, next_rest(Config));
failed(Config, {http_status, Code, _Body}) when Code =:= 401; Code =:= 403 ->
    rest(Config, bad_credential, ?AUTH_REST_MS);
failed(_Config, _TheMomentNotTheBackend) ->
    ok.

%% @doc A backend answered. Forget everything held against it.
-spec worked(map()) -> ok.
worked(Config) ->
    _ = catch ets:delete(table(), label(Config)),
    ok.

%% --- Internal ---

resting_slot({Config, _Key}) ->
    still(lookup(label(Config)), now_ms()).

still({_Until, _Strikes} = Entry, Now) -> element(1, Entry) > Now;
still(none, _Now)                      -> false.

rest(Config, Why, Ms) ->
    Label = label(Config),
    Strikes = strikes(lookup(Label)) + 1,
    true = ets:insert(table(), {Label, now_ms() + Ms, Strikes}),
    logger:notice("[mind_breaker] ~s ~p; resting ~bs (strike ~b)",
                  [Label, Why, Ms div 1000, Strikes]),
    ok.

%% Consecutive rate limits back off together: a quota that is exhausted is
%% usually exhausted for longer than the last guess.
next_rest(Config) ->
    min(?BASE_REST_MS bsl min(strikes(lookup(label(Config))), 4), ?MAX_REST_MS).

strikes({_Until, N}) -> N;
strikes(none)        -> 0.

lookup(Label) ->
    read(catch ets:lookup(table(), Label)).

read([{_Label, Until, Strikes}]) -> {Until, Strikes};
read(_MissingOrNoTable)          -> none.

%% Created on first use rather than by a supervisor: this is bookkeeping for a
%% pure function called from a mind's own reasoning process, and a table that
%% has to exist before anyone can think is a worse dependency than one that
%% appears when first needed.
table() ->
    ensure(ets:whereis(?TABLE)).

ensure(undefined) ->
    _ = catch ets:new(?TABLE, [set, public, named_table, {write_concurrency, true}]),
    ?TABLE;
ensure(_Tid) ->
    ?TABLE.

label(Config) -> maps:get(label, Config, "?").

now_ms() -> erlang:system_time(millisecond).
