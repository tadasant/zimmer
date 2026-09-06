# frozen_string_literal: true

require "test_helper"

# A human speaking to a spot session takes it to the head of the spot queue and
# gets its next turn moving, and sends the least human-involved queued session to
# the bottom in exchange.
#
# The two properties worth most here are the ones that would be expensive to get
# wrong: only a REAL human moves anything (a router's follow-up records no
# HumanMessage and so cannot reach this at all), and the demotion refuses more
# often than it fires — no candidate, nobody less involved, or a session old
# enough to be exempt all end in demoting nobody.
class Sessions::HumanInterventionPromotionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    Session.delete_all
    @setting = AppSetting.editable
    @setting.update!(spot_gating_enabled: true)
  end

  def spot_session(precedence: 0, status: :waiting, created_at: 1.hour.ago, metadata: {})
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "work",
                    genesis: SessionGenesis::GITHUB_ISSUE, scheduling_class: SessionGenesis::SPOT,
                    precedence: precedence, status: status, agent_runtime: "claude_code",
                    created_at: created_at, metadata: metadata)
  end

  # A record of a named human speaking to `session`. `entry_point` is the whole
  # discriminator: HumanMessageCapture writes one only for an established actor
  # at an input boundary, so this is what an agent's follow-up cannot produce.
  def human_message(session, entry_point: "web_ui.follow_up", occurred_at: Time.current)
    HumanMessage.create!(session: session, author: "tadasant", channel: HumanMessage::WEB_UI,
                         content: "have another look at this", occurred_at: occurred_at,
                         provenance: { "entry_point" => entry_point })
  end

  # The promotion pulls a queued turn forward, and a session with nothing queued
  # takes the enqueue branch. Neither is what these tests are about, so they run
  # inside the ActiveJob test adapter and assert on the placement.

  # === The promotion ===

  test "a human message takes a spot session to the head of the queue" do
    top = spot_session(precedence: 500)
    session = spot_session(precedence: 0)

    result = Sessions::HumanInterventionPromotion.call(human_message(session))

    assert result.acted?
    assert_operator session.reload.precedence, :>, top.precedence
    assert_equal session.precedence, result.precedence
  end

  test "a session already at the head keeps its number rather than walking up" do
    session = spot_session(precedence: 1000)
    spot_session(precedence: 10)

    Sessions::HumanInterventionPromotion.call(human_message(session))
    Sessions::HumanInterventionPromotion.call(human_message(session))

    assert_equal 1000, session.reload.precedence
  end

  test "the promotion brings the session's next turn forward" do
    session = spot_session
    spot_session
    calls = []
    Sessions::StartNow.stub(:call, lambda { |s, **|
      calls << s.id
      Sessions::StartNow::Result.new(outcome: :started, message: "started")
    }) do
      assert_equal true, Sessions::HumanInterventionPromotion.call(human_message(session)).started
    end

    assert_equal [ session.id ], calls, "landing the rank alone is zimmer#423"
  end

  test "a running session is promoted but nothing is started under it" do
    session = spot_session(status: :running)
    spot_session

    Sessions::StartNow.stub(:call, ->(*) { flunk("a running session has a turn already") }) do
      result = Sessions::HumanInterventionPromotion.call(human_message(session))
      assert_nil result.started
    end
  end

  # === What is not an intervention ===

  test "a priority session is left alone" do
    session = Session.create!(git_root: "https://github.com/t/r.git", prompt: "work",
                              genesis: SessionGenesis::GITHUB_ISSUE,
                              scheduling_class: SessionGenesis::PRIORITY,
                              precedence: 0, status: :waiting, agent_runtime: "claude_code")
    spot_session(precedence: 500)

    refute Sessions::HumanInterventionPromotion.call(human_message(session)).acted?
    assert_equal 0, session.reload.precedence
  end

  test "creating a session is not intervening in one" do
    session = spot_session
    spot_session(precedence: 500)

    Sessions::HumanInterventionPromotion::CREATION_ENTRY_POINTS.each do |entry_point|
      refute Sessions::HumanInterventionPromotion.call(
        human_message(session, entry_point: entry_point)
      ).acted?, entry_point
    end
    assert_equal 0, session.reload.precedence
  end

  test "an archived session is left alone" do
    session = spot_session
    session.update!(status: :archived)

    refute Sessions::HumanInterventionPromotion.call(human_message(session)).acted?
  end

  # === The exchange ===

  test "the least human-involved queued session goes to the bottom" do
    session = spot_session(precedence: 0)
    # Above `involved`, so demoting it actually moves it: a session that is
    # already the lowest in the queue is left where it is (its own test below).
    bottom = spot_session(precedence: 30)
    involved = spot_session(precedence: 20)
    human_message(involved)
    human_message(involved)

    result = Sessions::HumanInterventionPromotion.call(human_message(session))

    assert_equal bottom.id, result.demoted&.id
    assert_operator bottom.reload.precedence, :<, involved.reload.precedence
    assert_equal 1, bottom.metadata[Sessions::HumanInterventionPromotion::DEMOTED_COUNT]
  end

  test "between two equally-uninvolved sessions the one spoken to longest ago goes" do
    session = spot_session
    stale = spot_session(precedence: 30)
    recent = spot_session(precedence: 20)
    human_message(session)
    human_message(session)
    human_message(stale, occurred_at: 30.days.ago)
    human_message(recent, occurred_at: 1.minute.ago)

    result = Sessions::HumanInterventionPromotion.call(human_message(session))

    assert_equal stale.id, result.demoted&.id
  end

  test "nobody is demoted when no queued session is less involved" do
    session = spot_session
    peer = spot_session(precedence: 10)
    human_message(peer)

    # The promoted session's own count is 1 after the triggering message, and the
    # peer's is 1 too — a candidate has to be STRICTLY below.
    result = Sessions::HumanInterventionPromotion.call(human_message(session))

    assert result.acted?
    assert_nil result.demoted
    assert_equal 10, peer.reload.precedence
  end

  test "a session queued longer than the starvation exemption is never demoted" do
    session = spot_session
    old = spot_session(precedence: 10,
                       created_at: Sessions::HumanInterventionPromotion::STARVATION_EXEMPTION.ago - 1.hour)

    result = Sessions::HumanInterventionPromotion.call(human_message(session))

    assert result.acted?
    assert_nil result.demoted, "an unattended session sinks only until it is a day old"
    assert_equal 10, old.reload.precedence
  end

  test "a running session is not a demotion candidate" do
    session = spot_session
    runner = spot_session(precedence: 10, status: :running)

    result = Sessions::HumanInterventionPromotion.call(human_message(session))

    assert_nil result.demoted
    assert_equal 10, runner.reload.precedence
  end

  test "nobody is demoted when the promoted session is the whole queue" do
    session = spot_session

    result = Sessions::HumanInterventionPromotion.call(human_message(session))

    assert result.acted?
    assert_nil result.demoted
  end

  test "a session already at the bottom is not walked further down" do
    session = spot_session(precedence: 100)
    bottom = spot_session(precedence: -50)
    middle = spot_session(precedence: 0)
    human_message(middle)

    result = Sessions::HumanInterventionPromotion.call(human_message(session))

    # `bottom` is the least involved AND already the lowest, so the order it
    # would land on is the order it already has.
    assert_nil result.demoted
    assert_equal(-50, bottom.reload.precedence)
  end

  test "the demoted session keeps its turn, its record and its class" do
    session = spot_session
    victim = spot_session(precedence: 10, metadata: {
      SpotSessionPause::PAUSED_REASON => SpotSessionPause::QUEUED_REASON,
      SpotSessionPause::PAUSED_DETAIL => "parked deliberately"
    })

    Sessions::HumanInterventionPromotion.call(human_message(session))

    victim.reload
    assert victim.waiting?
    assert_equal SpotSessionPause::QUEUED_REASON, victim.metadata[SpotSessionPause::PAUSED_REASON]
    assert victim.spot?
  end

  # === The trigger ===

  test "recording a human message enqueues the promotion job" do
    session = spot_session

    assert_enqueued_with(job: HumanInterventionPromotionJob) do
      human_message(session)
    end
  end

  test "the job is a no-op for a message whose session has gone" do
    session = spot_session
    message = human_message(session)
    id = message.id
    session.destroy!

    assert_nothing_raised { HumanInterventionPromotionJob.new.perform(id) }
  end

  test "a failure inside the exchange leaves the human's message delivered" do
    session = spot_session
    spot_session(precedence: 10)

    Sessions::StartNow.stub(:call, ->(*) { raise ActiveRecord::StatementInvalid, "boom" }) do
      result = Sessions::HumanInterventionPromotion.call(human_message(session))
      assert result.acted?, "the promotion still landed"
      assert_nil result.started
    end
  end
end
