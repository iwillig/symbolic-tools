-module(ts_extract_ruby_tests).
-include_lib("eunit/include/eunit.hrl").

extracts_instance_and_singleton_methods_test() ->
    Source = <<"class Greeter\n"
               "  def greet(name, punctuation = '!')\n"
               "    name.upcase\n"
               "  end\n"
               "  def self.build(value)\n"
               "    new(value)\n"
               "  end\n"
               "end\n">>,
    Facts = ts_extract_ruby:text("methods.rb", Source),
    Path = 'methods.rb',
    ?assert(lists:member({defines, greet, 2, <<"(name, punctuation = '!')">>, Path, 2}, Facts)),
    ?assert(lists:member({defines, build, 1, <<"(value)">>, Path, 5}, Facts)),
    ?assert(lists:member({calls, greet, 2, {member, name, upcase, 0}, Path, 3}, Facts)),
    ?assert(lists:member({calls, build, 1, {local, new, 1}, Path, 6}, Facts)).

ignores_calls_outside_methods_test() ->
    Facts = ts_extract_ruby:text("top.rb", <<"puts 'top level'\ndef run\n  puts 'inside'\nend\n">>),
    ?assertEqual([{calls, run, 0, {local, puts, 1}, 'top.rb', 3}],
                 [F || F = {calls, _, _, _, _, _} <- Facts]).

comments_retain_ruby_marker_and_drop_line_ending_test() ->
    ?assert(lists:member({comment, 'comment.rb', 1, <<"# hello">>},
                         ts_extract_ruby:text("comment.rb", <<"# hello\n">>))).
