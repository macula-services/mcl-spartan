%%% @doc Hears the wire, and offers what it heard to the mind.
%%%
%%% THE ONE PLACE A FACT FROM OUTSIDE BECOMES SOMETHING THIS SERVICE DOES, and
%%% therefore the one place what counts as a story is decided. It decides
%%% almost nothing: whether the payload is a map at all. The mind's own gates
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
%%% IT DOES NOT DECODE THE ITEM. Nowhere here reads a field out of the payload,
%%% so a new field on mcl-news's fact arrives at the mind without a change in
%%% this module.
-module(on_news_item_reported_maybe_open_a_turn).

-behaviour(macula_subscriber).

-export([init/1, handle_event/4]).

%% What the wire delivered since boot: facts handed to the mind, and payloads
%% that were not facts at all. The other half of "is this working", what the
%% mind then did with them, is in the mind's own report.
init(_Args) ->
    {ok, #{offered => 0, refused => 0}}.

-spec handle_event(binary(), term(), map(), map()) -> {noreply, map()}.
handle_event(_Topic, Payload, _Meta, State) when is_map(Payload) ->
    ok = spartan_mind:think(Payload),
    {noreply, counted(offered, State)};
handle_event(Topic, Payload, _Meta, State) ->
    logger:warning("[spartan] not a fact on ~s: ~p", [Topic, Payload]),
    {noreply, counted(refused, State)}.

counted(Key, State) ->
    maps:update_with(Key, fun(N) -> N + 1 end, 1, State).
