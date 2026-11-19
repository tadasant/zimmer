# frozen_string_literal: true

require "test_helper"
require_relative "status_disjunction_finder"
require_relative "status_list_finder"

# The statuses a turn can be in — `running` and `waiting` — are listed once, as
# Session::TURN_STATUSES, and #in_turn_state? reads it.
#
# The pair feeds SQL at most of its sites: the spot gate's turn census
# (RunningTurns, Session.running_claude_code_burn_keys, SpotSessionHold's
# starvation lane), the work backlog's `in_flight` scope, HealthMonitorService's
# orphan check, and Trigger::PENDING_INTENT_STATUSES. HeartbeatSweepJob takes it
# as a `when` clause and SlackOutageMarker asks in_turn_state?. Spelled out at
# each site, a change to which states can hold a turn — the one #1040 made, when
# `waiting` started meaning "queued" — has to be found at every copy, and a copy
# that is missed answers differently from its siblings with nothing to say so.
#
# So no file in app/ or lib/ holds a literal list of exactly these two statuses,
# as strings or symbols in any order, except the constant itself. A list that
# holds them and others (Session::NON_REAPABLE_STATUSES) is a different question
# and is not flagged. The `running? || waiting?` spelling is the in_turn_state?
# contract's.
class TurnStatusesContractTest < ActiveSupport::TestCase
  STATUSES = %i[running waiting].freeze
  CONSTANT_HOME = "app/models/session.rb"
  CONSTANT_NAME = :TURN_STATUSES

  def spelled_out_copies(path, source)
    StatusListFinder.offenders(path, source, statuses: STATUSES,
                                             constant_name: CONSTANT_NAME, constant_home: CONSTANT_HOME)
  end

  test "Session::TURN_STATUSES is running and waiting, and backs in_turn_state?" do
    assert_equal %w[running waiting], Session::TURN_STATUSES
    assert Session::TURN_STATUSES.all? { |status| Session.statuses.key?(status) }
    Session.statuses.each_key do |status|
      assert_equal Session::TURN_STATUSES.include?(status), Session.new(status: status).in_turn_state?, status
    end
  end

  test "nothing outside Session::TURN_STATUSES lists running and waiting" do
    offenders = StatusDisjunctionFinder.app_sources.flat_map { |path, source| spelled_out_copies(path, source) }

    assert_empty offenders,
                 "These list the turn statuses instead of naming Session::TURN_STATUSES:\n" \
                 "#{offenders.join("\n")}"
  end

  test "the finder catches every spelling and leaves wider lists alone" do
    flagged = <<~RUBY
      a = Session.where(status: [ :running, :waiting ])
      B = %w[waiting running].freeze
      c = %i[running waiting]
      d = [ "waiting", :running ].include?(s.status)
      case s.status
      when "running", "waiting" then 1
      end
      e = x || foo(bar: [ :waiting, :running ])
      case s.status
      when *%w[running waiting] then 1
      end
    RUBY
    assert_equal %w[x.rb:1 x.rb:2 x.rb:3 x.rb:4 x.rb:6 x.rb:8 x.rb:10], spelled_out_copies("x.rb", flagged)

    ignored = <<~RUBY
      a = %w[running waiting needs_input]
      b = [ :running ]
      c = [ :running, :waiting, :running ]
      d = [ "\#{x}", "waiting" ]
      e = [ *list, :waiting ]
      case s.status
      when "running" then 1
      when "waiting", "needs_input" then 2
      end
      # [ :running, :waiting ]
      f = "%w[running waiting]"
      g = Session::TURN_STATUSES
      case s.status
      when *Session::TURN_STATUSES then 1
      end
    RUBY
    assert_empty spelled_out_copies("x.rb", ignored)

    assert_empty spelled_out_copies(CONSTANT_HOME, "TURN_STATUSES = %w[running waiting].freeze\n")
    assert_equal [ "#{CONSTANT_HOME}:1" ], spelled_out_copies(CONSTANT_HOME, "OTHER = %w[running waiting].freeze\n")
    assert_equal [ "#{CONSTANT_HOME}:1" ], spelled_out_copies(CONSTANT_HOME, "TURN_STATUSES = { a: %w[running waiting] }\n")
    assert_equal [ "x.rb:1" ], spelled_out_copies("x.rb", "TURN_STATUSES = %w[running waiting].freeze\n")
  end
end
