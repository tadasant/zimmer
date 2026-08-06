# frozen_string_literal: true

require "test_helper"

class AccountRotationEventTest < ActiveSupport::TestCase
  test "valid with required attributes" do
    event = AccountRotationEvent.new(
      rotated_from: claude_accounts(:primary),
      rotated_to: claude_accounts(:secondary),
      reason: "quota_exceeded",
      source: "automatic"
    )
    assert event.valid?
  end

  test "valid without rotated_from (initial setup)" do
    event = AccountRotationEvent.new(
      rotated_from: nil,
      rotated_to: claude_accounts(:secondary),
      reason: "quota_exceeded",
      source: "automatic"
    )
    assert event.valid?
  end

  test "invalid without source" do
    event = AccountRotationEvent.new(
      rotated_to: claude_accounts(:secondary),
      source: nil
    )
    assert_not event.valid?
    assert_includes event.errors[:source], "can't be blank"
  end

  test "invalid with unknown source" do
    event = AccountRotationEvent.new(
      rotated_to: claude_accounts(:secondary),
      source: "unknown"
    )
    assert_not event.valid?
    assert_includes event.errors[:source], "is not included in the list"
  end

  test "source must be automatic or manual" do
    %w[automatic manual].each do |valid_source|
      event = AccountRotationEvent.new(
        rotated_to: claude_accounts(:secondary),
        source: valid_source
      )
      assert event.valid?, "Expected source '#{valid_source}' to be valid"
    end
  end

  test "invalid without rotated_to on create" do
    event = AccountRotationEvent.new(
      rotated_from: claude_accounts(:primary),
      source: "automatic"
    )
    assert_not event.valid?
    assert_includes event.errors[:rotated_to], "can't be blank"
  end

  test "an existing event stays valid once its target account is deleted" do
    event = AccountRotationEvent.create!(
      rotated_to: claude_accounts(:secondary),
      source: "automatic"
    )
    event.rotated_to = nil

    assert event.valid?, "nullifying the target on delete must not strand an unsaveable row"
  end

  test "captures both account identities and the runtime at write time" do
    event = AccountRotationEvent.create!(
      rotated_from: claude_accounts(:primary),
      rotated_to: claude_accounts(:secondary),
      source: "automatic"
    )

    assert_equal claude_accounts(:primary).email, event.rotated_from_email
    assert_equal claude_accounts(:secondary).email, event.rotated_to_email
    assert_equal "claude_code", event.runtime
  end

  test "captures the runtime of a codex rotation" do
    event = AccountRotationEvent.create!(
      rotated_to: claude_accounts(:codex_secondary),
      source: "manual"
    )

    assert_equal "codex", event.runtime
  end

  test "an explicitly supplied source email survives capture" do
    # QuotasController#destroy_account names an account it has already deleted,
    # so there is no association left to read the email from.
    event = AccountRotationEvent.create!(
      rotated_from: nil,
      rotated_from_email: "gone@example.com",
      rotated_to: claude_accounts(:secondary),
      reason: "deleted_current_account",
      source: "manual"
    )

    assert_equal "gone@example.com", event.from_email
    assert event.from_deleted?
  end

  test "for_runtime filters on the event's own runtime column" do
    claude_event = AccountRotationEvent.create!(rotated_to: claude_accounts(:secondary), source: "manual")
    codex_event = AccountRotationEvent.create!(rotated_to: claude_accounts(:codex_secondary), source: "manual")

    assert_includes AccountRotationEvent.for_runtime("claude_code"), claude_event
    assert_not_includes AccountRotationEvent.for_runtime("claude_code"), codex_event
  end

  test "recent scope returns most recent 50 events ordered by created_at desc" do
    older = AccountRotationEvent.create!(
      rotated_to: claude_accounts(:primary),
      source: "automatic",
      reason: "quota_exceeded",
      created_at: 2.hours.ago
    )
    newer = AccountRotationEvent.create!(
      rotated_to: claude_accounts(:secondary),
      source: "manual",
      reason: "manual_switch",
      created_at: 1.hour.ago
    )

    recent = AccountRotationEvent.recent
    assert_equal newer, recent.first
    assert_equal older, recent.second
  end

  test "belongs_to rotated_from and rotated_to" do
    event = AccountRotationEvent.create!(
      rotated_from: claude_accounts(:primary),
      rotated_to: claude_accounts(:secondary),
      reason: "quota_exceeded",
      source: "automatic"
    )

    assert_equal claude_accounts(:primary), event.rotated_from
    assert_equal claude_accounts(:secondary), event.rotated_to
  end
end
