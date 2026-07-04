# frozen_string_literal: true

require "test_helper"

class HooksConfigTest < ActiveSupport::TestCase
  setup do
    HooksConfig.reload!
  end

  test "loads hooks from config file" do
    hooks = HooksConfig.all

    assert hooks.is_a?(Array)
    assert hooks.size > 0
    assert hooks.all? { |hook| hook.is_a?(HooksConfig::Hook) }
  end

  test "finds hook by name" do
    hook = HooksConfig.find("git-push-ci-reminder")

    assert_not_nil hook
    assert_equal "git-push-ci-reminder", hook.name
    assert_equal "Git Push CI Reminder", hook.title
  end

  test "returns nil for non-existent hook" do
    hook = HooksConfig.find("non-existent")

    assert_nil hook
  end

  test "finds hook by name with bang" do
    hook = HooksConfig.find!("git-push-ci-reminder")

    assert_not_nil hook
    assert_equal "git-push-ci-reminder", hook.name
  end

  test "raises error for non-existent hook with bang" do
    assert_raises(HooksConfig::HookNotFoundError) do
      HooksConfig.find!("non-existent")
    end
  end

  test "returns list of hook names" do
    names = HooksConfig.names

    assert names.is_a?(Array)
    assert names.size > 0
    assert names.all? { |name| name.is_a?(String) }
    assert_includes names, "git-push-ci-reminder"
  end

  test "checks if hook exists" do
    assert HooksConfig.exists?("git-push-ci-reminder")
    refute HooksConfig.exists?("non-existent")
  end

  test "hook has correct attributes" do
    hook = HooksConfig.find("git-push-ci-reminder")

    assert_equal "git-push-ci-reminder", hook.name
    assert_equal "git-push-ci-reminder", hook.id
    assert_equal "Git Push CI Reminder", hook.title
    assert hook.description.present?
    assert hook.path.end_with?("git-push-ci-reminder"),
      "expected hook.path to end with 'git-push-ci-reminder', got #{hook.path.inspect}"
    assert_equal hook.path, hook.absolute_path
  end

  test "hook converts to hash" do
    hook = HooksConfig.find("git-push-ci-reminder")
    hash = hook.to_h

    assert_equal "git-push-ci-reminder", hash[:id]
    assert_equal "git-push-ci-reminder", hash[:name]
    assert_equal "Git Push CI Reminder", hash[:title]
    assert hash[:description].present?
  end

  test "hook converts to json" do
    hook = HooksConfig.find("git-push-ci-reminder")
    json = JSON.parse(hook.to_json)

    assert_equal "git-push-ci-reminder", json["name"]
    assert_equal "Git Push CI Reminder", json["title"]
  end

  test "reloads configuration" do
    initial_hooks = HooksConfig.all

    reloaded_hooks = HooksConfig.reload!

    assert_equal initial_hooks.size, reloaded_hooks.size
  end

  # TTL/cache invalidation lives in AirCatalogService and is exercised in
  # AirCatalogServiceTest. HooksConfig only delegates.
end
