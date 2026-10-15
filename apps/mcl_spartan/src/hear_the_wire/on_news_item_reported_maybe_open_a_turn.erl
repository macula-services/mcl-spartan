%%% @doc Hears the wire, and offers what it heard to the mind.
%%%
%%% THE ONE PLACE A FACT FROM OUTSIDE BECOMES SOMETHING THIS SERVICE DOES, and
%%% therefore the one place what counts as a story is decided. It decides
%%% almost nothing: who said it, and whether the payload is a map at all. The mind's own gates
%%% (the clock, the daily cap, one turn per item) live with the mind, because
%%% they are about the mind's spend and not about this topic's shape.
%%%
%%% ⚠ AND IT DOES NOT WAIT FOR AN ANSWER. A turn is now a walk over a pool of
%%% providers and takes as long as they are patient, and this is a wire
%%% subscriber: one that blocks for that long is restarted with the facts it was
%%% holding, and a dropped fact and a quiet wire look exactly alike. So the fact
%%% is handed over and this returns. What became of it is in the mind's own
%%% report, which is where that answer lives now.
%%%
%%% ONLY AN ADMITTED mcl-news NODE IS HEARD. macula verifies who signed a fact,
%%% not who may publish on the topic, so without the membership check any node
%%% in the realm could hand the mind a story to post about. A fact from a node
%%% the realm says is not mcl-news, or from one this could not check, is
%%% counted and dropped; the cost of that is a turn not taken, never a turn
%%% taken on a stranger's word. Counted, not logged per fact: a stranger
%%% publishing in a loop must not become this service's log volume.
%%%
%%% IT DOES NOT DECODE THE ITEM. Nowhere here reads a field out of the payload,
%%% so a new field on mcl-news's fact arrives at the mind without a change in
%%% this module.
-module(on_news_item_reported_maybe_open_a_turn).

-behaviour(macula_subscriber).

-export([init/1, handle_event/4]).

%% What the wire delivered since boot: facts handed to the mind, payloads that
%% were not attributable facts at all, facts from a node that is not mcl-news,
%% and facts whose publisher could not be checked. The other half of "is this working", what the
%% mind then did with them, is in the mind's own report.
init(_Args) ->
    {ok, #{offered => 0, refused => 0, not_the_news_source => 0, unchecked => 0}}.

-spec handle_event(binary(), term(), map(), map()) -> {noreply, map()}.
handle_event(_Topic, Payload, #{publisher := Publisher, publisher_verified := true}, State)
  when is_map(Payload), is_binary(Publisher), byte_size(Publisher) =:= 32 ->
    {noreply, heard(mcl_om:org_member(mcl_spartan_topics:news_source(), Publisher), Payload, State)};
handle_event(_Topic, _UnattributedOrNotAMap, _Meta, State) ->
    {noreply, counted(refused, State)}.

heard({ok, _ExpiresAt}, Payload, State) ->
    ok = spartan_mind:think(Payload),
    counted(offered, State);
heard({error, {not_a_member, _}}, _Payload, State) ->
    counted(not_the_news_source, State);
heard({error, {unavailable, _}}, _Payload, State) ->
    counted(unchecked, State).

counted(Key, State) ->
    maps:update_with(Key, fun(N) -> N + 1 end, 1, State).
