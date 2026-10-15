%% @doc The card: what the mind was reacting to, copied from the fact.
%%
%% This is the module a model can never reach, so what it asserts is that what
%% arrives at the keeper is what mcl-news sent and not something reconstructed
%% on the way through.
-module(agora_stimulus_tests).

-include_lib("eunit/include/eunit.hrl").

the_card_is_the_fact_copied_test() ->
    {ok, Card} = agora_stimulus:of_fact(fact()),
    %% Values travel tagged as CBOR text, exactly as the sensor sends them.
    ?assertEqual({text, <<"france24">>}, maps:get(source, Card)),
    ?assertEqual({text, <<"A headline">>}, maps:get(title, Card)),
    ?assertEqual([{text, <<"sport">>}, {text, <<"eu">>}], maps:get(topics, Card)),
    %% Times stay integers: a millisecond turned into text is a number every
    %% consumer would have to parse back.
    ?assertEqual(1785215553616, maps:get(published_at, Card)),
    ?assertEqual(1792043408599, maps:get(fetched_at, Card)).

%% A post nobody can group is a post nobody can read in context, so an item
%% with no id is refused rather than posted with a blank thread.
a_fact_without_an_id_is_refused_test() ->
    ?assertEqual({error, missing_item_id},
                 agora_stimulus:of_fact(maps:remove(item_id, fact()))),
    ?assertEqual({error, missing_item_id}, agora_stimulus:of_fact(#{})),
    ?assertEqual({error, missing_item_id}, agora_stimulus:of_fact(not_a_map)).

%% Absent is absent. "The sensor did not report this" is a different thing from
%% "the sensor reported it empty", and a card that blanked them would erase the
%% difference.
absent_fields_are_absent_test() ->
    {ok, Card} = agora_stimulus:of_fact(maps:remove(image_url, fact())),
    ?assertNot(maps:is_key(image_url, Card)),
    ?assert(maps:is_key(url, Card)).

%% The same fact reaches this module in every spelling the wire can produce a
%% key in: an atom, a binary, or the tagged form. All three are one card.
every_key_spelling_gives_the_same_card_test() ->
    {ok, Text} = agora_stimulus:of_fact(fact()),
    {ok, Binary} = agora_stimulus:of_fact(binary_keys()),
    {ok, Tagged} = agora_stimulus:of_fact(tagged_keys()),
    ?assertEqual(Text, Binary),
    ?assertEqual(Text, Tagged).

%% item_id reads through the same spellings, so the mind can thread on a fact
%% whichever way it arrived.
item_id_reads_through_every_spelling_test() ->
    ?assertEqual(<<"item-1">>, agora_stimulus:item_id(fact())),
    ?assertEqual(<<"item-1">>, agora_stimulus:item_id(binary_keys())),
    ?assertEqual(<<"item-1">>, agora_stimulus:item_id(tagged_keys())),
    ?assertEqual(undefined, agora_stimulus:item_id(#{})).

%% The list is the keeper's own set, `source' included, because the keeper's
%% code is what decides what a recorded card holds. This test is what stops a
%% field a reader wants being quietly dropped from the card instead.
the_list_carries_the_fields_a_reader_wants_test() ->
    Fields = agora_stimulus:fields(),
    [?assert(lists:member(F, Fields))
     || F <- [item_id, source, title, summary, body, url, image_url, lang,
              topics, published_at, topic_class, emoji, reporting_country,
              subject_country, source_type, fetched_at]].

%%====================================================================
%% Helpers
%%====================================================================

fact() ->
    #{item_id => {text, <<"item-1">>},
      source => {text, <<"france24">>},
      title => {text, <<"A headline">>},
      body => {text, <<"A headline">>},
      url => {text, <<"https://example.test/a">>},
      image_url => {text, <<"https://example.test/a.jpg">>},
      lang => {text, <<"en">>},
      topics => [{text, <<"sport">>}, {text, <<"eu">>}],
      topic_class => {text, <<"sport">>},
      published_at => 1785215553616,
      fetched_at => 1792043408599,
      %% Not on the list, and not recorded: the keeper's field list is the
      %% contract, so a field it does not know does not travel.
      something_else => {text, <<"ignored">>}}.

binary_keys() ->
    maps:from_list([{atom_to_binary(K, utf8), V} || {K, V} <- maps:to_list(fact())]).

tagged_keys() ->
    maps:from_list([{{text, atom_to_binary(K, utf8)}, V} || {K, V} <- maps:to_list(fact())]).
