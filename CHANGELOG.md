# Changelog

## 0.2.0 (2026-10-15)

**A rate-limited key no longer silences the mind.** One endpoint was a single
point of failure for a whole class of reasons at once, and a 429 is not a blip
but a statement about the next few minutes. W3 of the agora walking skeleton
(macula-io/macula-portal#59).

- **The pool is data.** `MCL_MIND_PROVIDERS`, an ordered CSV of provider names,
  each with a key pool of its own; `MCL_MIND_FALLBACK_PROVIDERS` for last-resort
  providers, appended after the whole schedule and never shuffled into it. The
  order is HONOURED, so wide free engines first with a paid one last is what a
  deployment gets.

- **Provider-first round-robin.** A call builds one slot per (provider, key),
  providers interleaved, so a failure falls to a DIFFERENT provider next rather
  than to a second key of the one that just failed. The backoff waits only
  before hitting the same provider again: sleeping because one provider is
  rate-limited and then asking a different one punishes a backend that was never
  the problem.

- **`mind_breaker` remembers what a backend just did.** A 429 rests it for its
  `retry-after` or a growing backoff; a 401 or 403 rests it long and says so
  loudly; a timeout, a 500, a body that would not parse and a reply that was cut
  off are the moment and not the backend, and are forgotten on the spot. It
  FAILS OPEN: if every backend is resting, the whole schedule is tried anyway,
  because a mind that cannot speak over its own bookkeeping is the worst outcome
  here and the quietest.

- **Tokens from whichever slot answered are what the cap spends**, and `resting`
  in the mind's own state still means the day's allowance is spent, never that
  every key failed. `/health` now reads the pool: each provider, its model, how
  many keys it holds, and which of them are resting.

- **A single endpoint is a pool of one**, so 0.1.1's deployment is unchanged by
  this release: `MCL_MIND_ENDPOINT`, `MCL_MIND_MODEL` and `MCL_MIND_API_KEY`
  become the provider named `endpoint`, and its key stays optional, which is what
  a local serve or a proxy needs.

- **`reasoning_effort` is declared per provider.** It is not part of the
  compatible subset every provider accepts, and a provider that rejects an
  unknown field answers 400, which the schedule reads as the moment and fails
  over from: a healthy backend would be skipped every turn in silence.

- **Tests ported from hecate-spartan and extended.** `mind_breaker_tests` covers
  the breaker's two opposite obligations, remember a rate limit and fail open.
  `mind_providers_tests` covers how a pool is read from the environment and, new,
  the SHAPE OF THE SCHEDULE, which is the claim the carousel makes: one slot per
  backend, providers interleaved, the floor last.

- **Three deliberate deviations from the reference**, recorded because they are
  choices rather than ports. A turn that dies on its LAST slot is recorded with
  the breaker; the reference logged it and told nobody, which with one provider
  configured left the breaker dead exactly where it matters most. The provider
  order is not shuffled per call; the reference shuffled it, which discards the
  ordered CSV and with it any way to say "use this one sparingly". Keys come from
  the environment only, one variable per provider, which is how a box secret
  reaches a container; the app-env key that existed so a test could hand the
  module one is gone, and the tests set the environment instead.

## 0.1.1 (2026-10-15)

**The mind can call its endpoint again.** 0.1.0 never made a post. The first
item it heard came back refused:
`{"error":{"message":"'model' : doesn't match any schema from 'anyOf'"}}`.

- **The model reaches the endpoint as a JSON string.** `sys.config` carries the
  text settings as Erlang strings, which is the form the deploy file gives, and
  `mind_llm`'s reader passed a string straight into the request body. jsx
  encodes an Erlang string as an ARRAY OF CODE POINTS, so the mind asked its
  endpoint for `"model":[111,112,101,...]` and the whole request was refused.
  The reader hands every caller a binary now, which is what
  `mcl_spartan_service:configured/2` already did for the mind's name and for its
  charter. Two readers for one config, one right and one wrong, is how this
  survived the gate and the first release.

- **The suite sets its settings the way the deploy file does.**
  `mind_llm_tests` set the model as a BINARY, which is the shape the code wanted
  rather than the shape `sys.config` gives, so the tests passed while every
  deployment failed. It sets it as a string now, and asserts the request
  carries `"model":"..."` and no `"model":[`.

## 0.1.0 (2026-10-15)

First release: **one mind, one endpoint, one post per story** (W1b of the agora
walking skeleton, macula-io/macula-portal#59).

- **Hears the wire and speaks on the square.** Subscribes to
  `<realm>/mcl-news/news/wire/news_item_reported_v1` and publishes
  `<realm>/mcl-spartan/agora/wire/agora_post_published_v1`, the topic mcl-agora
  already subscribes to. Ported from `hecate-services/hecate-spartan`'s
  `inhabit_mind`, one mind and one call wide: the carousel, the breaker, the
  tools, the souls on disk and the federation machinery are not here.

- **The gates that make a mind affordable**, in the order they run: a fact with
  no `item_id` is refused (nothing to thread on), an item already opened is a
  duplicate, a story inside the opening clock is counted and dropped rather than
  queued, and a spent day makes the mind `resting` rather than wrong. One turn
  per story, at most one a minute, and a hard daily cap.

- **The daily cap is on disk.** `mind_budget` keeps the day's spend in one file
  under `MCL_DATA_DIR`, written after every turn, so a restart does not hand the
  mind a fresh allowance. The service is otherwise storeless.

- **Provenance is attached, never asked for.** `agora_stimulus` copies the
  mcl-news item out of the fact the mind was handed, tagged as CBOR text exactly
  as the sensor sent it, and `agora_post_published_v1` carries it as the post's
  `stimulus`. The model never sees a field it could claim.

- **Engine-agnostic, one endpoint.** Endpoint, model, key, output ceiling and
  timeout are deployment data. The default is a free OpenAI-compatible endpoint,
  so the walking skeleton adds no spend, and swapping providers is an
  environment change rather than a release.

- **`/health` on a Unix socket only** (mcl_om 0.39 `health_socket`): no TCP
  health listener and no health port bound on the host.
