%% Fetching one file over HTTPS at compile time, and the digest that says it is
%% the file we meant — see `hive/vendor.gleam` for what this is for (the three.js
%% build a program that draws a `hive.ui.scene` is compiled against).
%%
%% This is OTP's own `httpc` rather than `curl` on the PATH: the compiler already
%% runs on Erlang, so asking it to make one request adds nothing to what has to
%% be installed. The certificate chain is verified against the machine's own
%% trust store — a download that is also checked against a pinned digest has no
%% business skipping it.
-module(hive_fetch_ffi).

-export([get/1, sha256_hex/1]).

%% get(Url) -> {ok, Body} | {error, Message}
%%
%% Both are the shapes Gleam's `Result` maps onto, and the message is a sentence
%% rather than a term: it is shown to whoever ran the compiler.
get(Url) ->
    case started() of
        {error, Reason} ->
            {error, Reason};
        ok ->
            request(unicode:characters_to_list(Url))
    end.

%% The two applications a request needs. `inets` carries `httpc` and `ssl` the
%% transport; neither is started by a Gleam program on its own.
started() ->
    case application:ensure_all_started(inets) of
        {error, Bad} ->
            {error, unicode:characters_to_binary(
                      io_lib:format("could not start Erlang's HTTP client (inets): ~p", [Bad]))};
        {ok, _} ->
            case application:ensure_all_started(ssl) of
                {error, Bad} ->
                    {error, unicode:characters_to_binary(
                              io_lib:format("could not start Erlang's TLS stack (ssl): ~p", [Bad]))};
                {ok, _} -> ok
            end
    end.

request(Url) ->
    case tls() of
        {error, Reason} -> {error, Reason};
        {ok, Tls} -> request(Url, Tls)
    end.

request(Url, Tls) ->
    Http = [{timeout, 120000}, {connect_timeout, 30000}, {ssl, Tls}],
    case httpc:request(get, {Url, [{"user-agent", "hive-compiler"}]}, Http,
                       [{body_format, binary}]) of
        {ok, {{_Version, 200, _Phrase}, _Headers, Body}} ->
            {ok, Body};
        {ok, {{_Version, Status, Phrase}, _Headers, _Body}} ->
            {error, unicode:characters_to_binary(
                      io_lib:format("the server answered ~p ~s", [Status, Phrase]))};
        {error, Reason} ->
            {error, unicode:characters_to_binary(
                      io_lib:format("~p", [Reason]))}
    end.

%% Verifying the chain and the hostname both, which `httpc` does neither of
%% unless it is told to: without `verify_peer` any certificate is accepted, and
%% without the hostname match a valid certificate for somebody else's domain is.
%%
%% `cacerts_get/0` reads the operating system's trust store, and a machine with
%% none raises — which is reported as the failure it is rather than quietly
%% turning verification off.
tls() ->
    try public_key:cacerts_get() of
        Certs ->
            {ok, [{verify, verify_peer},
                  {cacerts, Certs},
                  {depth, 10},
                  {customize_hostname_check,
                   [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}]}
    catch
        _:Reason ->
            {error, unicode:characters_to_binary(
                      io_lib:format("this machine's certificate store could not be read, "
                                    "so an HTTPS download cannot be verified: ~p", [Reason]))}
    end.

%% sha256_hex(Bytes) -> <<"lowercase hex">>
sha256_hex(Bytes) ->
    Digest = crypto:hash(sha256, Bytes),
    unicode:characters_to_binary(
      string:lowercase(binary:encode_hex(Digest))).
