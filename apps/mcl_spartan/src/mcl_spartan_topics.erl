%%% @doc Where the wire is, and where the square is.
%%%
%%% TWO TOPICS, AND THEY ARE NOT THE SAME KIND OF THING. The wire is mcl-news's
%%% own fact and this mind only ever subscribes to it. The square carries this
%%% org's name because the SPEAKERS own it, which is what lets the keeper
%%% subscribe to it without being able to put words in it, and lets a speaker
%%% here publish to it without asking the keeper for anything.
%%%
%%% Both are canonical macula app facts, realm/org/app/domain/name_vN, and the
%%% realm segment is the realm NAME rather than its tag. That name is checked
%%% at start against the realm the pool actually publishes in, because a mind
%%% listening on a topic nobody publishes to looks exactly like a quiet wire,
%%% which is the hardest failure here to see from the outside.
-module(mcl_spartan_topics).

-export([realm_name/0, check_realm_name/0, check_realm_name/2]).
-export([news_wire_topics/0, news_wire_topic/1]).
-export([square_topics/0, square_topic/1]).

-define(APP, mcl_spartan).
-define(SOURCE, <<"mcl-news">>).
-define(SPEAKERS, <<"mcl-spartan">>).

%% @doc The news facts a mind listens to. One shape on one topic today; the
%% list is the seam a second source arrives through.
-spec news_wire_topics() -> [binary()].
news_wire_topics() ->
    [news_wire_topic(realm_name())].

-spec news_wire_topic(binary()) -> binary().
news_wire_topic(RealmName) ->
    macula_topic:app_fact(RealmName, ?SOURCE, <<"news">>, <<"wire">>,
                          <<"news_item_reported">>, 1).

%% @doc Every topic a post on the square is published to. The keeper subscribes
%% to exactly this, and a mismatch between the two is a post nobody records.
-spec square_topics() -> [binary()].
square_topics() ->
    [square_topic(realm_name())].

-spec square_topic(binary()) -> binary().
square_topic(RealmName) ->
    macula_topic:app_fact(RealmName, ?SPEAKERS, <<"agora">>, <<"wire">>,
                          <<"agora_post_published">>, 1).

%% @doc The realm NAME the topics carry, from the app env.
-spec realm_name() -> binary().
realm_name() ->
    named(application:get_env(?APP, realm_name, undefined)).

named(Name) when is_list(Name), Name =/= "" -> unicode:characters_to_binary(Name);
named(Name) when is_binary(Name), Name =/= <<>> -> Name;
named(_Unset) -> error({mcl_spartan_realm_name_unset, realm_name}).

%% @doc Refuse to start when the realm name is not the realm the pool publishes
%% in: the facts would go where nobody subscribed, and the mind would look
%% exactly like a quiet wire.
-spec check_realm_name() -> ok.
check_realm_name() ->
    configured(realm_name(), mcl_om:realm()).

configured(Name, {ok, Tag}) -> check_realm_name(Name, Tag);
configured(Name, Other)     -> error({mcl_spartan_realm_unset, Name, Other}).

%% The topics are built here too, not just hashed: a name that hashes right but
%% is not a valid topic segment would pass the hash and then fail every fact, at
%% publish time and once per post rather than once at boot.
-spec check_realm_name(binary(), binary()) -> ok.
check_realm_name(Name, Tag) ->
    _ = news_wire_topic(Name),
    _ = square_topic(Name),
    matched(crypto:hash(sha256, Name) =:= Tag, Name, Tag).

matched(true, _Name, _Tag) -> ok;
matched(false, Name, Tag)  -> error({mcl_spartan_realm_name_mismatch, Name, Tag}).
