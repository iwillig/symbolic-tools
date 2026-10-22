-module(symbolic_parse_log_handler).
-export([adding_handler/1, removing_handler/1, log/2]).

adding_handler(Config) -> {ok, Config}.
removing_handler(_Config) -> ok.
log(Event, Config) ->
    maps:get(receiver, Config) ! {parse_log, Event},
    ok.
