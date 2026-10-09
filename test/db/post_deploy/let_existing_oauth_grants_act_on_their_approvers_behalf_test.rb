# frozen_string_literal: true

require "test_helper"

# Connections approved before privilege levels existed start as "acts on my
# behalf"; one approved since keeps the level its approver chose.
class LetExistingOauthGrantsActOnTheirApproversBehalfTest < ActiveSupport::TestCase
  setup do
    @entry = PostDeployTask::Registry.find("20261009220500")
    assert @entry, "the task file must ship in db/post_deploy"
    @task_class = @entry.task_class
  end

  def grant(scope: OauthServer::SCOPE, scope_changed_at: nil, scope_change_reason: nil, revoked: false)
    client = OauthServer::Client.create!(client_id: "dcr-#{SecureRandom.hex(8)}", registration_type: OauthServer::Client::DCR,
      client_name: "Claude", redirect_uris: [ "https://claude.ai/api/mcp/auth_callback" ])
    OauthServer::Grant.create!(client: client, user_email: "tadas@tadasant.com", resource: "http://www.example.com/mcp",
      scope: scope, scope_changed_at: scope_changed_at, scope_change_reason: scope_change_reason,
      revoked_at: (Time.current if revoked))
  end

  def run_task
    run = PostDeployTaskRun.ledger_for(@entry)
    run.claim!(owner: "test")
    @task_class.new(run: run, logger: Rails.logger).up
    run.reload
  end

  test "raises live pre-existing grants, and leaves chosen and revoked ones alone" do
    legacy = grant
    chosen_relay = grant(scope_changed_at: 1.minute.ago, scope_change_reason: "consent")
    revoked = grant(revoked: true)

    run = run_task

    assert_predicate legacy.reload, :acts_as_human?
    assert_equal "backfill", legacy.scope_change_reason
    assert_equal "mcp", chosen_relay.reload.scope, "a level chosen at consent is the approver's, not the backfill's"
    assert_equal "mcp", revoked.reload.scope
    assert_equal 1, run.stats["raised"]
    assert_equal [ legacy.id ], run.stats["raised_grant_ids"]
  end

  test "a second run changes nothing" do
    legacy = grant
    run_task
    stamped_at = legacy.reload.scope_changed_at

    second = run_task

    assert_equal stamped_at, legacy.reload.scope_changed_at
    assert_equal [], second.stats["raised_grant_ids"]
  end
end
