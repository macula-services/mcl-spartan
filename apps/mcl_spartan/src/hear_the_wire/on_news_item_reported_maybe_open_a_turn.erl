%%% @doc Hears the wire, and offers what it heard to the mind.
%%%
%%% THE ONE PLACE A FACT FROM OUTSIDE BECOMES SOMETHING THIS SERVICE DOES, and
%%% therefore the one place what counts as a story is decided. It decides
%%% almost nothing: whether the payload is a map at all, and what the mind said
%%% back. The mind's own gates (the clock, the daily cap, one turn per item)
%%% live with the mind, because they are about the mind's spend and not about
%%% this topic's shape.
%%%
%%% IT DOES NOT DECODE THE ITEM. Nowhere here reads a field out of the payload,
%%% so a new field on mcl-news's fact arrives at the mind without a change in
%%% this module. What it does read is the mind's ANSWER, which is how a
%%% subscriber can say what it is doing without re-deriving it.
-module(on_news_item_reported_maybe_open_a_turn).

-behaviour(macula_subscriber).

-export([init/1, handle_event/4]).

%% What the listener has heard since boot. The caller that asks "is the mind
%% working" has /health and the mind's own report; this is the other half of
%% that answer, the part that says the wire was reaching us at all.
init(_Args) ->
    {ok, #{offered => 0, refused => 0}}.

-spec handle_event(binary(), term(), map(), map()) -> {noreply, map()}.
handle_event(_Topic, Payload, _Meta, State) when is_map(Payload) ->
    {noreply, heard(spartan_mind:think(Payload), State)};
handle_event(Topic, Payload, _Meta, State) ->
    logger:warning("[spartan] not a fact on ~s: ~p", [Topic, Payload]),
    {noreply, counted(refused, State)}.

heard({refused, _Why}, State) ->
    counted(refused, State);
heard({duplicate, _Why}, State) ->
    counted(refused, State);
heard(_Outcome, State) ->
    counted(offered, State).

counted(Key, State) ->
    maps:update_with(Key, fun(N) -> N + 1 end, 1, State).
