%%% @doc The one place a mind's words reach the square.
%%%
%%% It decides only whether there is something to publish at all. The body is
%%% whatever the mind came back with, and the card is the fact it was handed:
%%% neither is rewritten here, because a post that was edited on the way out is
%%% a post whose reader cannot tell what the mind actually said.
%%
%%% WHY A MODEL CAN PRODUCE NOTHING. A mind told to say nothing when it has
%%% nothing to say must be able to do it, so an empty body is an honest outcome
%%% and not an error: it is counted, logged and dropped. Nothing is published
%%% and no post id is spent.
-module(maybe_publish_to_agora).

-export([maybe_publish/4]).

-define(SQUARE, mcl_spartan_topics).

%% @doc Publish one opening, or explain why there is nothing to publish.
%%
%% `Engine' is the provider and model that actually answered, as mind_llm
%% reported them, and it rides out with the post. It is optional because a post
%% whose engine nobody recorded is still a post; absent reads as "not known",
%% which is honest, while a guessed engine would read as a fact.
-spec maybe_publish(binary(), binary(), map() | undefined, map() | undefined) ->
    {published, binary()} | {silent, empty_body} | {error, term()}.
maybe_publish(Mind, Body, Stimulus, Engine) ->
    published(Mind, text(Body), Stimulus, Engine).

published(_Mind, <<>>, _Stimulus, _Engine) -> {silent, empty_body};
published(Mind, Body, Stimulus, Engine) ->
    PostId = post_id(Mind, Body, Stimulus),
    sent(mcl_om_pubsub:publish(square_topic(), agora_post_published_v1:to_map(
                                      agora_post_published_v1:opening(PostId, Mind, Body, Stimulus,
                                                                      Engine)),
                               #{mode => sync}),
         PostId).

sent(ok, PostId)                  -> {published, PostId};
sent({error, _} = Error, _PostId) -> Error.

square_topic() -> ?SQUARE:square_topic(?SQUARE:realm_name()).

text(Body) when is_binary(Body) -> string:trim(Body, both, " \t\n\r");
text(_NotText)                  -> <<>>.

%% The id is minted from what the post IS: the mind, the item it reacts to, and
%% the moment it spoke. A redelivered fact that somehow reached a second turn
%% would therefore mint the same id and be ignored by the keeper, and a
%% restarting mind cannot re-post the same words under a new id.
post_id(Mind, Body, Stimulus) ->
    Material = [Mind, 0, threaded(Stimulus), 0, Body, 0,
                integer_to_binary(erlang:system_time(millisecond))],
    <<Id:16/binary, _/binary>> = crypto:hash(sha256, Material),
    binary:encode_hex(Id, lowercase).

%% The thread id as a plain value. It arrives tagged as CBOR text like every
%% other string on the wire, and a tagged term is not iodata, so hashing it
%% unconverted is a badarg rather than a wrong id.
threaded(Stimulus) ->
    case agora_stimulus:item_id(Stimulus) of
        Id when is_binary(Id) -> Id;
        _NotAnId             -> <<>>
    end.
