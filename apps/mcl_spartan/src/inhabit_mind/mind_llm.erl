%%% @doc Where a mind reaches off the BEAM to think: a POOL of providers, walked
%%% until one answers.
%%%
%%% ENGINE-AGNOSTIC BY CONFIG, NOT BY CODE. Which engines a mind may think with
%%% is deployment data (`MCL_MIND_PROVIDERS`), not a baked-in choice: nothing
%%% here names one as THE provider, and moving a mind to another is an
%%% environment change rather than a release.
%%%
%%% == Why a pool ==
%%%
%%% One endpoint and one key is a single point of failure that fails for a whole
%%% class of reasons at once: a rate limit, a key that was rotated, an account
%%% that ran out. A 429 is not a blip, it is a statement about the next few
%%% minutes, and a mind with one key hears it as silence. A pool answers it with
%%% the next slot.
%%%
%%% The CSV is ORDERED and the order is honoured: providers are tried as listed,
%%% so a deployment can put the wide free engines first and a paid one last, and
%%% get what it wrote. The reference implementation shuffled the provider order
%%% on every call, which spreads load but silently discards the order the
%%% operator wrote (and with it any way to say "use this one sparingly").
%%% Keys WITHIN a provider are shuffled, because that is where per-key quotas
%%% live and the keys of one provider are interchangeable.
%%%
%%% == The schedule ==
%%%
%%% A call builds ONE SLOT PER (provider, key), interleaved provider-first, so a
%%% failure falls to a DIFFERENT provider next rather than to a second key of
%%% the one that just failed. The schedule used to be a fixed number of slots
%%% drawn round-robin from the pools, which with one provider configured meant
%%% every slot pointing at the same provider and the same key: on 2026-09-02
%%% that cost about twenty-six seconds of backoff per turn, hammering an
%%% endpoint that had already answered 429 six times, before reaching a fallback
%%% that answered 200 immediately.
%%%
%%% The backoff waits ONLY before hitting the same provider again. Sleeping
%%% because one provider is rate-limited and then asking a different one
%%% punishes a backend that was never the problem, and that sleep was most of a
%%% turn's latency.
%%%
%%% == The fallback floor ==
%%%
%%% `MCL_MIND_FALLBACK_PROVIDERS` names last-resort providers, appended after
%%% the WHOLE primary schedule and never shuffled into it. A slow but sovereign
%%% local engine belongs here: it keeps the mind speaking when every brokered
%%% provider fails, without ever slowing a normal turn. A provider already in
%%% the pool is not repeated as a fallback: every key of it was just tried, and
%%% the first key again is the most likely one to be rate-limited.
%%%
%%% == What the endpoint reported is what is counted ==
%%%
%%% `usage.total_tokens` is the number the daily cap spends, from whichever slot
%%% answered. An endpoint that reports no usage would make the cap
%%% unenforceable, so that case falls back to a character estimate rather than
%%% to zero.
%%%
%%% ⚠ AND THE SLOTS THAT FAILED ARE COUNTED TOO. A 200 whose reply this code
%%% cannot use (a paragraph cut off by the token limit, a body that is not JSON,
%%% a reply with no choice in it) has already cost what the endpoint reports, and
%%% a walk that gave up after three slots spent at three: a turn that failed
%%% answers `{error, Reason, Tokens}' and the caller charges it. Only a REFUSED
%%% request is free, because a 429, a 500 or an unreachable host is one the
%%% provider did not answer at all.
-module(mind_llm).

-export([reason/2, config/0]).
-export([endpoint/0, model/0, timeout_ms/0, max_tokens/0]).
-export([providers/0, fallback_providers/0, provider_labels/0, fallback_labels/0,
         provider_config/1]).
%% The schedule, exported for the tests: it is the part config gets wrong.
-export([plan/0, schedule/0]).

-define(DEFAULT_ENDPOINT, "https://api.groq.com/openai/v1/chat/completions").
-define(DEFAULT_MODEL, <<"openai/gpt-oss-20b">>).
-define(DEFAULT_TIMEOUT_MS, 30000).
%% A REASONING MODEL SPENDS THIS BUDGET ON THINKING BEFORE IT WRITES ANYTHING,
%% and reasoning tokens count against the completion limit. At 300 a long think
%% produced an EMPTY content, which reads here as "nothing to say", so the one
%% post this service exists to make came down to luck. `reasoning_effort` is
%% sent low for the same reason (to the providers that declare they take it),
%% and a reply that still runs out of room is reported as truncated rather than
%% taken for silence: only the two of those together make an empty post mean
%% what it says.
-define(DEFAULT_MAX_TOKENS, 1024).
-define(CHARS_PER_TOKEN, 4).
-define(TEMPERATURE, 0.7).

%% --- the providers this code knows how to call ---
%%
%% A provider is a clause plus a name in a mind's `MCL_MIND_PROVIDERS`. Only
%% providers whose keys answer TODAY are here: a ported constant naming a model
%% that has since been retired is a backend that fails every turn, silently
%% skipped by the schedule, and the old code carried two of those (a NIM model
%% that reached end-of-life days after it was verified, and a Cerebras model the
%% catalog no longer serves). Adding one is two lines plus its key environment
%% variable, and it should be added on the day a real call answers.
-define(GROQ_URL, "https://api.groq.com/openai/v1/chat/completions").
-define(GROQ_MODEL, <<"openai/gpt-oss-20b">>).
-define(DEEPSEEK_URL, "https://api.deepseek.com/v1/chat/completions").
-define(DEEPSEEK_MODEL, <<"deepseek-chat">>).
-define(MELIOUS_URL, "https://api.melious.ai/v1/chat/completions").
-define(MELIOUS_MODEL, <<"qwen3.5-9b">>).
-define(MISTRAL_URL, "https://api.mistral.ai/v1/chat/completions").
-define(MISTRAL_MODEL, <<"mistral-small-latest">>).
%% NVIDIA's free NIM catalog, whose MODEL MOVES and is therefore a deployment
%% setting rather than a constant. The previous default reached end-of-life days
%% after it was verified, and every attempt then failed straight to the next
%% carousel slot without anything saying so; the catalog is also wider than the
%% account can use (models list in /v1/models and answer 404 on a real call), so
%% a model is chosen the day a real call answers, not from a listing.
%%
%% The default is the one the Supervisor verified live and did NOT flag: the
%% 550b "ultra" answers too and returns 503 when it is busy, which is a wasted
%% slot on every busy turn rather than a wrong answer, so it is the second
%% choice rather than the default.
-define(NVIDIA_URL, "https://integrate.api.nvidia.com/v1/chat/completions").
-define(NVIDIA_MODEL, <<"nvidia/nemotron-3-super-120b-a12b">>).

%% The keyless floor: a local OpenAI-compatible serve on the box, at
%% seconds-per-token. It gets its own patience and its own short output cap so a
%% fallback turn FINISHES instead of timing out at a fast provider's patience.
-define(LOCAL_TIMEOUT_MS, 600000).
-define(LOCAL_MAX_TOKENS, 160).

-define(BASE_BACKOFF_MS, 400).
-define(JITTER_MS, 500).

%% @doc One reasoning turn, against the pool: the charter as the system message,
%% the item as the user message, and the first answer back with what the turn
%% cost.
%%
%% ⚠ A TURN THAT FAILS IS NOT A FREE TURN, SO THE FAILURE CARRIES ITS COST. An
%% endpoint that answers 200 with something this code cannot use (a paragraph cut
%% off by the token limit, a body that is not JSON, a reply with no choice in it)
%% has already spent what it reports, and a walk that gave up after three slots
%% spent at all three. The caller charges that to the daily cap. A cap that
%% counted only the turns that worked would be a cap a failing pool spends
%% straight through, which is the opposite of what a cap is for.
%%
%% `tokens' in the answer is what the WHOLE TURN cost, so a turn that truncated
%% at one provider and was answered by the next is charged for both.
%%
%% `engine' in the answer is the provider and the model that ANSWERED, not the
%% first one configured: a pool of three makes those different facts, and only
%% this module can tell a caller which it was.
-spec reason(binary(), binary()) -> {ok, map()} | {error, term(), non_neg_integer()}.
reason(Charter, Prompt) ->
    reason_with([#{<<"role">> => <<"system">>, <<"content">> => Charter},
                 #{<<"role">> => <<"user">>, <<"content">> => Prompt}]).

reason_with(Messages) ->
    case schedule() of
        []    -> {error, no_backend, 0};
        %% The turn is named once, here, and every slot of it carries the name.
        %% This is the only place that knows where a turn begins, and the argos
        %% record needs it: the schedule holds one slot per (provider, key), so a
        %% provider with several keys walks the same {Provider, Model} pair more
        %% than once inside this one turn, and counting those as separate
        %% failures would make one bad moment look like a run of them.
        Slots -> walk(Messages, Slots, 1, erlang:unique_integer([monotonic, positive]))
    end.

%% @doc What this mind is configured to think with, for /health and the logs.
%% Keys are reported as a COUNT and never as a value; which providers are
%% resting right now is the answer to "is it the wire or is it the backends".
-spec config() -> map().
config() ->
    #{providers => provider_labels(),
      fallback => fallback_labels(),
      pool => [pool_report(Pool) || Pool <- pools()]}.

pool_report({Config, Keys}) ->
    #{provider => label(Config),
      model => maps:get(model, Config, undefined),
      keys => length(Keys),
      resting => mind_breaker:resting(Config)}.

%%====================================================================
%% The schedule
%%====================================================================

%% @doc The slots a call would walk, in order, before the breaker has its say.
%%
%% It also says which names it had to leave out, once per schedule. A name that
%% is dropped in SILENCE is how a deployment ends up with one provider when it
%% asked for three, which is the failure this release exists to fix.
-spec plan() -> [mind_breaker:slot()].
plan() ->
    {Pooled, Missing} = pools_of(providers()),
    {Fallback, FallbackMissing} = pools_of(fallback_providers()),
    ok = noted(Missing ++ FallbackMissing),
    every_backend_once(Pooled) ++ fallback_slots(Pooled, Fallback).

%% @doc The same schedule minus backends that are resting. FAILS OPEN: if that
%% would leave nothing, the whole plan is walked anyway.
-spec schedule() -> [mind_breaker:slot()].
schedule() ->
    mind_breaker:usable(plan()).

%% The pool on its own, without the log line: this is what the report a health
%% check reads is built from, and a health check must not write a line per read.
pools() ->
    element(1, pools_of(providers())).

%% The pool, and the names that did NOT make it: a name this code does not know,
%% or a keyed provider with no key. Both are dropped by design (a slot that
%% cannot authenticate spends a call to learn what the log already knows), and
%% both are worth saying out loud.
pools_of(Names) ->
    lists:foldr(fun pooled/2, {[], []}, Names).

pooled(Name, {Pooled, Missing}) ->
    case provider_config(Name) of
        undefined -> {Pooled, [{Name, unknown} | Missing]};
        Config    -> keyed(Name, Config, Pooled, Missing)
    end.

keyed(Name, Config, Pooled, Missing) ->
    case provider_keys(Config) of
        []   -> {Pooled, [{Name, maps:get(keyenv, Config)} | Missing]};
        Keys -> {[{Config, shuffle(Keys)} | Pooled], Missing}
    end.

noted(Missing) ->
    [warn(Dropped) || Dropped <- lists:usort(Missing)],
    ok.

warn({Name, unknown}) ->
    logger:warning("[mind_llm] ~s is named in a pool and this code does not know it; "
                   "it is not in the schedule", [Name]);
warn({Name, NoKeyEnv}) ->
    logger:warning("[mind_llm] ~s is named in a pool with no key in ~s; "
                   "it is not in the schedule", [Name, NoKeyEnv]).

%% One slot per (provider, key), providers interleaved so a turn tries a
%% different provider before a second key of the one that just failed.
every_backend_once(Pools) ->
    interleave([[{Config, Key} || Key <- Keys] || {Config, Keys} <- Pools]).

interleave([])    -> [];
interleave(Lists) ->
    Heads = [Head || [Head | _] <- Lists],
    Tails = [Tail || [_ | Tail] <- Lists, Tail =/= []],
    Heads ++ interleave(Tails).

%% One slot per configured fallback, in listed order, and only for a provider
%% that is not already in the pool.
fallback_slots(Pooled, Fallback) ->
    PooledLabels = [label(Config) || {Config, _Keys} <- Pooled],
    [{Config, hd(Keys)}
     || {Config, Keys} <- Fallback, not lists:member(label(Config), PooledLabels)].

%%====================================================================
%% The providers
%%====================================================================

%% @doc The pool this mind walks, in the order the deployment wrote it.
-spec providers() -> [string()].
providers() ->
    csv_env("MCL_MIND_PROVIDERS", default_providers()).

%% The pool a deployment that names no pool has: the one endpoint W1b deployed,
%% as a pool of one. A mind that is live keeps thinking while the deeper pool is
%% a deployment change rather than a second release.
default_providers() ->
    ["endpoint"].

%% @doc Last-resort providers, tried only after the whole pool is exhausted.
-spec fallback_providers() -> [string()].
fallback_providers() ->
    csv_env("MCL_MIND_FALLBACK_PROVIDERS", []).

%% @doc The pool as a human CSV, for the mind's own report.
-spec provider_labels() -> binary().
provider_labels() ->
    labels(providers()).

-spec fallback_labels() -> binary().
fallback_labels() ->
    labels(fallback_providers()).

labels(Names) ->
    iolist_to_binary(lists:join(<<",">>, [unicode:characters_to_binary(N) || N <- Names])).

%% @doc A provider's endpoint, model and key environment variable.
%%
%% `timeout` and `max_tokens` are per provider because a local engine's patience
%% and output cap are nothing like a fast broker's. `reasoning_effort` is
%% declared only where the model is a reasoning model: the field is not part of
%% the compatible subset every provider accepts, and a provider that rejects an
%% unknown field would answer 400, which the schedule treats as the moment and
%% fails over from, skipping a healthy backend in silence.
-spec provider_config(string()) -> map() | undefined.
provider_config("groq") ->
    #{url => ?GROQ_URL, model => ?GROQ_MODEL, keyenv => "GROQ_API_KEYS",
      label => "groq", reasoning_effort => <<"low">>};
provider_config("deepseek") ->
    #{url => ?DEEPSEEK_URL, model => env_text("MCL_DEEPSEEK_MODEL", ?DEEPSEEK_MODEL),
      keyenv => "DEEPSEEK_API_KEYS", label => "deepseek"};
provider_config("melious") ->
    #{url => ?MELIOUS_URL, model => env_text("MCL_MELIOUS_MODEL", ?MELIOUS_MODEL),
      keyenv => "MELIOUS_API_KEY", label => "melious", reasoning_effort => <<"low">>};
provider_config("mistral") ->
    #{url => ?MISTRAL_URL, model => env_text("MCL_MISTRAL_MODEL", ?MISTRAL_MODEL),
      keyenv => "MISTRAL_API_KEYS", label => "mistral"};
provider_config("nvidia") ->
    #{url => ?NVIDIA_URL, model => env_text("MCL_NVIDIA_MODEL", ?NVIDIA_MODEL),
      keyenv => "NVIDIA_API_KEYS", label => "nvidia"};
%% The one endpoint a deployment named, which is what a mind with no pool has.
%% Its key is OPTIONAL: a local serve or a proxy takes no bearer, and the
%% single-endpoint deployment called out with no authorization header whenever
%% no key was set.
provider_config("endpoint") ->
    #{url => endpoint(), model => model(), keyenv => "MCL_MIND_API_KEY",
      label => "endpoint", key_optional => true, reasoning_effort => <<"low">>};
%% The keyless local floor. A local engine is a deployment fact (which box hosts
%% it, which model it was converted to), so this provider exists only when a
%% deployment names one: a baked-in localhost default would turn a
%% misconfiguration into a silent call to nowhere.
provider_config("local") ->
    local_config(os:getenv("MCL_MIND_LOCAL_URL"));
provider_config(_Unknown) ->
    undefined.

local_config(Url) when is_list(Url), Url =/= "" ->
    #{url => Url, model => env_text("MCL_MIND_LOCAL_MODEL", <<"local">>),
      keyenv => "MCL_MIND_LOCAL_API_KEY", label => "local",
      key_optional => true, timeout => ?LOCAL_TIMEOUT_MS, max_tokens => ?LOCAL_MAX_TOKENS};
local_config(_Unset) ->
    undefined.

%% The keys a provider would be called with. A provider whose key is OPTIONAL
%% (the one endpoint a deployment named, and the keyless local floor) answers a
%% single slot with no key at all rather than none: the call is the point, and a
%% local serve ignores a bearer anyway.
provider_keys(#{key_optional := true} = Config) ->
    case keys(Config) of
        []   -> [undefined];
        Keys -> Keys
    end;
provider_keys(Config) ->
    keys(Config).

%% A pool is a CSV: one key is a pool of one. Whitespace is trimmed and empty
%% parts are dropped, so " k1 , , k2 " is two keys and not four.
keys(#{keyenv := Env}) ->
    case os:getenv(Env) of
        false -> [];
        ""    -> [];
        Csv   -> split_csv(Csv)
    end.

%%====================================================================
%% The walk
%%====================================================================

%% The last slot has its own clause: its failure is the end of the schedule and
%% the evidence for why the turn was lost, so it is reported and kept.
%%
%% ⚠ THE REFERENCE DID NOT TELL THE BREAKER ABOUT IT, and only logged it. With
%% one provider configured that leaves the breaker dead exactly where it matters
%% most, and a one-provider pool is what is live today: a rate limit would be
%% rediscovered on every single turn. This records it like any other failure.
walk(Messages, [{Config, Key}], _N, Turn) ->
    case once(Config, body(Config, Messages), Key) of
        {ok, _Reply} = Answered ->
            answered(Config, Answered);
        {error, Why, Tokens} ->
            ok = failed(Config, Why, Turn),
            logger:notice("[mind_llm] ~s failed on the last slot (~p); "
                          "schedule exhausted, this turn is lost", [label(Config), Why]),
            {error, {all_backends_exhausted, label(Config), Why}, Tokens}
    end;
walk(Messages, [{Config, Key} | Rest], N, Turn) ->
    case once(Config, body(Config, Messages), Key) of
        {ok, _Reply} = Answered ->
            answered(Config, Answered);
        {error, Why, Tokens} ->
            ok = failed(Config, Why, Turn),
            Delay = pause_before(Rest, Config, N),
            logger:info("[mind_llm] ~s failed (~p); next slot in ~bms",
                        [label(Config), Why, Delay]),
            sleep(Delay),
            charged(walk(Messages, Rest, N + 1, Turn), Tokens)
    end.

%% The engine travels out with the answer, because THIS is the only place that
%% knows which slot answered: the schedule is a list and the caller sees one
%% reply. The post carries it so a reader can check the claim, and it is filled
%% in here rather than at the call site precisely so it cannot be filled in from
%% the head of the schedule, which would be a lie that looks exactly like the
%% truth.
answered(Config, {ok, Reply}) ->
    _ = mind_breaker:worked(Config),
    _ = mind_argos:succeeded(provider(Config), model_of(Config)),
    {ok, Reply#{engine => engine_of(Config)}}.

%% Every slot attempt is written down TWICE, in the two places that keep
%% different memories of it: the breaker, which is keyed on the provider because
%% quota is, and the argos record, which is keyed on the model because liveness
%% is. Both are told from here, where the attempt actually happened, so neither
%% can be told about a slot that was never tried. The turn travels on with it,
%% because the argos record counts a pair's failures once per turn: several keys
%% of one provider is one backend seen several times, not several turns.
failed(Config, Why, Turn) ->
    _ = mind_breaker:failed(Config, Why),
    _ = mind_argos:failed(provider(Config), model_of(Config), Why, Turn),
    ok.

%% The provider by its configured name and the model it was asked for, both as
%% text for the wire. A provider that answered with a model nobody configured is
%% not a case that can happen here: the model is part of the request.
engine_of(Config) ->
    #{provider => provider(Config), model => model_of(Config)}.

provider(Config) -> unicode:characters_to_binary(label(Config)).

model_of(Config) -> maps:get(model, Config, <<>>).

%% What a slot that failed still cost, added to whatever the turn ends up
%% costing: the address of a truncated reply at one provider is part of the
%% price of the turn another provider answered.
charged({ok, #{tokens := Tokens} = Reply}, Before) ->
    {ok, Reply#{tokens := Tokens + Before}};
charged({error, Why, Tokens}, Before) ->
    {error, Why, Before + Tokens}.

%% Wait only before hitting the SAME provider again.
pause_before([{Next, _Key} | _], Config, N) ->
    same_provider(label(Next) =:= label(Config), N).

same_provider(true, N)   -> (?BASE_BACKOFF_MS bsl min(N - 1, 5)) + rand:uniform(?JITTER_MS);
same_provider(false, _N) -> 0.

sleep(0)     -> ok;
sleep(Delay) -> timer:sleep(Delay).

label(Config) -> maps:get(label, Config, "?").

timeout_of(Config) -> maps:get(timeout, Config, timeout_ms()).

%%====================================================================
%% The call
%%====================================================================

once(Config, Body, Key) ->
    ok = ensure_http(),
    case httpc:request(post, {maps:get(url, Config), headers(Key), "application/json", Body},
                       [{timeout, timeout_of(Config)}, {connect_timeout, timeout_of(Config)},
                        {ssl, ssl_opts()}],
                       [{body_format, binary}]) of
        {ok, {{_Version, 200, _Reason}, _Headers, Response}} ->
            parse(Response, byte_size(Body));
        {ok, {{_Version, 429, _Reason}, Headers, Response}} ->
            %% ⚠ A REFUSED REQUEST COSTS NOTHING HERE, AND THAT IS DELIBERATE. A
            %% 429, a 500 or an unreachable host is a request the provider did
            %% not answer: there is no usage to carry, and charging an estimate
            %% for it would drive a mind with a broken pool into `resting' for a
            %% spend that never happened, which stops it speaking instead of
            %% keeping it trying. Only a 200 that produced something costs.
            {error, {http_status, 429, clip(Response), retry_after(Headers)}, 0};
        {ok, {{_Version, Status, _Reason}, _Headers, Response}} ->
            {error, {http_status, Status, clip(Response)}, 0};
        {error, Reason} ->
            {error, {unreachable, Reason}, 0}
    end.

%% A rate limit usually says when to come back. Discarding the headers threw
%% away the one piece of information a 429 actually carries: how long the quota
%% is gone for.
%%
%% Seconds, per RFC 9110. The HTTP-date form is legal and nobody sends it for a
%% rate limit, so an unparseable value means "we were not told".
retry_after(Headers) ->
    seconds(lists:keyfind("retry-after", 1,
                          [{string:lowercase(K), V} || {K, V} <- Headers])).

seconds({_K, V}) when is_list(V) -> whole(string:to_integer(string:trim(V)));
seconds(_AbsentOrUnusable)       -> undefined.

whole({N, _Rest}) when is_integer(N), N > 0 -> N;
whole(_NotSeconds)                          -> undefined.

%% @private The prompt is a fixed size per turn, so the question the endpoint
%% answered is the cost question: only the answer's own length is unknown.
parse(Response, RequestBytes) ->
    try jsx:decode(Response, [return_maps]) of
        Decoded -> parsed(Decoded, RequestBytes)
    catch
        _:_ -> {error, {not_json, clip(Response)}, estimate(RequestBytes, <<>>)}
    end.

%% ⚠ A BODY THAT IS VALID JSON AND NOT AN OBJECT IS NOT A MIND-KILLER. jsx
%% decodes `[]' into a LIST and `null' into an atom, and the usage reader assumed
%% an object: a `badmap' raised here runs inside the mind's own cast, so a gateway
%% answering `[]' repeatedly would kill the mind and take everything queued
%% behind it with it. An endpoint having a bad day costs the TURN, which the
%% schedule fails over from, and never the mind.
parsed(#{<<"choices">> := [#{<<"message">> := Message} | _] = Choices} = Decoded, RequestBytes)
  when is_map(Message) ->
    content(Message, finish(Choices), Decoded, RequestBytes);
parsed(Decoded, RequestBytes) ->
    {error, no_choice, used(Decoded, RequestBytes, <<>>)}.

%% A reply the endpoint cut off is not a post. `length` means the model was
%% still writing when it ran out of room, and what came back is a paragraph
%% ending mid-sentence: publishing that is worse than saying nothing, and
%% treating it as silence would hide a budget that is too small.
%%
%% ⚠ AND IT IS NOT FREE EITHER. The endpoint reports what it charged for the
%% thinking it did, including the thinking that produced the sentence it was
%% cut off in the middle of. Discarding that number is how a pool that truncates
%% every reply spent without limit: the cap counted the turns that worked and
%% called the failures free.
content(Message, <<"length">>, Decoded, RequestBytes) ->
    {error, truncated, used(Decoded, RequestBytes, text(maps:get(<<"content">>, Message, <<>>)))};
content(Message, _FinishReason, Decoded, RequestBytes) ->
    Body = text(maps:get(<<"content">>, Message, <<>>)),
    {ok, #{body => Body, tokens => used(Decoded, RequestBytes, Body)}}.

finish([#{<<"finish_reason">> := Reason} | _]) -> Reason;
finish([_Other | Rest])                        -> finish(Rest);
finish([])                                     -> undefined.

text(Content) when is_binary(Content) -> Content;
text(_NotText)                        -> <<>>.

%% A usage field is only readable when the body that carried it was an object.
%% Anything else (a bare array, a bare string, a gateways's html that happened to
%% parse) has nothing to report and falls to the estimate.
used(Decoded, RequestBytes, Content) when is_map(Decoded) ->
    tokens(maps:get(<<"usage">>, Decoded, undefined), RequestBytes, Content);
used(_NotAnObject, RequestBytes, Content) ->
    estimate(RequestBytes, Content).

%% What the endpoint says it cost, or an estimate when it declines to say:
%% characters over four, which is the usual rule of thumb for English prose and
%% is deliberately generous rather than clever, because an under-count here is
%% a cap that does not hold.
tokens(#{<<"total_tokens">> := Total}, _RequestBytes, _Content)
  when is_integer(Total), Total >= 0 ->
    Total;
tokens(_UnsaidOrUnusable, RequestBytes, Content) ->
    estimate(RequestBytes, Content).

estimate(RequestBytes, Content) ->
    (RequestBytes + byte_size(Content)) div ?CHARS_PER_TOKEN.

%% --- the request ---

body(Config, Messages) ->
    jsx:encode(thinking(#{<<"model">> => maps:get(model, Config),
                          <<"messages">> => Messages,
                          <<"max_tokens">> => maps:get(max_tokens, Config, max_tokens()),
                          <<"temperature">> => ?TEMPERATURE}, Config)).

%% A reasoning model's thinking is paid for out of the completion budget, so it
%% is asked to think little: this mind writes one short paragraph, and effort
%% spent elsewhere is room taken from the paragraph. Sent only to the providers
%% that declare they take it.
thinking(Base, Config) ->
    case maps:get(reasoning_effort, Config, undefined) of
        undefined -> Base;
        Effort    -> Base#{<<"reasoning_effort">> => Effort}
    end.

headers(Key) ->
    [{"content-type", "application/json"} | authorization(Key)].

%% A keyless provider gets no header at all rather than a placeholder bearer:
%% the call is the point, and a credential nobody reads is noise in a log.
authorization(undefined) -> [];
authorization(Key)       -> [{"authorization", "Bearer " ++ Key}].

ensure_http() ->
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(ssl),
    ok.

%% Verify against the system trust store, the same posture mcl-news takes for
%% the wire it reads. No Big-Tech SDK sits in this path: one HTTPS POST.
ssl_opts() ->
    [{verify, verify_peer},
     {cacerts, public_key:cacerts_get()},
     {customize_hostname_check,
      [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}].

%% An error body is evidence, so it is kept, but bounded: a gateway error page
%% is not worth a log line per turn forever.
clip(Response) when byte_size(Response) =< 400 -> Response;
clip(Response) -> binary:part(Response, 0, 400).

%%====================================================================
%% Configuration
%%====================================================================
%%
%% ⚠ TEXT AND NUMBERS ARE READ DIFFERENTLY, AND THAT IS NOT PEDANTRY. sys.config
%% substitutes these from the environment, so `{mind_max_tokens, 1024}' arrives
%% as an INTEGER and `{mind_model, "..."}' as a STRING; a helper that only
%% accepted strings would take the ceiling and the timeout from the file and
%% quietly ignore both, leaving every deployment on the defaults with nothing
%% saying so. A number that is not a positive integer is the default.
%%
%% ⚠ AND ONE TYPE COMES OUT OF THE TEXT READER, A BINARY, WHICHEVER FORM WENT
%% IN. A string was passed through unchanged, and a string that reaches
%% jsx:encode comes out as an ARRAY OF CODE POINTS, not as a JSON string: the
%% first deployment asked its endpoint for
%% `"model":[111,112,101,110,97,105,...]' and the endpoint refused the whole
%% request, "'model' : doesn't match any schema from 'anyOf'". The tests missed
%% it because they set the model as a BINARY, which is the shape the code wanted
%% rather than the shape the deploy file gives.
%%
%% Every reader added with the pool obeys both halves of that lesson: one type
%% out, and a value of the wrong shape falls back rather than crashing a turn.

-spec endpoint() -> binary().
endpoint() -> text(mind_endpoint, ?DEFAULT_ENDPOINT).

-spec model() -> binary().
model() -> text(mind_model, ?DEFAULT_MODEL).

-spec timeout_ms() -> pos_integer().
timeout_ms() -> number(mind_timeout_ms, ?DEFAULT_TIMEOUT_MS).

-spec max_tokens() -> pos_integer().
max_tokens() -> number(mind_max_tokens, ?DEFAULT_MAX_TOKENS).

%% @doc One type out, whichever form the deploy file used.
text(Key, Default) ->
    case application:get_env(mcl_spartan, Key, Default) of
        Value when is_binary(Value), Value =/= <<>> -> Value;
        Value when is_list(Value), Value =/= ""     -> unicode:characters_to_binary(Value);
        _                                           -> Default
    end.

number(Key, Default) ->
    case application:get_env(mcl_spartan, Key, Default) of
        Value when is_integer(Value), Value > 0 -> Value;
        _                                       -> Default
    end.

%% A provider setting that arrives on the command line is always text, and it
%% leaves as a binary for the same reason as above.
env_text(Var, Default) ->
    case os:getenv(Var) of
        Value when is_list(Value), Value =/= "" -> unicode:characters_to_binary(Value);
        _Unset                                  -> Default
    end.

csv_env(Var, Default) ->
    case os:getenv(Var) of
        Value when is_list(Value), Value =/= "" -> split_csv(Value);
        _Unset                                  -> Default
    end.

split_csv(S) ->
    [T || Part <- string:tokens(S, ","), (T = string:trim(Part)) =/= ""].

shuffle(List) ->
    [X || {_, X} <- lists:sort([{rand:uniform(), X} || X <- List])].
