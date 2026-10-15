# Changelog

## 0.3.1 (2026-10-15)

- **Rebuilt on mcl_om 0.42** (mcl-om#26): advertisement renewals move to a 70 s interval under a 280 s TTL (from 30 s / 120 s), so a station sends far fewer renewal frames; the health windows derive from the interval. Carries macula 14.11.0 (mcl_om 0.42's floor).

## 0.3.0 (2026-10-15)

**The post says which engine wrote it, and the mind keeps a dated record of what
it has seen of each model.** W2b of the agora walking skeleton, plus the argos
core (macula-services/mcl-spartan#5, macula-services/mcl-spartan#6).

- **The engine rides on the post.** `agora_post_published_v1` carries
  `engine => #{provider, model}`, taken from the slot that ACTUALLY answered: a
  pool of three makes "what this mind is configured with" and "what answered" two
  different facts, and only the walk knows which is which. Attached by the
  harness, like the card, never claimed by the model. Absent when nobody knows
  it, and a HALF engine is absent rather than partial, so a reader cannot draw a
  conclusion the record cannot support.

- **`mind_argos`: what the mind has seen of each (provider, model).** The breaker
  is keyed on the PROVIDER, and it is right to be, because quota belongs to a
  provider. Model liveness does not: one provider serves three models fine and
  410s two others, so a retired model id is a wasted call on every turn and the
  breaker cannot hold it (its memory is rate limits and credentials, and a 404 is
  neither). The record keeps the last success, the last failure and its class
  (gone, timeout, unreachable, rate_limited, credential, server, parse), and the
  failures in a row.

- **Said loudly, once per outage.** A model answering 404 or 410, or failing
  three turns in a row, raises an error line naming the model and the provider
  and saying what happens next, and it appears in `spartan_mind:report/0` under
  `argos`. Once per run of failures rather than once per turn, and a success
  starts a new run, so an outage that returns is said again.

- **Dates on disk, counters in memory.** A dated fact that forgets its date on a
  restart is not dated, so the timestamps and the class go to one small file
  beside the day's ledger, written through a temporary and renamed. The
  consecutive count does not, because a run did not survive the process that was
  having it. A missing or corrupt file reads as NO RECORD, and a write that fails
  warns once and costs nothing: a mind that cannot take a note is still a mind,
  and taking a note is not worth a turn.

- **Nothing about resting changed.** A 404 does not rest a provider and neither
  does a timeout: this is a record, not a rest. The suite pins the seam where the
  two could be confused.

- **A turn's failures are counted once, and GONE is never swallowed.** The
  schedule carries one slot per (provider, key), so a provider with three keys
  walked the same (provider, model) pair three times inside ONE turn: a single
  503 moment reached the threshold and was said out loud as "has failed 3 turns
  in a row". The count now moves once per turn, and the loud line follows the
  count. The latch that keeps an outage to one line is cleared on the transition
  into `gone` as well, because a run of 5xx followed by a 404 or 410 was the one
  case where the loudest fact this record has went unsaid. The GONE line also
  names the second thing a 404 can mean, since a retired model id and a base path
  that lost its version segment look identical from the far end.

## 0.2.1 (2026-10-15)

**Only mcl-news is heard.** macula verifies who signed a fact, not who may
publish on the topic, so any node in the realm could hand the mind a story to
post about. W2 of the agora walking skeleton (macula-services/mcl-agora#1,
macula-io/macula-portal#59).

- The wire subscriber asks `mcl_om:org_member(<<"mcl-news">>, Publisher)` about
  every fact before it reaches the mind. A node the realm says is not mcl-news
  is counted (`not_the_news_source`) and dropped; a publisher that could not be
  checked is counted (`unchecked`) and dropped too, never trusted. A publication
  without a verified publisher is refused before any lookup.
- Counted, not logged per fact: a stranger publishing in a loop must not become
  this service's log volume.
- `mcl_om` floor `~> 0.41` (`org_member/2` and its cache).

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
  every key failed. The pool is visible in the mind's own report,
  `spartan_mind:report/0`: each provider, its model, how many keys it holds and
  which of them are resting. `/health` still answers `ok` and no more than that,
  which is a limit of mcl_om's document rather than of this service, and is what
  mcl-spartan#4 is about.

- **A single endpoint is a pool of one**, so 0.1.1's deployment is unchanged by
  this release: `MCL_MIND_ENDPOINT`, `MCL_MIND_MODEL` and `MCL_MIND_API_KEY`
  become the provider named `endpoint`, and its key stays optional, which is what
  a local serve or a proxy needs.

- **NVIDIA joins the pool**, on the day a real call answered rather than from a
  catalog listing: `NVIDIA_API_KEYS` and `MCL_NVIDIA_MODEL`, because that catalog
  MOVES (the previous default reached end-of-life days after it was verified, and
  every attempt then failed straight to the next slot with nothing saying so).
  The model that answers 503 when it is busy is a rotation and not a rest: a 5xx
  is the moment rather than the backend, so the turn walks past it and the next
  turn asks it again, which is what "intermittently busy" deserves.

- **`reasoning_effort` is declared per provider.** It is not part of the
  compatible subset every provider accepts, and a provider that rejects an
  unknown field answers 400, which the schedule reads as the moment and fails
  over from: a healthy backend would be skipped every turn in silence.

- **A turn that failed is charged.** Two things the pool made true that the code
  did not yet do. A 200 whose reply this code cannot use (cut off by the token
  limit, a body that is not JSON, no choice in it) has already cost what the
  endpoint reports, and a walk that gave up after three slots spent at three, so
  the failure carries that cost and the mind charges it. Only a REFUSED request
  is free, because a 429 or an unreachable host is one the provider did not
  answer at all. Charging only the turns that worked is a cap a failing pool
  spends straight through.

- **The wire no longer waits for a turn.** `think/1` is a cast. A turn can now
  take as long as every provider's patience added together, and the wire
  subscriber made that turn synchronously, so a slow pool exited the subscriber
  and dropped whatever facts it was holding: a dropped fact and a quiet wire look
  exactly alike, which is the one failure this service cannot see. The mind
  serialises itself instead, and the facts that queue behind a turn are answered
  by the gates in microseconds.

- **The opening clock gates when a fact ARRIVED, not when it was read.** Taking
  the turn off the wire made this true the moment it landed: a turn can outlast
  the clock, so a fact handed over during one was read after the clock had
  already elapsed, opened a paid turn of its own, and so did the next one, with
  the mailbox as the only bound on it. The arrival is stamped where the wire
  hands the fact over, so a fact that was already waiting when the mind got to it
  opens nothing.

- **A body of valid JSON that is not an object no longer takes the mind down.**
  jsx decodes an array into a list and `null` into an atom, and reading `usage`
  out of either raised a badmap inside the mind's own cast: a gateway answering
  `[]` would have killed the mind and taken everything queued behind it with it.
  A turn that costs the turn, and that the schedule fails over from, is what it
  is now, at both levels: a body that is not an object, and a choice whose
  message is not one.

- **A provider that does not make it into the schedule says so.** A name this
  code does not know, or a keyed provider with no key, is dropped by design; it
  is dropped out loud now, once per schedule, which is the difference between a
  pool of three and a pool of one that nothing reports. The report a health check
  reads builds no schedule, so it stays quiet.

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
