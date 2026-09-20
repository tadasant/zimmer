# frozen_string_literal: true

require "test_helper"

# The Force affordance on the queued-for-a-worker banner, end to end: what the
# page offers, what it says when there is nothing to offer, and what the POST
# behind it actually does.
class SessionsControllerForceStartTest < ActionDispatch::IntegrationTest
  SLOTS = 2

  setup do
    GoodJob::Process.delete_all
    GoodJob::Job.delete_all
    @capsule = GoodJob::Process.create!(state: { "hostname" => "worker-1" })
  end

  teardown do
    GoodJob::Job.delete_all
    GoodJob::Process.delete_all
  end

  def with_pool(&block) = RunningTurns.stub(:worker_slots, SLOTS, &block)

  def session_in(status, **attrs)
    Session.create!({
      git_root: "https://github.com/t/r.git", prompt: "work", status: status,
      session_id: "cli-#{SecureRandom.hex(4)}", genesis: SessionGenesis::WEB_UI
    }.merge(attrs))
  end

  def turn_on_a_worker(session, started: 1.minute.ago)
    GoodJob::Job.create!(
      queue_name: "agents", job_class: "AgentSessionJob", active_job_id: SecureRandom.uuid,
      serialized_params: { "job_class" => "AgentSessionJob", "arguments" => [ session.id ] },
      performed_at: started, locked_at: started, locked_by_id: @capsule.id
    )
  end

  def queued_turn(session)
    GoodJob::Job.create!(
      queue_name: "agents", job_class: "AgentSessionJob", active_job_id: SecureRandom.uuid,
      serialized_params: { "job_class" => "AgentSessionJob", "arguments" => [ session.id ] },
      created_at: 30.seconds.ago
    )
  end

  def saturate(count: SLOTS)
    count.times.map do |i|
      victim = session_in(:running)
      turn_on_a_worker(victim, started: (count - i).minutes.ago)
      victim
    end
  end

  def queued_session
    session = session_in(:waiting)
    queued_turn(session)
    session
  end

  # --- what the banner offers -------------------------------------------------

  test "the banner offers Force, and names the turn it would stop" do
    _oldest, newest = saturate
    session = queued_session

    with_pool { get session_path(session) }

    assert_response :success
    assert_select "[data-queued-turn-banner]"
    assert_select "form[action=?]", force_start_session_path(session)
    assert_select "[data-queued-turn-force-cost]", /session ##{newest.id}/
    # The confirmed victim rides along, so a pick that changes is refused.
    assert_select "form[action=?] input[name=expected_victim_id][value=?]",
      force_start_session_path(session), newest.id.to_s
  end

  test "the confirmation says what is about to be killed" do
    _oldest, newest = saturate
    session = queued_session

    with_pool { get session_path(session) }

    form = response.body[/<form[^>]*action="#{Regexp.escape(force_start_session_path(session))}"[^>]*>/]
    assert form, "the Force form should be on the page"
    assert_match(/data-turbo-confirm=/, form)
    assert_match(/Stop session ##{newest.id}/, CGI.unescapeHTML(form))
    assert_match(/tool call it is in the middle of is lost/, CGI.unescapeHTML(form))
  end

  test "no eligible victim means a sentence instead of a button that does nothing" do
    turn_on_a_worker(session_in(:running))
    session = queued_session

    with_pool { get session_path(session) }

    assert_response :success
    assert_select "[data-queued-turn-banner]"
    assert_select "form[action=?]", force_start_session_path(session), count: 0
    assert_select "[data-queued-turn-force-unavailable]", /Nothing to force/
  end

  test "a session that is not queued for a worker gets no banner and no button" do
    saturate
    session = session_in(:waiting)

    with_pool { get session_path(session) }

    assert_response :success
    assert_select "[data-queued-turn-banner]", count: 0
    assert_select "form[action=?]", force_start_session_path(session), count: 0
  end

  # --- the POST ---------------------------------------------------------------

  test "Force stops the newest turn, re-queues it, and says so" do
    _oldest, newest = saturate
    session = queued_session

    with_pool do
      assert_enqueued_with(job: AgentSessionJob) do
        post force_start_session_path(session)
      end
    end

    assert_redirected_to session_path(session)
    assert_match(/Session #{newest.id}'s turn was stopped and put back in the queue/, flash[:notice])
    assert newest.reload.waiting?
    assert_equal session.id, newest.metadata[Sessions::ForceTurnStart::FORCED_FOR_SESSION]
  end

  test "Force refuses when the turn the person confirmed is no longer the one that would be stopped" do
    _oldest, newest = saturate
    session = queued_session

    with_pool do
      assert_no_enqueued_jobs(only: AgentSessionJob) do
        post force_start_session_path(session), params: { expected_victim_id: 424_242 }
      end
    end

    assert_match(/no longer the one that would be stopped/, flash[:alert])
    assert newest.reload.running?
  end

  test "Force reports the honest refusal rather than pretending" do
    turn_on_a_worker(session_in(:running))
    session = queued_session

    with_pool do
      assert_no_enqueued_jobs(only: AgentSessionJob) do
        post force_start_session_path(session)
      end
    end

    assert_match(/Nothing to force/, flash[:alert])
    assert_nil flash[:notice]
  end

  test "Force refuses a session that is not waiting on a worker at all" do
    saturate
    session = session_in(:running)

    with_pool { post force_start_session_path(session) }

    assert_match(/only a session queued for a worker can be forced/, flash[:alert])
  end
end
