# frozen_string_literal: true

require "test_helper"

class Sessions::UpdateSchedulingClassTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def spot(precedence, status: :waiting, session_id: nil)
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", status: status,
      scheduling_class: SessionGenesis::SPOT, precedence: precedence, session_id: session_id)
  end

  def priority(precedence: 0, status: :waiting)
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", status: status,
      scheduling_class: SessionGenesis::PRIORITY, precedence: precedence)
  end

  def log_contents(session)
    session.logs.order(:created_at).pluck(:content)
  end

  # --- the class --------------------------------------------------------------

  test "writes the class and logs the move, labelled by the actor" do
    session = spot(10, status: :needs_input)

    result = Sessions::UpdateSchedulingClass.call(session: session, scheduling_class: "priority", actor: :mcp)

    assert session.reload.priority?
    assert_equal SessionGenesis::PRIORITY, session.scheduling_class
    assert_equal SessionGenesis::SPOT, result.previous_class
    assert_equal [ "Scheduling class set via MCP to priority (was spot)" ], log_contents(session)
  end

  test "each actor's log row reads the way its door wrote it" do
    { web: "Scheduling class set to spot (was priority)",
      mcp: "Scheduling class set via MCP to spot (was priority)",
      rest: "Scheduling class set via the REST API to spot (was priority)" }.each do |actor, line|
      session = priority(status: :needs_input)
      Sessions::UpdateSchedulingClass.call(session: session, scheduling_class: "spot", actor: actor)
      assert_equal [ line ], log_contents(session), "actor #{actor}"
    end
  end

  test "a blank class clears the choice back to the one the origin derives" do
    session = Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", status: :needs_input,
      genesis: SessionGenesis::GITHUB_ISSUE, scheduling_class: SessionGenesis::PRIORITY)
    derived = SessionGenesis.effective_class(SessionGenesis::GITHUB_ISSUE)

    [ nil, "" ].each do |blank|
      session.update!(scheduling_class: SessionGenesis::PRIORITY)
      Sessions::UpdateSchedulingClass.call(session: session, scheduling_class: blank, actor: :web)

      assert_nil session.reload.scheduling_class, "#{blank.inspect} clears it"
      assert_equal derived, session.priority_class
    end
  end

  test "an unknown class is refused before anything is written" do
    session = spot(10)

    error = assert_raises(Sessions::UpdateSchedulingClass::UnknownSchedulingClass) do
      Sessions::UpdateSchedulingClass.call(session: session, scheduling_class: "whenever", actor: :web, precedence: 99)
    end

    assert_equal "whenever", error.scheduling_class
    assert_equal "Unknown scheduling class: whenever", error.message
    session.reload
    assert_equal SessionGenesis::SPOT, session.scheduling_class
    assert_equal 10, session.precedence
    assert_empty session.logs
  end

  test "the class the session already has writes no log row" do
    session = spot(10, status: :needs_input)

    assert_no_difference -> { session.logs.count } do
      Sessions::UpdateSchedulingClass.call(session: session, scheduling_class: "spot", actor: :web)
    end
  end

  test "a retry after a failed write still logs the move" do
    # A failed UPDATE leaves the new class on the in-memory record; the retry
    # must compare against what is stored, not read it as a no-op.
    session = spot(10, status: :needs_input)
    session.scheduling_class = SessionGenesis::PRIORITY
    session.precedence = 50

    result = Sessions::UpdateSchedulingClass.call(session: session, scheduling_class: "priority", actor: :web, precedence: 50)

    assert_equal SessionGenesis::SPOT, result.previous_class
    assert_equal 10, result.previous_precedence
    assert_equal [ "Scheduling class set to priority (was spot)", "Precedence set to 50 (was 10)" ], log_contents(session)
  end

  # --- the rank ---------------------------------------------------------------

  test "an absolute precedence goes in the same write and is logged" do
    session = priority(precedence: 0, status: :needs_input)

    result = Sessions::UpdateSchedulingClass.call(session: session, scheduling_class: "spot", actor: :web, precedence: "640")

    assert_equal 640, session.reload.precedence
    assert result.precedence_changed?
    assert_equal [ "Scheduling class set to spot (was priority)", "Precedence set to 640 (was 0)" ], log_contents(session)
  end

  test "naming no rank leaves the rank alone" do
    spot(900)
    session = priority(precedence: 7, status: :needs_input)

    result = Sessions::UpdateSchedulingClass.call(session: session, scheduling_class: "spot", actor: :web)

    assert_equal 7, session.reload.precedence
    assert_not result.precedence_changed?
  end

  test "an out-of-range precedence is refused with nothing written" do
    session = priority(precedence: 0, status: :needs_input)

    assert_raises(ActiveRecord::RecordInvalid) do
      Sessions::UpdateSchedulingClass.call(session: session, scheduling_class: "spot", actor: :web,
        precedence: SessionPrecedence::MAX + 1)
    end

    assert_equal SessionGenesis::PRIORITY, session.reload.scheduling_class
    assert_empty session.logs
  end

  test "top_of_spot lands a few points above the current head of the spot queue" do
    spot(70)
    session = priority(precedence: 0, status: :needs_input)

    Sessions::UpdateSchedulingClass.call(session: session, scheduling_class: "spot", actor: :web,
      place: SessionPrecedence::PLACE_TOP_OF_SPOT)

    assert_equal 70 + SessionPrecedence::SLOT_GAP, session.reload.precedence
  end

  # The semantics every door shares: `Session#precedence_for_place`, floored at
  # the rank the session holds. Resolving against the queue alone would rewrite
  # 1000 down to 15 here.
  test "top_of_spot never lowers a rank that is already above the head of the queue" do
    spot(10)
    session = priority(precedence: 1000, status: :needs_input)

    result = Sessions::UpdateSchedulingClass.call(session: session, scheduling_class: "spot", actor: :web,
      place: SessionPrecedence::PLACE_TOP_OF_SPOT)

    assert_equal 1000, session.reload.precedence
    assert_not result.precedence_changed?
    assert_equal [ "Scheduling class set to spot (was priority)" ], log_contents(session)
  end

  test "top_of_spot does not measure the session against itself" do
    spot(40)
    session = spot(45, status: :needs_input)

    Sessions::UpdateSchedulingClass.call(session: session, scheduling_class: "spot", actor: :mcp,
      place: SessionPrecedence::PLACE_TOP_OF_SPOT)

    assert_equal 45, session.reload.precedence, "already first, so re-placing it is a no-op"
  end

  test "place and precedence together are refused" do
    session = priority(status: :needs_input)

    assert_raises(ArgumentError) do
      Sessions::UpdateSchedulingClass.call(session: session, scheduling_class: "spot", actor: :mcp,
        precedence: 5, place: SessionPrecedence::PLACE_TOP_OF_SPOT)
    end
    assert_equal SessionGenesis::PRIORITY, session.reload.scheduling_class
  end

  # --- the start --------------------------------------------------------------

  test "promoting a waiting session starts it, named by the actor" do
    session = spot(10)

    result = nil
    assert_enqueued_with(job: AgentSessionJob, args: [ session.id ]) do
      result = Sessions::UpdateSchedulingClass.call(session: session, scheduling_class: "priority", actor: :rest)
    end

    assert_equal :started, result.start.outcome
    assert session.logs.where("content LIKE ?", "%Started now by the REST API promoting it%").exists?
  end

  test "a demotion starts nothing" do
    session = priority

    result = nil
    assert_no_enqueued_jobs(only: AgentSessionJob) do
      result = Sessions::UpdateSchedulingClass.call(session: session, scheduling_class: "spot", actor: :web)
    end
    assert_nil result.start
  end

  test "re-saving a priority session does not restart it" do
    session = priority

    assert_no_enqueued_jobs(only: AgentSessionJob) do
      assert_nil Sessions::UpdateSchedulingClass.call(session: session, scheduling_class: "priority", actor: :web).start
    end
  end

  test "promoting a session that is not waiting starts nothing" do
    session = spot(10, status: :needs_input)

    assert_nil Sessions::UpdateSchedulingClass.call(session: session, scheduling_class: "priority", actor: :mcp).start
  end

  test "a stranded session is left alone and the result says so" do
    session = spot(10, session_id: "cli-abc")

    result = Sessions::UpdateSchedulingClass.call(session: session, scheduling_class: "priority", actor: :web)

    assert result.start.nothing_queued?
  end

  test "assigned attributes ride the same save" do
    session = spot(10, status: :needs_input)
    session.assign_attributes(goal: "Ship it")

    Sessions::UpdateSchedulingClass.call(session: session, scheduling_class: "priority", actor: :rest)

    assert_equal "Ship it", session.reload.goal
    assert session.priority?
  end

  test "start: false defers the start to start_if_promoted" do
    session = spot(10)

    result = nil
    assert_no_enqueued_jobs(only: AgentSessionJob) do
      result = Sessions::UpdateSchedulingClass.call(session: session, scheduling_class: "priority", actor: :rest, start: false)
    end
    assert_nil result.start
    assert session.reload.priority?

    assert_enqueued_with(job: AgentSessionJob, args: [ session.id ]) do
      assert_equal :started, Sessions::UpdateSchedulingClass.start_if_promoted(result).outcome
    end
  end
end
