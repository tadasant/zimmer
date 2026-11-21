# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Revoke-at-rest: which transitions count as a turn coming to rest, the job's
# re-check, and the sweep's backstop.
class BrokeredTokenRevocationTest < ActiveSupport::TestCase
  include TokenBrokerTestHelpers
  include ActiveJob::TestHelper

  setup do
    @strad = FakeStrad.new
    client = @strad.client
    TokenBroker::Client.stubs(:new).returns(client)
    stub_mcp_catalog("image-diff" => brokered_strad_entry("image-diff"))
    @session = create_session(status: :running)
  end

  def mint!
    with_oauth_client_identity do
      @strad.create_grant! unless McpBrokerGrant.exists?
      TokenBroker.mint_for_session(@session, %w[image-diff])
    end
  end

  def revoke_jobs = enqueued_jobs.select { |job| job["job_class"] == "TokenBrokerRevokeJob" }

  test "every rest enqueues a revocation" do
    %i[pause fail archive].each do |event|
      session = create_session(status: :running)
      @session = session
      mint!
      clear_enqueued_jobs

      session.public_send(:"#{event}!")

      assert_equal 1, revoke_jobs.size, "#{event} is a rest"
    end
  end

  test "going to sleep from running is a rest; becoming waiting from elsewhere is not" do
    mint!
    @session.update!(status: :needs_input)
    clear_enqueued_jobs

    @session.sleep!
    assert_empty revoke_jobs, "needs_input → waiting happens before a turn's own spawn"

    @session.update!(status: :running)
    clear_enqueued_jobs
    @session.update!(status: :waiting)
    assert_equal 1, revoke_jobs.size
  end

  test "an elicitation block is not a rest: the process is alive and waiting on a human" do
    mint!
    clear_enqueued_jobs

    @session.merge_metadata!("blocked_on_elicitation" => true)
    @session.block_on_elicitation!

    assert_empty revoke_jobs
  end

  test "a session with no live brokered token enqueues nothing" do
    @session.pause!
    assert_empty revoke_jobs
  end

  test "the job revokes the children minted before the rest" do
    token = mint!.tokens["image-diff"]
    @session.update!(status: :needs_input)

    with_oauth_client_identity do
      TokenBrokerRevokeJob.perform_now(@session.id, Time.current.iso8601(6))
    end

    assert_equal [ token ], @strad.revoked
    assert_equal "revoked", McpBrokeredToken.sole.state
  end

  test "the job leaves a token alone when the session is running again by the time it runs" do
    mint!
    rested_at = Time.current.iso8601(6)
    @session.update!(status: :running)

    with_oauth_client_identity { TokenBrokerRevokeJob.perform_now(@session.id, rested_at) }

    assert_empty @strad.revoked
    assert_equal "live", McpBrokeredToken.sole.state
  end

  test "the sweep revokes a child left live at rest, after the grace, and spares a running session's" do
    mint!
    resting = @session
    resting.update_columns(status: Session.statuses[:needs_input])
    running = create_session(status: :running)
    @session = running
    mint!

    travel TokenBroker::SWEEP_GRACE + 1.minute
    with_oauth_client_identity { TokenBrokerSweepJob.perform_now }

    assert_equal "revoked", McpBrokeredToken.find_by(session_id: resting.id).state
    assert_equal "live", McpBrokeredToken.find_by(session_id: running.id).state
  end

  test "the sweep returns at once when the broker was never used" do
    McpBrokeredToken.expects(:live).never
    TokenBrokerSweepJob.perform_now
  end

  test "the sweep deletes week-old closed rows" do
    mint!
    McpBrokeredToken.update_all(state: "revoked", updated_at: 8.days.ago)

    TokenBrokerSweepJob.perform_now

    assert_equal 0, McpBrokeredToken.count
  end
end
