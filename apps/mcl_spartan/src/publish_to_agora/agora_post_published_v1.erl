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

-export([opening/5, to_map/1, event_type/0]).

-record(post, {post_id     :: binary(),
               from        :: binary(),
               body        :: binary(),
               posted_at   :: integer(),
               kind        :: binary(),
               stimulus    :: map() | undefined,
               engine      :: map() | undefined}).

-opaque post() :: #post{}.
-export_type([post/0]).

%% @doc An opening post: the first thing this mind says about an item.
-spec opening(binary(), binary(), binary(), map() | undefined, map() | undefined) -> post().
opening(PostId, From, Body, Stimulus, Engine) ->
    #post{post_id = PostId, from = From, body = Body, kind = <<"opening">>,
          posted_at = erlang:system_time(millisecond), stimulus = Stimulus,
          engine = Engine}.

-spec event_type() -> binary().
event_type() -> <<"agora_post_published_v1">>.

%% @doc The wire form. Strings are tagged text, the id and the reply target are
%% bytes (the keeper hashes the id and stores the target as it travels), and
%% the time is an integer in milliseconds.
-spec to_map(post()) -> map().
to_map(#post{post_id = PostId, from = From, body = Body, posted_at = At,
             kind = Kind, stimulus = Stimulus, engine = Engine}) ->
    with_engine(with_stimulus(#{event_type => event_type(),
                                post_id => PostId,
                                from => {text, From},
                                body => {text, Body},
                                in_reply_to => <<>>,
                                posted_at => At,
                                kind => {text, Kind}},
                               Stimulus),
                Engine).

%% A post that answers nothing in particular carries no stimulus field at all,
%% rather than an empty map: absent is what the keeper reads as "not prompted".
with_stimulus(Map, undefined) -> Map;
with_stimulus(Map, Stimulus)  -> Map#{stimulus => Stimulus}.

%% WHICH ENGINE WROTE THIS, attached by the harness from the slot that actually
%% answered (see mind_llm:engine_of/1). Same principle as the card: a model asked
%% to name its own engine would name the one it was told about, which is the
%% pool's head rather than the truth.
%%
%% ABSENT when it is not known, never a placeholder and never half of one: an
%% engine needs BOTH a provider and a model, so a post carrying one of the two
%% would let a reader draw a conclusion the record cannot support. A post from a
%% mind that does not know its engine is a post, and the field simply is not
%% there.
with_engine(Map, Engine) ->
    case engine_wire(Engine) of
        undefined -> Map;
        Wire      -> Map#{engine => Wire}
    end.

engine_wire(#{provider := Provider, model := Model})
  when is_binary(Provider), Provider =/= <<>>, is_binary(Model), Model =/= <<>> ->
    #{provider => {text, Provider}, model => {text, Model}};
engine_wire(_AbsentOrIncomplete) ->
    undefined.
