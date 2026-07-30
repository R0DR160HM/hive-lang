%% Spawning the compiled program for `hive run` — see `hive/spawn.gleam` for why
%% this cannot go through `shellout`, and why the program's input is handed over
%% in a file rather than written down its standard input.
-module(hive_spawn_ffi).

-export([run/5]).

%% The variable the input relay's path is passed to the program in. The other
%% half of this contract is `TermRead` in `hive/runtime.gleam`, including the
%% `.end` suffix that names the file marking the end of the input.
-define(RELAY_VAR, "HIVE_RUN_STDIN_FILE").

%% run(Command, Args, Dir, Env, Relay) -> ExitStatus
%%
%% Runs `Command` (looked up on PATH, then inside `Dir`) with `Args` in `Dir`,
%% carries its output to ours, and returns the status it exited with. Standard
%% error is left alone, so the child writes to our terminal directly.
%%
%% `Relay` is where our own standard input is copied for the program to read,
%% or `<<>>` for a program with no `hive.term.read()` in it — which is left
%% entirely alone, our standard input included, so that whatever runs after us
%% still has it.
run(Command, Args, Dir, Env, Relay) ->
    case find_executable(Command, Dir) of
        error ->
            %% The status a shell reports for a command it cannot find.
            127;
        {ok, Executable} ->
            %% Nothing here writes to the child, so no exit signal from the port
            %% is expected. Trapping them anyway means that if one does arrive,
            %% it is a message to be handled rather than something that takes
            %% the compiler down. The flag goes back as it was afterwards, so
            %% this is not something the rest of the compiler runs under.
            Previous = process_flag(trap_exit, true),
            State = start(Executable, Args, Dir, Env, Relay),
            try
                relay(State)
            after
                process_flag(trap_exit, Previous),
                %% The input is not left lying around on disk afterwards: it is
                %% whatever was typed at the program's prompts.
                discard_relay(State)
            end
    end.

start(Executable, Args, Dir, Env, Relay) ->
    %% The relay has to exist before the child does, so that a program reading
    %% at once finds it there.
    Input = open_input(Relay),
    Child = open_port({spawn_executable, Executable}, [
        {args, Args},
        {cd, Dir},
        {env, environment(Env, Relay)},
        %% Read only. The child's standard input is closed and never written to:
        %% input it had not read by the time it exited would be left in the pipe,
        %% and it is the write of it that fails then — killing the port before it
        %% has reported the status the program exited with. Handing the input
        %% over in a file is what avoids ever writing to the child at all.
        in,
        %% Deliver output as it arrives rather than a line at a time: a prompt
        %% written without a trailing newline has to reach the terminal before
        %% the read that follows it, not after.
        stream,
        binary,
        %% Without this the port is closed — and an exit signal sent — the moment
        %% the child closes its output, which would race the exit status being
        %% waited for below.
        eof,
        exit_status,
        hide
    ]),
    Input#{
        child => Child,
        output_done => false,
        status => none,
        port_dead => false
    }.

%% Our own input is read straight off file descriptor 0 rather than through
%% io:get_line/1, because the io server is the wrong tool twice over: its Windows
%% console reader crashes outright on a standard input redirected from NUL —
%% taking standard output down with it — and going through it would hand us
%% decoded lines where copying the bytes across verbatim is all that is wanted.
open_input(<<>>) ->
    #{relay => none, file => none, stdin => none};
open_input(Relay) ->
    Path = binary_to_list(Relay),
    %% What an earlier run left behind is not this run's input.
    _ = file:delete(Path),
    _ = file:delete(Path ++ ".end"),
    case file:open(Path, [write, raw, binary]) of
        {ok, File} ->
            #{
                relay => Path,
                file => File,
                stdin => open_port({fd, 0, 1}, [in, stream, binary, eof])
            };
        %% Nowhere to put the input. The program still runs; its reads reach the
        %% end of an empty relay and come back "", as they do with no input at
        %% all.
        {error, _Reason} ->
            #{relay => Path, file => none, stdin => none}
    end.

%% Carries the child's output out and our input into the relay until the child is
%% finished.
relay(#{child := Child, stdin := Stdin} = State) ->
    receive
        {Child, {data, Bytes}} ->
            io:put_chars(Bytes),
            relay(State);
        {Child, eof} ->
            finish(State#{output_done := true});
        {Child, {exit_status, Status}} ->
            finish(State#{status := Status});
        %% Not expected — nothing is written to the child — but if the port does
        %% go away, nothing further can arrive through it.
        {'EXIT', Child, _Reason} ->
            finish(State#{output_done := true, port_dead := true});
        %% A read of nothing means end of input just as `eof` does: that is how a
        %% standard input redirected from NUL reports itself on Windows.
        {Stdin, {data, <<>>}} ->
            relay(end_input(State));
        {Stdin, eof} ->
            relay(end_input(State));
        {Stdin, {data, Bytes}} ->
            relay(forward(State, Bytes));
        {'EXIT', Stdin, _Reason} ->
            relay(end_input(State));
        {Stdin, _Other} ->
            relay(State)
    end.

%% The child is finished once its exit status is known and no more of its output
%% can arrive. Both have to be in hand before returning: the status does not
%% travel down the same pipe as the output and can overtake the last of it, so
%% returning on the status alone would drop whatever the program printed last.
finish(#{status := Status, output_done := true}) when is_integer(Status) ->
    Status;
%% Only reachable if the port died before the child was reaped, leaving no
%% status to report.
finish(#{status := none, port_dead := true}) ->
    1;
finish(State) ->
    relay(State).

%% Written straight through rather than buffered: a prompt is answered one line
%% at a time, and the program is waiting on each one.
forward(#{file := none} = State, _Bytes) ->
    State;
forward(#{file := File} = State, Bytes) ->
    _ = file:write(File, Bytes),
    State.

%% Our input is over. Closing the relay flushes it, and only then is the file
%% that says so created — so a program that finds it can trust that everything
%% written before it is already there to be read.
end_input(#{file := none} = State) ->
    State;
end_input(#{file := File, relay := Path} = State) ->
    _ = file:close(File),
    _ = file:write_file(Path ++ ".end", <<>>),
    State#{file := none}.

discard_relay(#{relay := none}) ->
    ok;
discard_relay(#{relay := Path, file := File}) ->
    %% Already closed if the input ran out before the program did.
    _ =
        case File of
            none -> ok;
            _ -> file:close(File)
        end,
    _ = file:delete(Path),
    _ = file:delete(Path ++ ".end"),
    ok.

find_executable(Command, Dir) ->
    Name = binary_to_list(Command),
    case os:find_executable(Name) of
        false ->
            InDir = filename:join(binary_to_list(Dir), Name),
            case filelib:is_regular(InDir) of
                true -> {ok, InDir};
                false -> error
            end;
        Executable ->
            {ok, Executable}
    end.

environment(Env, Relay) ->
    All =
        case Relay of
            <<>> -> Env;
            _ -> [{<<?RELAY_VAR>>, Relay} | Env]
        end,
    [
        {
            binary_to_list(Name),
            unicode:characters_to_list(Value, file:native_name_encoding())
        }
     || {Name, Value} <- All
    ].
