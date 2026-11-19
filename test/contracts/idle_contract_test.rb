# frozen_string_literal: true

require "test_helper"
require_relative "status_disjunction_finder"

# "Is this session at rest somewhere a prompt could be handed to it?" has one
# answer, Session#idle?: `needs_input` or `waiting`.
#
# The queue's schedulers and its drain ask it, and so do the doors that deliver
# straight to an idle session: the web follow-up form, a trigger's direct
# delivery, an MCP App widget's send-now, and both recovery continues. Spelled
# out at each site, a change to which states count as at rest — the one #566
# made, when `waiting` started counting — has to be found at every copy, and a
# copy that is missed answers differently from its siblings with nothing to say
# so.
#
# So no file in app/ or lib/ spells the two-state disjunction out except the
# predicate itself. A chain that tests these two states and others (the
# three-state accepts_follow_up? chain, DeploymentRecoveryJob's
# `needs_input? || waiting? || failed?`) is a different question and is not
# flagged.
class IdleContractTest < ActiveSupport::TestCase
  REST_STATES = %i[needs_input? waiting?].freeze
  PREDICATE_HOME = "app/models/concerns/session_state_machine.rb"
  PREDICATE_NAME = :idle?

  def spelled_out_copies(path, source)
    StatusDisjunctionFinder.offenders(path, source, states: REST_STATES,
                                                    predicate_name: PREDICATE_NAME, predicate_home: PREDICATE_HOME)
  end

  test "nothing outside Session#idle? spells out needs_input? || waiting?" do
    offenders = StatusDisjunctionFinder.app_sources.flat_map { |path, source| spelled_out_copies(path, source) }

    assert_empty offenders,
                 "These spell out the resting states instead of calling Session#idle?:\n" \
                 "#{offenders.join("\n")}"
  end

  test "the finder catches every spelling and leaves wider chains alone" do
    flagged = <<~RUBY
      a unless s.needs_input? || s.waiting?
      b if @s.waiting? || @s.needs_input?
      if x then y elsif session.waiting? || session.needs_input? then z end
      c = x || foo(s.needs_input? || s.waiting?)
    RUBY
    assert_equal %w[x.rb:1 x.rb:2 x.rb:3 x.rb:4], spelled_out_copies("x.rb", flagged)

    ignored = <<~RUBY
      a if s.running? || s.waiting? || s.needs_input?
      b if (s.needs_input? || s.waiting? || s.failed?)
      c if s.running? || s.waiting?
      d = s.needs_input? && s.waiting?
      # s.needs_input? || s.waiting?
      e = "s.needs_input? || s.waiting?"
    RUBY
    assert_empty spelled_out_copies("x.rb", ignored)

    assert_empty spelled_out_copies(PREDICATE_HOME, "def idle?\n  needs_input? || waiting?\nend\n")
    assert_equal [ "#{PREDICATE_HOME}:2" ],
                 spelled_out_copies(PREDICATE_HOME, "def accepts_follow_up?\n  needs_input? || waiting?\nend\n")
  end
end
