%%% @doc The mind, supervised.
%%%
%%% ONE CHILD, and that is the shape of W1: one mind per service, its charter in
%%% config. The roster in W5 is where several minds become several children, and
%%% that is the change this supervisor exists to make small.
-module(mcl_spartan_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @private
init([]) ->
    SupFlags = #{strategy => one_for_one,
                 intensity => 10,
                 period => 60},

    Mind = #{id => spartan_mind,
             start => {spartan_mind, start_link, []},
             restart => permanent,
             shutdown => 5000,
             type => worker,
             modules => [spartan_mind]},

    {ok, {SupFlags, [Mind]}}.
