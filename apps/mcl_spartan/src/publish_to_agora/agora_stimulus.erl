%%% @doc What the mind was reacting to, carried with what it said.
%%%
%%% ATTACH, NEVER ASK. The mind does not author this and is never prompted for
%%% it: this module COPIES the fact the mind was handed. Every field is
%%% therefore provenance rather than a claim, and cannot be hallucinated, which
%%% is why it is a module of its own rather than three lines in the mind. A
%%% model asked to name its own source invents one; a model that never touches
%%% the attachment cannot.
%%%
%%% item_id IS THE THREAD. Every post carrying the same item_id is the same
%%% conversation: one post per item in W1, replies and a synthesis later. That
%%% is why a fact without one is refused rather than posted, because a post
%%% nobody can group is a post nobody can read in context.
%%%
%%% THE FIELD LIST IS THE KEEPER'S, not ours. mcl-agora records a fixed set of
%%% mcl-news's reported fields and drops anything else, so sending more would
%%% change nothing there. The value of a card is that it says what mcl-news
%%% said, in the shape mcl-news said it, which is what `tagged/1' below
%%% restores.
-module(agora_stimulus).

-export([of_fact/1, fields/0, item_id/1]).

%% @doc The mcl-news fields a card may carry.
%%
%% This list and the keeper's own (`agora_post_stimulus`, which is what decides
%% what a recorded card holds) are the same set, `source' included. The keeper's
%% README lists one field fewer: it is the code that decides, so `source' is
%% recorded, and that README is owed a line rather than this module a change.
-spec fields() -> [atom()].
fields() ->
    [item_id, source, title, summary, body, url, image_url, lang, topics,
     published_at, topic_class, emoji, reporting_country, reporting_country_name,
     subject_country, subject_country_name, source_type, fetched_at].

%% @doc The card for one fact, or a refusal when there is nothing to thread on.
%%
%% Fields the wire did not report are OMITTED rather than blanked: the keeper
%% records what the sensor said, and "the sensor did not report this" is a
%% different thing from "the sensor reported it empty".
-spec of_fact(map()) -> {ok, map()} | {error, missing_item_id}.
of_fact(Fact) when is_map(Fact) ->
    kept(mcl_om_wire:field(item_id, Fact), Fact);
of_fact(_NotAFact) ->
    {error, missing_item_id}.

kept(undefined, _Fact) -> {error, missing_item_id};
kept(_ItemId, Fact)    -> {ok, maps:from_list(kept_fields(Fact))}.

kept_fields(Fact) ->
    [{K, V} || K <- fields(), V <- [tagged(mcl_om_wire:field(K, Fact))], V =/= undefined].

%% Strings go out tagged as CBOR text, exactly as mcl-news sends them, so a
%% consumer outside the BEAM reads a string and not a byte dump. The read above
%% unwraps the wire form to get here, and this puts the canonical one back.
tagged(Text) when is_binary(Text) -> {text, Text};
tagged(List) when is_list(List)   -> [tagged(Element) || Element <- List];
tagged(Other)                     -> Other.

%% @doc The thread id, from a card or from a raw fact.
-spec item_id(map()) -> binary() | undefined.
item_id(Map) -> mcl_om_wire:field(item_id, Map).
