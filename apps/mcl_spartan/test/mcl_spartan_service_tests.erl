%% @doc The service contract, asserted locally.
%%
%% mcl_om resolves its six callbacks BY NAME at startup, on a live node, so a
%% service that forgets one dies with `undef' where nobody is watching. The
%% primary defence is the `-behaviour(mcl_om_service)' attribute, which turns a
%% missing callback into a compile error under warnings_as_errors.
%%
%% What this suite adds is everything the compiler cannot see: that the attribute
%% has not been quietly dropped, that the values inside those callbacks are the
%% shapes mcl_om will destructure, and that the two topic paths this mind
%% depends on are the ones the services at the other ends actually use.
-module(mcl_spartan_service_tests).

-include_lib("eunit/include/eunit.hrl").

-define(APP, mcl_spartan).
-define(SERVICE, mcl_spartan_service).

%% Belt and braces with the behaviour attribute, and it survives the attribute
%% being removed. If mcl_om ever adds a SEVENTH required callback this test
%% keeps passing and the deploy still breaks, which is the honest limit of a
%% local assertion about a remote contract.
exports_every_required_callback_test() ->
    _ = code:ensure_loaded(?SERVICE),
    Required = [{info, 0}, {start, 1}, {stop, 1},
                {health, 0}, {capabilities, 0}, {identity_spec, 0}],
    Missing = [F || {N, A} = F <- Required,
                    not erlang:function_exported(?SERVICE, N, A)],
    ?assertEqual([], Missing).

info_carries_the_three_keys_test() ->
    #{name := Name, version := Vsn, description := Desc} = ?SERVICE:info(),
    ?assert(is_binary(Name)),
    ?assert(is_binary(Vsn)),
    ?assert(is_binary(Desc)),
    ?assertEqual(<<"mcl-spartan">>, Name).

%% THE TWO NAMES MUST AGREE. The OTP application is snake_case because it is an
%% Erlang atom; the repository, the image and the name on the mesh are kebab.
%% They describe one service, so a mismatch is caught on the first eunit run
%% rather than by a puzzled reader months later.
mesh_name_matches_the_application_test() ->
    #{name := Wire} = ?SERVICE:info(),
    Snake = atom_to_binary(?APP, utf8),
    ?assertEqual(binary:replace(Snake, <<"_">>, <<"-">>, [global]), Wire).

%% The version in info/0 is what a peer reads off the mesh, so it disagreeing
%% with the application it describes is a lie nothing else would catch.
info_version_matches_the_application_test() ->
    _ = application:load(?APP),
    {ok, Vsn} = application:get_key(?APP, vsn),
    #{version := Reported} = ?SERVICE:info(),
    ?assertEqual(list_to_binary(Vsn), Reported).

%% /health answers for the MIND, not for the process table. A mind that is not
%% running is a degraded service, and this asserts whichever of the two is true
%% rather than assuming an order the suite does not control.
health_reports_whether_the_mind_runs_test() ->
    case whereis(spartan_mind) of
        undefined -> ?assertMatch({degraded, {mind_not_running, _}}, ?SERVICE:health());
        _Pid      -> ?assertEqual(ok, ?SERVICE:health())
    end.

%% A speaker offers no procedure: it publishes to the square, and the keeper
%% subscribes. An empty list is the honest answer, and adding a capability
%% breaks this test so someone writes down what this service can now be called
%% for.
announces_no_capability_test() ->
    ?assertEqual([], ?SERVICE:capabilities()).

identity_spec_has_the_shape_mcl_om_expects_test() ->
    #{scope := Scope, actions := Actions,
      resources := Resources, ttl_days := Ttl} = ?SERVICE:identity_spec(),
    ?assert(is_binary(Scope)),
    ?assert(is_list(Actions)),
    ?assert(is_list(Resources)),
    ?assert(is_integer(Ttl) andalso Ttl > 0).

%% A resource this service is not authorised for is a publish the realm would
%% refuse once UCAN delegation lands. THIS MIND ASKS FOR NOTHING because it
%% needs nothing: the square carries its own org's name, so publishing there is
%% what its identity is for, and asking for a grant over the wire would be
%% asking to be trusted not to speak.
authority_matches_what_is_announced_test() ->
    #{actions := Actions, resources := Resources} = ?SERVICE:identity_spec(),
    ?assertEqual([], ?SERVICE:capabilities()),
    ?assertEqual([], Actions),
    ?assertEqual([], Resources).

%% One child, the mind, which owns the clock and the ledger.
supervises_the_mind_test() ->
    {ok, {_Flags, Children}} = mcl_spartan_sup:init([]),
    ?assertEqual([spartan_mind], [maps:get(id, C) || C <- Children]).

%% The mind's charter is prompt material and its default lives in the service,
%% so a deploy that wants the default does not have to paste it.
charter_is_never_empty_test() ->
    ?assert(is_binary(?SERVICE:charter())),
    ?assert(byte_size(?SERVICE:charter()) > 0),
    ?assert(is_binary(?SERVICE:mind_name())).

%%==============================================================================
%% The two topics, which are the contract with the services at either end
%%==============================================================================

%% ⚠ THIS IS THE ONE ASSERTION THAT CROSSES A REPOSITORY BOUNDARY, and it is
%% here because both ends would otherwise look healthy while the wire carried
%% nothing. mcl-news publishes on exactly the first topic, and mcl-agora
%% subscribes to exactly the second. A drift in either is a mind that hears
%% nothing or a keeper that records nothing, and neither shows up as an error
%% anywhere: both would read as a quiet day.
the_two_topic_paths_are_the_ones_the_other_services_use_test() ->
    Realm = <<"io.macula">>,
    ?assertEqual(<<"io.macula/mcl-news/news/wire/news_item_reported_v1">>,
                 mcl_spartan_topics:news_wire_topic(Realm)),
    ?assertEqual(<<"io.macula/mcl-spartan/agora/wire/agora_post_published_v1">>,
                 mcl_spartan_topics:square_topic(Realm)),
    ?assertEqual([mcl_spartan_topics:news_wire_topic(Realm)],
                 mcl_spartan_topics:news_wire_topics()),
    ?assertEqual([on_news_item_reported_maybe_open_a_turn],
                 [Mod || {_Topic, Mod, _Args} <- ?SERVICE:subscriptions()]).

%% The topics carry the realm NAME, so a mind on the wrong realm is caught at
%% boot rather than by a wire that never speaks.
realm_name_must_match_the_realm_tag_test() ->
    Name = <<"io.macula">>,
    Tag = crypto:hash(sha256, Name),
    ?assertEqual(ok, mcl_spartan_topics:check_realm_name(Name, Tag)),
    ?assertError({mcl_spartan_realm_name_mismatch, _, _},
                 mcl_spartan_topics:check_realm_name(Name, crypto:hash(sha256, <<"other">>))).

%% The release takes the realm name from the environment: the topics carry it,
%% and start/1 checks it against the realm tag.
release_config_names_the_realm_test() ->
    {ok, Text} = file:read_file(alongside("config/sys.config.src")),
    Named = re:replace(Text, <<"\"\\$\\{([A-Z_]+)\\}\"">>, <<"\"\\1\"">>, [global]),
    Substituted = re:replace(Named, <<"\\$\\{[A-Z_]+\\}">>, <<"0">>, [global, {return, list}]),
    {ok, Tokens, _End} = erl_scan:string(Substituted),
    {ok, Config} = erl_parse:parse_term(Tokens),
    ?assertEqual("MCL_REALM_NAME", proplists:get_value(realm_name, proplists:get_value(?APP, Config, []))),
    %% The key is NOT in this file on purpose: a box secret stays on the box.
    ?assertEqual(undefined, proplists:get_value(mind_api_key, proplists:get_value(?APP, Config, []))).

%%==============================================================================
%% The runtime is pinned in two places, and neither is the one you are running
%%==============================================================================

%% ⚠ TO THE PATCH, AND NOTHING FLOATS. The image tags name a date rather than a
%% release, so the builder and lint each assert the release in a check step;
%% this compares those, the .tool-versions pin, and this VM.
the_runtime_agrees_between_the_image_the_ci_and_this_vm_test() ->
    Check = "\\{<<\"([0-9]+\\.[0-9]+\\.[0-9]+)\">>, true\\} -> halt\\(0\\);",
    Image = pinned("Containerfile", Check),
    CiCheck = pinned(".github/workflows/lint.yml", Check),
    Tools = pinned(".tool-versions", "^erlang ([0-9]+\\.[0-9]+\\.[0-9]+)$"),
    ?assertEqual([Image], lists:usort([Image, CiCheck, Tools, running_otp()])).

%% Build, CI and runtime are the team pair, named by dated tag AND digest, so a
%% re-pushed tag cannot change what builds or what runs.
images_are_the_digest_pinned_team_pair_test() ->
    Digest = ":[0-9]{8}-[0-9]{4}@sha256:[0-9a-f]{64}",
    ?assertMatch(<<_/binary>>,
                 pinned("Containerfile",
                        "^FROM (ghcr\\.io/macula-io/macula-ci-otp)" ++ Digest ++ " AS builder$")),
    ?assertMatch(<<_/binary>>,
                 pinned("Containerfile",
                        "^FROM (ghcr\\.io/macula-io/macula-pq-runtime)" ++ Digest ++ "$")),
    ?assertMatch(<<_/binary>>,
                 pinned(".github/workflows/lint.yml",
                        "^\\s+image: (ghcr\\.io/macula-io/macula-ci-otp)" ++ Digest ++ "$")).

%% The image says which commit it was built from: build-push passes the sha, the
%% runtime stage labels the image with it, so a digest a fleet pins can be
%% traced back to its commit.
the_image_carries_its_revision_test() ->
    ?assertEqual(<<"REVISION">>, pinned("Containerfile", "^ARG (REVISION)=unknown$")),
    ?assertEqual(<<"${REVISION}">>,
                 pinned("Containerfile",
                        "^LABEL org\\.opencontainers\\.image\\.revision=\"([^\"]+)\"$")),
    ?assertEqual(<<"${{ github.sha }}">>,
                 pinned(".github/workflows/build-push.yml", "^\\s+REVISION=(.+)$")).

%% The full release, 28.4.3 and not 28: `otp_release' names only the major.
running_otp() ->
    {ok, Version} = file:read_file(filename:join([code:root_dir(), "releases",
                                                  erlang:system_info(otp_release),
                                                  "OTP_VERSION"])),
    string:trim(Version).

pinned(Relative, Pattern) ->
    {ok, Text} = file:read_file(alongside(Relative)),
    {match, [Version]} = re:run(Text, Pattern,
                                [multiline, {capture, all_but_first, binary}]),
    Version.

%% Relative to the beam rather than the working directory, because eunit runs
%% from wherever the developer happens to be standing.
alongside(Name) -> climb(filename:dirname(code:which(?MODULE)), Name, 8).

climb(_Dir, Name, 0) -> Name;
climb(Dir, Name, Left) ->
    Candidate = filename:join(Dir, Name),
    found(filelib:is_regular(Candidate), Candidate, Dir, Name, Left).

found(true, Candidate, _Dir, _Name, _Left) -> Candidate;
found(false, _Candidate, Dir, Name, Left) ->
    climb(filename:dirname(Dir), Name, Left - 1).
