# frozen_string_literal: true

require "test_helper"
require_relative "status_disjunction_finder"

# "Can this session take a turn?" has one answer, Session#accepts_follow_up?.
#
# Every path that hands a session a turn (the REST and MCP follow-up doors, the
# interrupt service, message_parent's interrupt, the enqueued-message processor,
# trigger reuse, the lost-clone rebuild) asks the same question, and the answer
# is the same three states: running, waiting, needs_input. Spelled out at each
# call site, those copies drift: a new state, or a change to which states take a
# turn, has to be made at every copy, and a copy that is missed answers
# differently from its siblings with nothing to say so.
#
# So no file in app/ or lib/ spells the three-state disjunction out except the
# predicate itself. StatusDisjunctionFinder parses the source, so a mention in a
# comment or a string does not count.
class AcceptsFollowUpContractTest < ActiveSupport::TestCase
  TURN_TAKING_STATES = %i[running? waiting? needs_input?].freeze
  PREDICATE_HOME = "app/models/session.rb"
  PREDICATE_NAME = :accepts_follow_up?

  def spelled_out_copies(path, source)
    StatusDisjunctionFinder.offenders(path, source, states: TURN_TAKING_STATES,
                                                    predicate_name: PREDICATE_NAME, predicate_home: PREDICATE_HOME)
  end

  test "nothing outside Session#accepts_follow_up? spells out running? || waiting? || needs_input?" do
    offenders = StatusDisjunctionFinder.app_sources.flat_map { |path, source| spelled_out_copies(path, source) }

    assert_empty offenders,
                 "These spell out the turn-taking states instead of calling Session#accepts_follow_up?:\n" \
                 "#{offenders.join("\n")}"
  end

  test "the finder catches every spelling and leaves partial and unrelated checks alone" do
    flagged = <<~RUBY
      a if s.running? || s.waiting? || s.needs_input?
      b unless s.needs_input? || (s.running? || s.waiting?)
      c = s.waiting? || s.needs_input? || s.running?
    RUBY
    assert_equal %w[x.rb:1 x.rb:2 x.rb:3], spelled_out_copies("x.rb", flagged)

    ignored = <<~RUBY
      a if s.running? || s.waiting?
      b if s.needs_input? || s.waiting? || s.failed?
      d if s.failed? || s.running? || s.waiting? || s.needs_input?
      f if s.running? || s.waiting? || s.needs_input? || s.failed?
      # s.running? || s.waiting? || s.needs_input?
      c = "s.running? || s.waiting? || s.needs_input?"
    RUBY
    assert_empty spelled_out_copies("x.rb", ignored)

    assert_empty spelled_out_copies(PREDICATE_HOME, "def accepts_follow_up?\n  running? || waiting? || needs_input?\nend\n")
    assert_equal [ "#{PREDICATE_HOME}:1" ], spelled_out_copies(PREDICATE_HOME, "x if s.running? || s.waiting? || s.needs_input?\n")
    assert_equal [ "#{PREDICATE_HOME}:2" ],
                 spelled_out_copies(PREDICATE_HOME, "def other?\n  running? || waiting? || needs_input?\nend\n")
    assert_equal [ "#{PREDICATE_HOME}:2" ],
                 spelled_out_copies(PREDICATE_HOME, "def accepts_follow_up?\n  running? || s.waiting? || s.needs_input?\nend\n")
  end
end
