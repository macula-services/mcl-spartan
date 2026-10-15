%%% @doc The hard daily allowance, and what happens when it is gone.
%%%
%%% A CAP THAT DOES NOT SURVIVE A RESTART IS NOT A CAP. The obvious shape keeps
%%% the count in the mind's own memory, and then a crash loop hands the mind a
%%% fresh allowance every time it comes back, which is exactly the runaway the
%%% cap exists to stop. So the count lives in one small file in the service's
%%% data directory, written after every turn, and the day key is UTC so the
%%% allowance turns over at one moment wherever the box is.
%%%
%%% IT IS A FILE AND NOT A STORE, ON PURPOSE. mcl-spartan has no event history
%%% to keep and no read model to rebuild: this is one integer and the day it
%%% belongs to. The roster in W5 is what earns a real store, and this file
%%% disappears into it then.
%%%
%%% A BUDGET THAT CANNOT BE READ IS A FRESH DAY, not a crash. The worst case is
%%% one day counted twice, and the alternative is a mind that cannot think
%%% because it cannot read its own ledger, which is worse in every direction.
-module(mind_budget).

-export([load/0, today/1, spend/2, resting/1, report/1, save/1, day/0, cap/0, path/0]).

-define(LEDGER, "mind_budget.term").
-define(DEFAULT_CAP, 100000).

-type budget() :: #{day := integer(), spent := non_neg_integer()}.
-export_type([budget/0]).

%% @doc Today's ledger: what the file holds, if the file is today's.
-spec load() -> budget().
load() ->
    today(kept(read())).

%% @doc The same ledger, rolled to today. Called BEFORE EVERY GATE and not only
%% at boot: a mind that is up across midnight would otherwise keep yesterday's
%% spend, and rest for the rest of its life. That is a cap for the life of a
%% container wearing a daily cap's name.
-spec today(budget()) -> budget().
today(Budget) ->
    rolled(Budget).

rolled(#{day := Day} = Budget) ->
    case Day =:= day() of
        true  -> Budget;
        false -> #{day => day(), spent => 0}
    end.

%% A file that is missing, unreadable, or written by an older shape is not an
%% error. `safe' on the decode is what keeps a corrupted file from being able
%% to mint atoms in the node that reads it.
kept(#{day := Day, spent := Spent} = Budget)
  when is_integer(Day), is_integer(Spent), Spent >= 0 ->
    Budget;
kept(_Unusable) ->
    #{day => day(), spent => 0}.

read() ->
    case file:read_file(path()) of
        {ok, Bin} -> decoded(Bin);
        {error, _} -> #{}
    end.

decoded(Bin) ->
    try binary_to_term(Bin, [safe]) of
        Term -> Term
    catch
        _:_ -> #{}
    end.

%% @doc Add what one turn cost. Tokens are what the endpoint reported, or the
%% estimate mind_llm falls back to when it reports nothing.
-spec spend(budget(), non_neg_integer()) -> budget().
spend(#{spent := Spent} = Budget, Tokens) when is_integer(Tokens), Tokens >= 0 ->
    Budget#{spent := Spent + Tokens}.

%% @doc Whether the day's allowance is gone. A resting mind is a normal state,
%% not a fault: it is how the design keeps a story from being paid for twice.
-spec resting(budget()) -> boolean().
resting(#{spent := Spent}) ->
    Spent >= cap().

%% @doc What /health and the logs say about the budget. `spent' is the number a
%% person watching a box actually wants, so it is the one carried out.
-spec report(budget()) -> map().
report(#{day := Day, spent := Spent}) ->
    #{day => Day, spent => Spent, cap => cap(), resting => resting(#{day => Day, spent => Spent})}.

%% @doc Write the ledger. Called after every turn that spent anything, so a
%% restart costs at most one turn's tokens rather than the whole day's.
-spec save(budget()) -> ok.
save(Budget) ->
    ok = filelib:ensure_path(data_dir()),
    file:write_file(path(), term_to_binary(Budget)).

%% @doc Days since the epoch, UTC. `erlang:system_time/1' has no day unit, so it
%% is seconds divided down: one number that changes at midnight UTC everywhere,
%% which is what a daily allowance needs and what a local date would not give.
-spec day() -> integer().
day() ->
    erlang:system_time(second) div 86400.

-spec cap() -> non_neg_integer().
cap() ->
    configured_cap(application:get_env(mcl_spartan, daily_token_cap, ?DEFAULT_CAP)).

configured_cap(Cap) when is_integer(Cap), Cap > 0 -> Cap;
configured_cap(_Unset)                             -> ?DEFAULT_CAP.

-spec path() -> file:filename_all().
path() ->
    filename:join(data_dir(), ?LEDGER).

data_dir() ->
    Dir = application:get_env(mcl_spartan, data_dir, "/data"),
    case is_list(Dir) andalso Dir =/= "" of
        true  -> Dir;
        false -> "/data"
    end.
