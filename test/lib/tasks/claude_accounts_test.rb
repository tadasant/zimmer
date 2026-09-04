# frozen_string_literal: true

require "test_helper"
require "rake"

class ClaudeAccountsTasksTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  teardown do
    Rake::Task.clear
  end

  # claude_accounts:add

  test "add creates a new account with email and priority" do
    email = "newuser-#{SecureRandom.hex(4)}@example.com"

    output = capture_io do
      Rake::Task["claude_accounts:add"].reenable
      Rake::Task["claude_accounts:add"].invoke(email, "3")
    end.first

    account = ClaudeAccount.find_by(email: email)
    assert_not_nil account
    assert_equal 3, account.priority
    assert_match(/Added account #{email}/, output)
  ensure
    ClaudeAccount.find_by(email: email)&.destroy
  end

  test "add defaults priority to 0" do
    email = "defaultpri-#{SecureRandom.hex(4)}@example.com"

    capture_io do
      Rake::Task["claude_accounts:add"].reenable
      Rake::Task["claude_accounts:add"].invoke(email)
    end

    account = ClaudeAccount.find_by(email: email)
    assert_not_nil account
    assert_equal 0, account.priority
  ensure
    ClaudeAccount.find_by(email: email)&.destroy
  end

  test "add updates priority on existing account" do
    account = claude_accounts(:secondary)
    original_priority = account.priority

    output = capture_io do
      Rake::Task["claude_accounts:add"].reenable
      Rake::Task["claude_accounts:add"].invoke(account.email, "99")
    end.first

    account.reload
    assert_equal 99, account.priority
    assert_match(/Updated existing account/, output)

    # Restore
    account.update!(priority: original_priority)
  end

  # The task no longer reads `~/.claude/.credentials.json` to decide whether the
  # new row already has credentials. Whose tokens sit on a file three writers
  # share is not evidence, and under session-scoped credentials there is nothing
  # in that file to read. See issue #618.
  test "add points a credential-less account at the Authenticate button" do
    email = "needs-auth-#{SecureRandom.hex(4)}@example.com"

    output = capture_io do
      Rake::Task["claude_accounts:add"].reenable
      Rake::Task["claude_accounts:add"].invoke(email, "0")
    end.first

    assert_equal({}, ClaudeAccount.find_by(email: email).oauth_config)
    assert_match(%r{open /inference and click Authenticate}, output)
    assert_no_match(/filesystem/i, output)
  ensure
    ClaudeAccount.find_by(email: email)&.destroy
  end

  # claude_accounts:remove

  test "remove deletes a non-current account" do
    account = ClaudeAccount.create!(email: "removable-#{SecureRandom.hex(4)}@example.com", priority: 99)

    output = capture_io do
      Rake::Task["claude_accounts:remove"].reenable
      Rake::Task["claude_accounts:remove"].invoke(account.email)
    end.first

    assert_nil ClaudeAccount.find_by(email: account.email)
    assert_match(/Removed account/, output)
  end

  test "remove refuses to delete the current active account" do
    current = claude_accounts(:primary)
    assert current.is_current?

    error = assert_raises(SystemExit) do
      capture_io do
        Rake::Task["claude_accounts:remove"].reenable
        Rake::Task["claude_accounts:remove"].invoke(current.email)
      end
    end

    assert_equal 1, error.status
    assert_not_nil ClaudeAccount.find_by(email: current.email)
  end

  test "remove aborts for unknown email" do
    error = assert_raises(SystemExit) do
      capture_io do
        Rake::Task["claude_accounts:remove"].reenable
        Rake::Task["claude_accounts:remove"].invoke("nonexistent@example.com")
      end
    end

    assert_equal 1, error.status
  end

  # claude_accounts:list

  test "list shows all accounts ordered by priority" do
    output = capture_io do
      Rake::Task["claude_accounts:list"].reenable
      Rake::Task["claude_accounts:list"].invoke
    end.first

    assert_match(/Claude Accounts/, output)
    assert_match(/tadas@tadasant.com/, output)
    assert_match(/\[CURRENT\]/, output)
  end

  test "list shows empty message when no accounts" do
    # Temporarily remove all accounts
    saved = ClaudeAccount.all.map(&:attributes)
    ClaudeAccount.destroy_all

    output = capture_io do
      Rake::Task["claude_accounts:list"].reenable
      Rake::Task["claude_accounts:list"].invoke
    end.first

    assert_match(/No Claude accounts configured/, output)

    # Restore accounts
    saved.each do |attrs|
      ClaudeAccount.create!(attrs.except("id", "created_at", "updated_at"))
    end
  end
end
