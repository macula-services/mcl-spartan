%% @doc Who the mind hears the news from.
%%
%% macula verifies who signed a fact, not who may publish on the topic, so a
%% stranger in the realm could otherwise hand the mind a story to post about.
%% Only a fact an admitted mcl-news node signed reaches the mind; everything
%% else is counted and dropped, and an unchecked publisher is never trusted.
-module(hear_the_wire_tests).

-include_lib("eunit/include/eunit.hrl").

-define(LISTENER, on_news_item_reported_maybe_open_a_turn).
-define(TOPIC, <<"io.macula/mcl-news/news/wire/news_item_reported_v1">>).
-define(SENSOR, <<5:256>>).

wire_test_() ->
    {foreach,
     fun() ->
         meck:new(spartan_mind, [no_link, non_strict]),
         meck:expect(spartan_mind, think, 1, ok),
         meck:new(mcl_om, [no_link, non_strict])
     end,
     fun(_) -> meck:unload(mcl_om), meck:unload(spartan_mind) end,
     [fun a_fact_from_the_news_source_reaches_the_mind/0,
      fun a_fact_from_a_node_that_is_not_the_news_source_does_not/0,
      fun a_fact_whose_publisher_could_not_be_checked_does_not/0,
      fun an_unverified_publication_is_not_even_checked/0,
      fun a_publication_without_a_publisher_is_refused/0,
      fun a_payload_that_is_not_a_fact_is_refused/0]}.

a_fact_from_the_news_source_reaches_the_mind() ->
    meck:expect(mcl_om, org_member, 2, {ok, 1}),
    State = heard(fact(), meta()),
    ?assertEqual(1, maps:get(offered, State)),
    ?assert(meck:called(spartan_mind, think, [fact()])),
    ?assert(meck:called(mcl_om, org_member, [<<"mcl-news">>, ?SENSOR])).

a_fact_from_a_node_that_is_not_the_news_source_does_not() ->
    meck:expect(mcl_om, org_member, 2, {error, {not_a_member, delegation_mismatch}}),
    State = heard(fact(), meta()),
    ?assertEqual(1, maps:get(not_the_news_source, State)),
    ?assertEqual(0, maps:get(offered, State)),
    ?assertNot(meck:called(spartan_mind, think, '_')).

a_fact_whose_publisher_could_not_be_checked_does_not() ->
    meck:expect(mcl_om, org_member, 2, {error, {unavailable, timeout}}),
    State = heard(fact(), meta()),
    ?assertEqual(1, maps:get(unchecked, State)),
    ?assertNot(meck:called(spartan_mind, think, '_')).

an_unverified_publication_is_not_even_checked() ->
    meck:expect(mcl_om, org_member, 2, {ok, 1}),
    State = heard(fact(), #{publisher => ?SENSOR, publisher_verified => false}),
    ?assertEqual(1, maps:get(refused, State)),
    ?assertNot(meck:called(mcl_om, org_member, '_')),
    ?assertNot(meck:called(spartan_mind, think, '_')).

a_publication_without_a_publisher_is_refused() ->
    meck:expect(mcl_om, org_member, 2, {ok, 1}),
    State = heard(fact(), #{}),
    ?assertEqual(1, maps:get(refused, State)),
    ?assertNot(meck:called(spartan_mind, think, '_')).

a_payload_that_is_not_a_fact_is_refused() ->
    meck:expect(mcl_om, org_member, 2, {ok, 1}),
    State = heard(<<"not a fact">>, meta()),
    ?assertEqual(1, maps:get(refused, State)),
    ?assertNot(meck:called(spartan_mind, think, '_')).

%%------------------------------------------------------------------------------

heard(Payload, Meta) ->
    {ok, Fresh} = ?LISTENER:init(#{}),
    {noreply, State} = ?LISTENER:handle_event(?TOPIC, Payload, Meta, Fresh),
    State.

meta() -> #{publisher => ?SENSOR, publisher_verified => true}.

fact() -> #{item_id => {text, <<"i1">>}, title => {text, <<"A real headline">>}}.
