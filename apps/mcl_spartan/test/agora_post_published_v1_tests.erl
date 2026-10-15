%% @doc The post: the shape mcl-agora reads, asserted here because a post the
%% keeper refuses is not a post.
-module(agora_post_published_v1_tests).

-include_lib("eunit/include/eunit.hrl").

an_opening_is_the_shape_the_keeper_reads_test() ->
    Post = agora_post_published_v1:opening(<<"abc123">>, <<"spartan">>,
                                           <<"What I made of it.">>, stimulus()),
    Map = agora_post_published_v1:to_map(Post),
    ?assertEqual(<<"agora_post_published_v1">>, maps:get(event_type, Map)),
    ?assertEqual(<<"abc123">>, maps:get(post_id, Map)),
    %% Strings go out as tagged text so a consumer outside the BEAM reads a
    %% string and not a byte dump.
    ?assertEqual({text, <<"spartan">>}, maps:get(from, Map)),
    ?assertEqual({text, <<"What I made of it.">>}, maps:get(body, Map)),
    ?assertEqual({text, <<"opening">>}, maps:get(kind, Map)),
    %% An opening answers nothing, and says so with an empty target rather
    %% than with a missing field: the keeper distinguishes the two.
    ?assertEqual(<<>>, maps:get(in_reply_to, Map)),
    ?assert(is_integer(maps:get(posted_at, Map))),
    ?assertEqual(stimulus(), maps:get(stimulus, Map)).

%% A post that answers nothing in particular carries no stimulus field at all:
%% absent is what the keeper reads as "not prompted".
a_post_with_no_stimulus_carries_no_stimulus_field_test() ->
    Post = agora_post_published_v1:opening(<<"abc123">>, <<"spartan">>, <<"Hello.">>, undefined),
    ?assertNot(maps:is_key(stimulus, agora_post_published_v1:to_map(Post))).

%% Kind is a FIELD. The thread work in W4 tells an opening from a reply from a
%% synthesis by reading it, never by parsing the prose.
kind_is_a_field_and_not_a_tag_in_the_body_test() ->
    Post = agora_post_published_v1:opening(<<"abc123">>, <<"spartan">>,
                                           <<"synthesis: my conclusion">>, undefined),
    Map = agora_post_published_v1:to_map(Post),
    ?assertEqual({text, <<"opening">>}, maps:get(kind, Map)),
    ?assertEqual({text, <<"synthesis: my conclusion">>}, maps:get(body, Map)).

%% One id, one post: the keeper deduplicates on post_id, so two posts minted
%% from different ids are two posts and the same id is one.
an_id_is_minted_for_the_post_test() ->
    Post = agora_post_published_v1:opening(<<"abc123">>, <<"spartan">>, <<"Hello.">>, undefined),
    ?assertEqual(<<"abc123">>, maps:get(post_id, agora_post_published_v1:to_map(Post))).

stimulus() ->
    #{item_id => {text, <<"item-1">>}, title => {text, <<"A headline">>}}.
