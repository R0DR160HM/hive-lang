%% Where this machine keeps a user's own files — the root of the package cache
%% remote imports are cloned into (see `hive/imports.gleam`).
%%
%% Erlang has no portable "home directory" call, so this is the two environment
%% variables between them: HOME everywhere but Windows, USERPROFILE there. A
%% machine that sets neither gets the empty string back, and the caller falls
%% back to a cache beside the program it is compiling — which is worse only in
%% that it is not shared.
-module(hive_home_ffi).

-export([home/0]).

home() ->
    case first_set(["HOME", "USERPROFILE"]) of
        false -> <<"">>;
        Value -> unicode:characters_to_binary(Value)
    end.

first_set([]) ->
    false;
first_set([Name | Rest]) ->
    case os:getenv(Name) of
        false -> first_set(Rest);
        "" -> first_set(Rest);
        Value -> Value
    end.
