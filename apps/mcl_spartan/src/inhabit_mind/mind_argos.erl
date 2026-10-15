%%% @doc What the mind has SEEN of each model it calls: when it last answered,
%%% when it last failed and how, and how many failures in a row.
%%%
%%% WHY THIS IS NOT THE BREAKER. The breaker is keyed on the PROVIDER, and it is
%%% right to be: quota and credentials belong to a provider, so resting one is
%%% the thing to do about a 429. Model liveness is a different fact with a
%%% different key. One provider serves several models and retires them one at a
%%% time, so a model id that has begun answering 404 or 410 is a wasted call on
%%% EVERY turn, and the breaker cannot hold it: its memory is rate limits and
%%% credentials, and a 404 is neither.
%%%
%%% The pool's own comment already admits the symptom (a ported constant naming a
%%% model that has since been retired is a backend that fails every turn and is
%%% skipped by the schedule in silence). THIS MODULE IS ABOUT THE SILENCE. It
%%% changes nothing about which slot is tried or which provider rests: it writes
%%% down what happened, with a date, and says the loud part out loud.
%%%
%%% == Dates on disk, counters in memory ==
%%%
%%% A dated fact that forgets its date on a restart is not dated, so the two
%%% timestamps and the class go to one small file under the mind's data
%%% directory. The consecutive-failure count does not: it is about the run in
%%% progress, and a run does not survive the process that was having it. A
%%% missing or unreadable file reads as NO RECORD rather than as an error,
%%% exactly as the day's ledger does, because the alternative is a mind that
%%% cannot think because it cannot read its own notes.
%%%
%%% == It only ever says what it saw ==
%%%
%%% Every entry here came from a turn the mind was already making. There is no
%%% timer, no probe and no scheduled call: if the mind stops turning, this record
%%% stops moving, and that is the honest reading of it. It is a record of the
%%% mind's own experience, not of the provider's state.
-module(mind_argos).

-export([succeeded/2, failed/4, report/0]).

-define(TABLE, mind_argos).
%% ⚠ NOT ?FILE: Erlang predefines ?FILE as the source path, so redefining it is
%% a compile error rather than a shadowing nobody notices.
-define(RECORD_FILE, "mind_argos.term").
%% How many failures in a row are worth a loud line. Three, because one is a
%% moment and two might be a coincidence: at three the mind has spent three
%% turns' worth of patience on the same thing and a person should know.
-define(STRIKES, 3).
%% The process-dictionary latch for "we already said the record cannot be
%% written", so a full disk is one line rather than one per turn.
-define(WRITE_WARNED, mind_argos_write_warned).

-type key()      :: {binary(), binary()}.
-type class()    :: gone | timeout | unreachable | rate_limited | credential
                  | server | parse | other.
%% A name for one turn of the mind's own reasoning, handed in by the walk. Opaque
%% here: all this module does with it is ask whether two failures happened in the
%% same one.
-type turn()     :: integer().
%% `consecutive' counts TURNS, not attempts, and `turn' is the last one that
%% counted, which is what keeps the repeats of a single turn from being read as a
%% run of them.
-type record_()  :: #{last_success_at := integer() | undefined,
                      last_failure_at := integer() | undefined,
                      class := class() | undefined,
                      consecutive := non_neg_integer(),
                      turn := turn() | undefined,
                      told := boolean()}.

-export_type([class/0]).

%% @doc A slot answered. That is the whole of it, and it clears the run.
%%
%% The turn marker is cleared with it, and that is not bookkeeping: a failure
%% after a success is the first of a NEW run even when it lands in the same turn,
%% and leaving the marker behind would have it counted as a repeat of a run that
%% has already ended.
-spec succeeded(binary(), binary()) -> ok.
succeeded(Provider, Model) ->
    _ = changed(key(Provider, Model),
                fun(Seen) -> Seen#{last_success_at => now_s(), consecutive => 0,
                                   turn => undefined, told => false} end),
    ok.

%% @doc A slot failed, with whatever mind_llm said about it and the turn it
%% failed in. The class is read out of that term here rather than at the call
%% site, so the two ends cannot disagree about what a 410 is.
%%
%% ⚠ THE TURN IS THE UNIT AND THE ATTEMPT IS NOT. The schedule carries one slot
%% per (provider, key), so a provider with three keys walks the same
%% {Provider, Model} pair three times in ONE turn: a single 503 moment would
%% otherwise be counted three times and said out loud as "has failed 3 turns in a
%% row", which is a lie a reader would believe. The turn is what tells the
%% repeats of one moment from a run of them, and only the walk knows it.
-spec failed(binary(), binary(), term(), turn()) -> ok.
failed(Provider, Model, Why, Turn) ->
    Key = key(Provider, Model),
    Record = changed(Key, fun(Seen) -> failed_seen(Seen, classify(Why), Turn) end),
    loud(Key, Record).

%% @doc The record as it stands, oldest key first, for the mind's own report.
-spec report() -> [map()].
report() ->
    [row(Key, Seen) || {Key, Seen} <- lists:sort(ets:tab2list(table()))].

%%====================================================================
%% The record
%%====================================================================

-spec key(binary(), binary()) -> key().
key(Provider, Model) -> {Provider, Model}.

%% What a failure does to the record. The count moves once per TURN; everything
%% else is written fresh, because a second key of the same provider failing in the
%% same turn is the same pair failing again and the class it failed with is what
%% the mind last saw of it.
failed_seen(Seen, Class, Turn) ->
    Seen#{last_failure_at => now_s(),
          class => Class,
          turn => Turn,
          consecutive => counted(maps:get(turn, Seen, undefined) =:= Turn, Seen),
          told => told(Seen, Class)}.

counted(true, Seen)  -> maps:get(consecutive, Seen);
counted(false, Seen) -> maps:get(consecutive, Seen) + 1.

%% The latch is what makes one outage one line rather than one per turn, and a
%% success clears it because the outage ended. It is cleared here as well, on the
%% TRANSITION into gone and only there: a run of 5xx says its piece and latches,
%% and a 410 arriving after it would otherwise never say GONE, which is precisely
%% the silence this module exists to end. Only the transition, though, or a model
%% that has been gone for an hour would be one line per turn, which is the noise
%% the latch is for.
told(Seen, Class) ->
    maps:get(told, Seen) andalso not (Class =:= gone andalso maps:get(class, Seen) =/= gone).

row({Provider, Model}, Seen) ->
    #{provider => Provider,
      model => Model,
      last_success_at => maps:get(last_success_at, Seen),
      last_failure_at => maps:get(last_failure_at, Seen),
      class => maps:get(class, Seen),
      consecutive => maps:get(consecutive, Seen)}.

-spec changed(key(), fun((record_()) -> record_())) -> record_().
changed(Key, Fun) ->
    Record = Fun(seen(Key)),
    true = ets:insert(table(), {Key, Record}),
    ok = kept(Key, Record),
    Record.

%% What is known about this key right now: what the table holds, or what the
%% file remembers if this is the first time it has been asked about since boot.
%% The counters are NOT in the file, so a record that comes back off disk starts
%% with the run it has not had.
-spec seen(key()) -> record_().
seen(Key) ->
    case ets:lookup(table(), Key) of
        [{Key, Seen}] -> Seen;
        []            -> gained(#{})
    end.

%% What the file remembers, put into the table as it is created: the dates come
%% back, the runs do not, because a run did not survive the process that was
%% having it. Loading here rather than per key is what makes a report complete
%% straight after a restart, which is when a person is most likely to read one.
load() ->
    [true = ets:insert(?TABLE, {Key, gained(Remembered)})
     || {Key, Remembered} <- maps:to_list(read())],
    ok.

gained(Remembered) ->
    #{last_success_at => maps:get(last_success_at, Remembered, undefined),
      last_failure_at => maps:get(last_failure_at, Remembered, undefined),
      class => maps:get(class, Remembered, undefined),
      consecutive => 0,
      turn => undefined,
      told => false}.

%%====================================================================
%% Saying it loudly
%%====================================================================

%% Once per run of failures, and immediately when a model is GONE: a 404 is not
%% a bad moment, it is a model that does not exist any more. A line per turn
%% forever would be the noise the ledger's own notice avoids, and the run resets
%% on the next answer, so this is a line per outage rather than per attempt.
%%
%% The GONE line names the second thing a 404 can mean, because the two have the
%% same fix and the mind cannot tell them apart from here: a retired model id and
%% a base path that lost its version segment look identical from the far end.
loud(Key, #{class := gone, told := false} = Record) ->
    say(Key, Record, "is GONE (404 or 410: the model is not served any more, or the "
                     "endpoint path is wrong) and will waste a call on every turn");
loud(Key, #{consecutive := N, told := false} = Record) when N >= ?STRIKES ->
    say(Key, Record, "has failed " ++ integer_to_list(N) ++ " turns in a row");
loud(_Key, _Record) ->
    ok.

say({Provider, Model}, Record, What) ->
    logger:error("[mind_argos] ~s on ~s ~s; last ~p. The pool still calls it: "
                 "this is a record, not a rest.", [Model, Provider, What, maps:get(class, Record)]),
    true = ets:insert(table(), {key(Provider, Model), Record#{told => true}}),
    ok.

%%====================================================================
%% Reading a failure the way the pool talks about it
%%====================================================================

%% The classes are the ones the pool and the breaker already use, so a reader
%% can put the two records side by side without translating between them. A
%% 404 or a 410 is the one that means the model is not there any more; 429 and
%% the credential classes are the breaker's own subjects, kept here so that a
%% model that is being rate-limited is not mistaken for one that is gone.
-spec classify(term()) -> class().
classify({http_status, 404, _Body}) -> gone;
classify({http_status, 410, _Body}) -> gone;
classify({http_status, 429, _Body}) -> rate_limited;
classify({http_status, 429, _Body, _RetryAfter}) -> rate_limited;
classify({http_status, 401, _Body}) -> credential;
classify({http_status, 403, _Body}) -> credential;
classify({http_status, Code, _Body}) when is_integer(Code), Code >= 500 -> server;
classify({http_status, _Code, _Body}) -> other;
classify({unreachable, timeout}) -> timeout;
classify({unreachable, _Reason}) -> unreachable;
classify({not_json, _Body}) -> parse;
classify(truncated) -> parse;
classify(no_choice) -> parse;
classify(_SomethingElse) -> other.

%%====================================================================
%% The file: dates only, one small term, replaced atomically
%%====================================================================

%% ⚠ WRITTEN THROUGH A TEMPORARY AND RENAMED, not written in place. A reader
%% that catches a half-written file is the one case this record must not have: a
%% truncated term decodes to nothing, and "nothing" here means the dates the file
%% exists to keep. The rename is atomic within one directory, so a reader sees
%% the old file or the new one and never a mixture.
kept(Key, Record) ->
    written(write(maps:put(Key, dates(Record), read()))).

%% ⚠ A WRITE THAT FAILS MUST NOT COST A TURN. What a failed write loses is the
%% DATE across a restart, and that is not worth a mind that cannot think, which
%% is the same bargain the read path makes. Said once per process rather than per
%% write: a full or read-only data directory would otherwise be one line per
%% turn forever, which is the noise this module exists to cut through. The latch
%% is the process dictionary because the mind IS one process, and a latch is all
%% it is.
written(ok) ->
    ok;
written({error, Reason}) ->
    said_once(Reason).

said_once(Reason) ->
    case erlang:get(?WRITE_WARNED) of
        true -> ok;
        _    -> logger:warning("[mind_argos] the record could not be written (~p); "
                               "the dates will not survive a restart", [Reason]),
                erlang:put(?WRITE_WARNED, true),
                ok
    end.

dates(Record) ->
    #{last_success_at => maps:get(last_success_at, Record),
      last_failure_at => maps:get(last_failure_at, Record),
      class => maps:get(class, Record)}.

%% EVERY STEP RETURNS ITS FAILURE rather than asserting on it, which is the
%% difference between a mind that cannot take a note and a mind that cannot
%% think: the caller turns an error into one warning and carries on.
write(All) ->
    Path = path(),
    Tmp = Path ++ ".tmp",
    replaced(made_directory(Path), Tmp, Path, term_to_binary(All)).

made_directory(Path) ->
    filelib:ensure_path(filename:dirname(Path)).

replaced(ok, Tmp, Path, Bin) ->
    renamed(file:write_file(Tmp, Bin), Tmp, Path);
replaced({error, _} = Error, _Tmp, _Path, _Bin) ->
    Error.

renamed(ok, Tmp, Path) -> file:rename(Tmp, Path);
renamed({error, _} = Error, _Tmp, _Path) -> Error.

%% A file that is missing, unreadable, or written by an older shape is not an
%% error and not a crash: it is no record. `safe' on the decode is what keeps a
%% corrupted file from being able to mint atoms in the node that reads it.
read() ->
    case file:read_file(path()) of
        {ok, Bin} -> decoded(Bin);
        {error, _} -> #{}
    end.

decoded(Bin) ->
    try binary_to_term(Bin, [safe]) of
        Term when is_map(Term) -> Term;
        _NotARecord            -> #{}
    catch
        _:_ -> #{}
    end.

%% ONE READER FOR THE DATA DIRECTORY, and it is not this module. The ledger
%% already reads MCL_DATA_DIR, and a second reader is how two settings for one
%% directory drift apart (the same shape of defect as mcl-spartan#2, where two
%% readers for one setting disagreed about the shape they took).
path() ->
    filename:join(mind_budget:data_dir(), ?RECORD_FILE).

now_s() -> erlang:system_time(second).

%% Created on first use rather than by a supervisor, as the breaker's table is:
%% this is bookkeeping for a pure function called from the mind's own reasoning
%% process, and a table that has to exist before anyone can think is a worse
%% dependency than one that appears when first needed.
table() ->
    ensure(ets:whereis(?TABLE)).

ensure(undefined) ->
    _ = catch ets:new(?TABLE, [set, public, named_table, {write_concurrency, true}]),
    ok = load(),
    ?TABLE;
ensure(_Tid) ->
    ?TABLE.
