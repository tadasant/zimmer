# frozen_string_literal: true

require "test_helper"
require_relative "status_disjunction_finder"

# "Is this session in a state a turn can be in?" has one answer,
# Session#in_turn_state?: `running` (a worker has spawned the process) or
# `waiting` (the turn is queued for one, since #1040).
#
# It is the cheap status read that comes before any job-row question:
# Sessions::LiveTurn's gate, the clone-setup park in Sessions::ParkUndeliveredTurn,
# AuthOutageParkService's refused-spawn park and its running_job_id stamp,
# AgentSessionJob's "did the session move under us" check, and GoalCheck's
# provisional flag. Spelled out at each site, a change to which states can hold a
# turn — the one #1040 made, when `waiting` started meaning "queued" — has to be
# found at every copy, and a copy that is missed answers differently from its
# siblings with nothing to say so.
#
# So no file in app/ or lib/ spells the two-state disjunction out except the
# predicate itself. A chain that tests these two states and others (the
# three-state accepts_follow_up? chain) is a different question and is not
# flagged.
class InTurnStateContractTest < ActiveSupport::TestCase
  TURN_STATES = %i[running? waiting?].freeze
  PREDICATE_HOME = "app/models/session.rb"
  PREDICATE_NAME = :in_turn_state?

  def spelled_out_copies(path, source)
    StatusDisjunctionFinder.offenders(path, source, states: TURN_STATES,
                                                    predicate_name: PREDICATE_NAME, predicate_home: PREDICATE_HOME)
  end

  test "nothing outside Session#in_turn_state? spells out running? || waiting?" do
    offenders = StatusDisjunctionFinder.app_sources.flat_map { |path, source| spelled_out_copies(path, source) }

    assert_empty offenders,
                 "These spell out the turn states instead of calling Session#in_turn_state?:\n" \
                 "#{offenders.join("\n")}"
  end

  test "the finder catches every spelling and leaves the three-state chain alone" do
    flagged = <<~RUBY
      a unless s.running? || s.waiting?
      b if (s.reload.waiting? || s.running?) && s.running_job_id.blank?
      c = foo(s.waiting? || s.running?)
    RUBY
    assert_equal %w[x.rb:1 x.rb:2 x.rb:3], spelled_out_copies("x.rb", flagged)

    ignored = <<~RUBY
      a if s.running? || s.waiting? || s.needs_input?
      b if s.needs_input? || (s.running? || s.waiting?)
      c if s.needs_input? || s.waiting?
      d = s.running? && s.waiting?
      # s.running? || s.waiting?
      e = "s.running? || s.waiting?"
    RUBY
    assert_empty spelled_out_copies("x.rb", ignored)

    assert_empty spelled_out_copies(PREDICATE_HOME, "def in_turn_state?\n  running? || waiting?\nend\n")
    assert_equal [ "#{PREDICATE_HOME}:2" ],
                 spelled_out_copies(PREDICATE_HOME, "def accepts_follow_up?\n  running? || waiting?\nend\n")
  end
end
