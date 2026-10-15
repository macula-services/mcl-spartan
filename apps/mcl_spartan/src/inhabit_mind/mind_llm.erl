%%% @doc Where a mind reaches off the BEAM to think. One endpoint, one call.
%%%
%%% ENGINE-AGNOSTIC BY CONFIG, NOT BY CODE. Endpoint, model and key are
%%% deployment facts: a mind is a mind whichever engine answers, so nothing
%%% here names a provider, and swapping one for another is an environment
%%% change rather than a release. The default is a free OpenAI-compatible
%%% endpoint, so the walking skeleton adds no spend by being built.
%%%
%%% NO CAROUSEL AND NO BREAKER YET, DELIBERATELY. W3 ports spartan's provider
%%% pools, its round-robin over (provider, key) slots and its circuit breaker.
%%% W1b's job is one mind, one endpoint, one turn: the failure mode here is a
%%% logged error and a post that does not happen, which is the honest behaviour
%%% for a skeleton and the thing the carousel later improves.
%%%
%%% WHAT THE ENDPOINT REPORTED IS WHAT IS COUNTED. `usage.total_tokens' is the
%%% number the daily cap spends. An endpoint that reports no usage would make
%%% the cap unenforceable, so that case falls back to a character estimate
%%% rather than to zero.
-module(mind_llm).

-export([reason/2, endpoint/0, model/0, api_key/0, timeout_ms/0, max_tokens/0, config/0]).

-define(DEFAULT_ENDPOINT, "https://api.groq.com/openai/v1/chat/completions").
-define(DEFAULT_MODEL, <<"openai/gpt-oss-20b">>).
-define(DEFAULT_TIMEOUT_MS, 30000).
%% A REASONING MODEL SPENDS THIS BUDGET ON THINKING BEFORE IT WRITES ANYTHING,
%% and reasoning tokens count against the completion limit. At 300 a long think
%% produced an EMPTY content, which reads here as "nothing to say", so the one
%% post this increment exists to make came down to luck. `reasoning_effort' is
%% sent low for the same reason, and a reply that still runs out of room is
%% reported as truncated rather than taken for silence: only the two of those
%% together make an empty post mean what it says.
-define(DEFAULT_MAX_TOKENS, 1024).
-define(CHARS_PER_TOKEN, 4).

%% @doc One reasoning turn: the charter as the system message, the item as the
%% user message, and the answer back with what it cost.
-spec reason(binary(), binary()) -> {ok, map()} | {error, term()}.
reason(Charter, Prompt) ->
    sent(request_body(Charter, Prompt)).

sent(Body) ->
    ok = ensure_http(),
    case httpc:request(post, {endpoint(), headers(), "application/json", Body},
                       [{timeout, timeout_ms()}, {connect_timeout, timeout_ms()},
                        {ssl, ssl_opts()}],
                       [{body_format, binary}]) of
        {ok, {{_Version, 200, _Reason}, _Headers, Response}} ->
            parse(Response, byte_size(Body));
        {ok, {{_Version, Status, _Reason}, _Headers, Response}} ->
            {error, {http_status, Status, clip(Response)}};
        {error, Reason} ->
            {error, {unreachable, Reason}}
    end.

%% @private The prompt is a fixed size per turn, so the question the endpoint
%% answered is the cost question: only the answer's own length is unknown.
parse(Response, RequestBytes) ->
    try jsx:decode(Response, [return_maps]) of
        Decoded -> parsed(Decoded, RequestBytes)
    catch
        _:_ -> {error, {not_json, clip(Response)}}
    end.

parsed(#{<<"choices">> := [#{<<"message">> := Message} | _] = Choices} = Decoded, RequestBytes) ->
    content(Message, finish(Choices), Decoded, RequestBytes);
parsed(_Unexpected, _RequestBytes) ->
    {error, no_choice}.

%% A reply the endpoint cut off is not a post. `length' means the model was
%% still writing when it ran out of room, and what came back is a paragraph
%% ending mid-sentence: publishing that is worse than saying nothing, and
%% treating it as silence would hide a budget that is too small.
content(_Message, <<"length">>, _Decoded, _RequestBytes) ->
    {error, truncated};
content(Message, _FinishReason, Decoded, RequestBytes) ->
    Body = text(maps:get(<<"content">>, Message, <<>>)),
    {ok, #{body => Body,
           tokens => tokens(maps:get(<<"usage">>, Decoded, undefined), RequestBytes, Body)}}.

finish([#{<<"finish_reason">> := Reason} | _]) -> Reason;
finish([_Other | Rest])                          -> finish(Rest);
finish([])                                       -> undefined.

text(Content) when is_binary(Content) -> Content;
text(_NotText)                        -> <<>>.

%% What the endpoint says it cost, or an estimate when it declines to say:
%% characters over four, which is the usual rule of thumb for English prose and
%% is deliberately generous rather than clever, because an under-count here is
%% a cap that does not hold.
tokens(#{<<"total_tokens">> := Total}, _RequestBytes, _Content)
  when is_integer(Total), Total >= 0 ->
    Total;
tokens(undefined, RequestBytes, Content) ->
    (RequestBytes + byte_size(Content)) div ?CHARS_PER_TOKEN;
tokens(_Unusable, RequestBytes, Content) ->
    (RequestBytes + byte_size(Content)) div ?CHARS_PER_TOKEN.

%% --- configuration ---
%%
%% ⚠ TEXT AND NUMBERS ARE READ DIFFERENTLY, AND THAT IS NOT PEDANTRY. sys.config
%% substitutes these from the environment, so `{mind_max_tokens, 1024}' arrives
%% as an INTEGER and `{mind_model, "..."}' as a STRING; a helper that only
%% accepted strings would take the ceiling and the timeout from the file and
%% quietly ignore both, leaving every deployment on the defaults with nothing
%% saying so. A number that is not a positive integer is the default.
%%
%% ⚠ AND ONE TYPE COMES OUT OF THE TEXT READER, A BINARY, WHICHEVER FORM WENT
%% IN. A string was passed through unchanged, and a string that reaches
%% jsx:encode comes out as an ARRAY OF CODE POINTS, not as a JSON string: the
%% first deployment asked its endpoint for
%% `"model":[111,112,101,110,97,105,...]' and the endpoint refused the whole
%% request, "'model' : doesn't match any schema from 'anyOf'". The tests missed
%% it because they set the model as a BINARY, which is the shape the code
%% wanted rather than the shape the deploy file gives. `binary_to_list/1' in
%% authorization/1 wanted a binary too, so a string key was a crash there
%% rather than a refusal.

-spec endpoint() -> binary().
endpoint() -> text(mind_endpoint, ?DEFAULT_ENDPOINT).

-spec model() -> binary().
model() -> text(mind_model, ?DEFAULT_MODEL).

%% @doc The key the endpoint is called with. The environment first, because
%% that is how a box secret reaches a container, and the app env second so a
%% test can hand the module one without touching the box.
-spec api_key() -> binary() | undefined.
api_key() ->
    case os:getenv("MCL_MIND_API_KEY") of
        false -> text(mind_api_key, undefined);
        Key   -> unicode:characters_to_binary(Key)
    end.

-spec timeout_ms() -> pos_integer().
timeout_ms() -> number(mind_timeout_ms, ?DEFAULT_TIMEOUT_MS).

-spec max_tokens() -> pos_integer().
max_tokens() -> number(mind_max_tokens, ?DEFAULT_MAX_TOKENS).

%% @doc What this mind is configured to think with, for /health and the logs.
%% The key is reported as PRESENT OR ABSENT and never as a value.
-spec config() -> map().
config() ->
    #{endpoint => endpoint(), model => model(),
      key => key_presence(api_key()), timeout_ms => timeout_ms(),
      max_tokens => max_tokens()}.

key_presence(undefined) -> absent;
key_presence(<<>>)      -> absent;
key_presence(_Key)      -> present.

%% @doc One type out, whichever form the deploy file used. The default passes
%% through untouched: api_key/0's is undefined.
text(Key, Default) ->
    case application:get_env(mcl_spartan, Key, Default) of
        Value when is_binary(Value), Value =/= <<>> -> Value;
        Value when is_list(Value), Value =/= ""     -> unicode:characters_to_binary(Value);
        _                                           -> Default
    end.

number(Key, Default) ->
    case application:get_env(mcl_spartan, Key, Default) of
        Value when is_integer(Value), Value > 0 -> Value;
        _                                       -> Default
    end.

%% --- the request ---

request_body(Charter, Prompt) ->
    jsx:encode(#{<<"model">> => model(),
                 <<"messages">> => [#{<<"role">> => <<"system">>, <<"content">> => Charter},
                                    #{<<"role">> => <<"user">>, <<"content">> => Prompt}],
                 %% A reasoning model's thinking is paid for out of the
                 %% completion budget, so it is asked to think little: this mind
                 %% writes one short paragraph, and effort spent elsewhere is
                 %% room taken from the paragraph.
                 <<"reasoning_effort">> => <<"low">>,
                 <<"max_tokens">> => max_tokens(),
                 <<"temperature">> => 0.7}).

headers() ->
    [{"content-type", "application/json"} | authorization(api_key())].

authorization(undefined) -> [];
authorization(<<>>)      -> [];
authorization(Key)       -> [{"authorization", "Bearer " ++ binary_to_list(Key)}].

ensure_http() ->
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(ssl),
    ok.

%% Verify against the system trust store, the same posture mcl-news takes for
%% the wire it reads. No Big-Tech SDK sits in this path: one HTTPS POST.
ssl_opts() ->
    [{verify, verify_peer},
     {cacerts, public_key:cacerts_get()},
     {customize_hostname_check,
      [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}].

%% An error body is evidence, so it is kept, but bounded: a gateway error page
%% is not worth a log line per turn forever.
clip(Response) when byte_size(Response) =< 400 -> Response;
clip(Response) -> binary:part(Response, 0, 400).
