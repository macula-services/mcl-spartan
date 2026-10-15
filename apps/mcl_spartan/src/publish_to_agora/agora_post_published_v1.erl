%%% @doc The post a mind publishes to the square.
%%%
%%% ONE SHAPE, FIXED HERE, BECAUSE THE KEEPER READS IT. mcl-agora subscribes to
%%% this topic and records these fields by name, so this module and that
%%% README have to agree or the post is dropped as unusable. A post the keeper
%%% refuses is not a post, which is why the shape is built in one place and
%%% tested rather than assembled at the call site.
%%%
%%% `kind' IS A FIELD, NEVER A TAG PARSED BACK OUT OF PROSE. In W1 every post
%%% is an opening; replies and a synthesis arrive in W4 and are told apart by
%%% this field, not by anything a model wrote.
%%%
%%% `in_reply_to' IS EMPTY FOR AN OPENING, not absent, because the keeper
%%% distinguishes "answers nothing" from "answers something I did not say".
-module(agora_post_published_v1).

-export([opening/4, to_map/1, event_type/0]).

-record(post, {post_id     :: binary(),
               from        :: binary(),
               body        :: binary(),
               posted_at   :: integer(),
               kind        :: binary(),
               stimulus    :: map() | undefined}).

-opaque post() :: #post{}.
-export_type([post/0]).

%% @doc An opening post: the first thing this mind says about an item.
-spec opening(binary(), binary(), binary(), map() | undefined) -> post().
opening(PostId, From, Body, Stimulus) ->
    #post{post_id = PostId, from = From, body = Body, kind = <<"opening">>,
          posted_at = erlang:system_time(millisecond), stimulus = Stimulus}.

-spec event_type() -> binary().
event_type() -> <<"agora_post_published_v1">>.

%% @doc The wire form. Strings are tagged text, the id and the reply target are
%% bytes (the keeper hashes the id and stores the target as it travels), and
%% the time is an integer in milliseconds.
-spec to_map(post()) -> map().
to_map(#post{post_id = PostId, from = From, body = Body, posted_at = At,
             kind = Kind, stimulus = Stimulus}) ->
    with_stimulus(#{event_type => event_type(),
                    post_id => PostId,
                    from => {text, From},
                    body => {text, Body},
                    in_reply_to => <<>>,
                    posted_at => At,
                    kind => {text, Kind}},
                  Stimulus).

%% A post that answers nothing in particular carries no stimulus field at all,
%% rather than an empty map: absent is what the keeper reads as "not prompted".
with_stimulus(Map, undefined) -> Map;
with_stimulus(Map, Stimulus)  -> Map#{stimulus => Stimulus}.
