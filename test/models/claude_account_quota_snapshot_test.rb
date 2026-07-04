# frozen_string_literal: true

require "test_helper"

class ClaudeAccountQuotaSnapshotTest < ActiveSupport::TestCase
  test "belongs to claude_account" do
    snapshot = claude_account_quota_snapshots(:primary_recent)
    assert_equal claude_accounts(:primary), snapshot.claude_account
  end

  test "validates claude_account presence" do
    snapshot = ClaudeAccountQuotaSnapshot.new(claude_account: nil)
    assert_not snapshot.valid?
    assert_includes snapshot.errors[:claude_account], "must exist"
  end

  test "to_display_hash returns expected keys" do
    snapshot = claude_account_quota_snapshots(:primary_recent)
    display = snapshot.to_display_hash
    assert_kind_of Hash, display
    assert display.key?(:subscription_type)
    assert display.key?(:utilization_5h)
    assert display.key?(:utilization_7d)
  end
end
