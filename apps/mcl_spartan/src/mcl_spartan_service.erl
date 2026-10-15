%%% @doc The mcl_om service contract: what this mind is and may do.
%%%
%%% SIX CALLBACKS, ALL REQUIRED, resolved by name at startup on a live node, so
%%% a service that forgets one dies with `undef' where nobody is watching. The
%%% `-behaviour' attribute is what turns that into a compile error instead.
%%%
%%% A SPEAKER, NOT A SERVER. It offers no procedure, so it advertises no
%%% capability and, like mcl-news, asks the realm for no extra authority. It
%%% subscribes to the wire and it publishes to the square, and both are things
%%% its own verified identity is entitled to do without anybody's grant: the
%%% square carries this org's name, and a fact on it is attributable to whoever
%%% macula verified published it.
-module(mcl_spartan_service).

-behaviour(mcl_om_service).

-export([info/0, start/1, stop/1, health/0, capabilities/0, identity_spec/0]).
-export([subscriptions/0, charter/0, mind_name/0]).

info() ->
    #{name => <<"mcl-spartan">>,
      version => <<"0.2.1">>,
      description => <<"The Spartan Mind: hears the real wire, reasons once about one story, and posts what it made of it to the square">>}.

%% The realm name the topics carry is checked against the realm the pool
%% publishes in before the mind starts: a mind on the wrong realm hears nothing.
start(_Opts) ->
    ok = mcl_spartan_topics:check_realm_name(),
    mcl_spartan_sup:start_link().

stop(_State) -> ok.

%% Green while the mind runs. A quiet wire is not a health failure (nobody may
%% have reported anything), and neither is a dark mesh (facts are missed and the
%% mind keeps what it holds), both deliberately. A mind that has spent its daily
%% budget and is resting IS healthy: it is a state the design insists on, not a
%% fault, and /health stays ok for it.
%%
%% ⚠ AND THAT IS ALL /health SAYS. mcl_om builds the document from this verdict
%% plus its own grant and advertise checks, so a service's own detail (the day's
%% spend, and the provider pool with its key counts and which are resting) is NOT
%% in that JSON, however useful it would be there: it is in spartan_mind:report/0.
%% mcl-spartan#4 is where the mind publishes something a health read can carry,
%% and until it lands the pool is read from the box, not from the endpoint.
health() -> spartan_mind:health().

%% A speaker offers no procedure: it publishes a fact, and the keeper subscribes.
capabilities() -> [].

%% THE AUTHORITY THIS SERVICE ASKS THE REALM FOR, and deliberately nothing more:
%% none. It publishes under its own verified identity and subscribes to topics
%% other orgs own, which is exactly what mcl-news and mcl-sentinel do with an
%% empty resource list. Asking for a grant over the square would be asking to be
%% trusted not to speak, and this service exists to speak.
identity_spec() ->
    #{scope => <<"mcl-spartan">>,
      actions => [],
      resources => [],
      ttl_days => 30}.

%% @doc The wire, wired by mcl_om:boot/1 into a supervised subscriber before
%% start/1 runs. The handler decides whether the fact is worth a turn; the mind
%% decides what the turn says.
-spec subscriptions() -> [{binary(), module(), term()}].
subscriptions() ->
    [{Topic, on_news_item_reported_maybe_open_a_turn, #{}}
     || Topic <- mcl_spartan_topics:news_wire_topics()].

%% ==========================================================================
%% The charter, and who is speaking
%% ==========================================================================

%% @doc The name this mind speaks under: what a reader sees as the author of a
%% post, and a deploy fact rather than a model's invention. Config first, since
%% two minds on one box differ by exactly this.
-spec mind_name() -> binary().
mind_name() ->
    configured(mind_name, <<"spartan">>).

%% @doc The mind's charter: what it reads and what it is for. W1b's charter is
%% one config entry, which is what the plan asks for, and the roster in W5 is
%% where several of them live.
%%
%% It is DATA, and it is prompt material, not code: a mind is what it was told
%% to be, and changing this changes the mind without touching the loop.
-spec charter() -> binary().
charter() ->
    configured(charter, default_charter()).

configured(Key, Default) ->
    case application:get_env(mcl_spartan, Key, Default) of
        Value when is_binary(Value), Value =/= <<>> -> Value;
        Value when is_list(Value), Value =/= "" -> unicode:characters_to_binary(Value);
        _ -> Default
    end.

%% What a news desk is FOR, in the plainest words a model can act on. Short on
%% purpose: length is instruction-following budget spent on our own prose.
default_charter() ->
    <<"You are a news desk on the macula mesh. You are handed one item the "
      "wire has just reported. Say what you make of it, in one short paragraph, "
      "for a reader who has the article in front of them. Be specific and be "
      "plain: no greeting, no sign-off, no restating the headline. If the item "
      "gives you nothing worth saying, say nothing at all.">>.
