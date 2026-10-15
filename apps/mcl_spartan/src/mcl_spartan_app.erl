%%% @doc OTP application entry.
%%%
%%% mcl_om:boot/1 wires the mesh, the realm identity and health, and subscribes
%%% the wire to this service's handler, and THEN starts the service. STORELESS:
%%% the service module exports no store_id/0 and no data_dir/0 callback, so no
%%% reckon-db is started, and the only thing a mind keeps between runs is its
%%% own daily ledger (mind_budget).
-module(mcl_spartan_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    mcl_om:boot(mcl_spartan_service).

stop(_State) -> ok.
