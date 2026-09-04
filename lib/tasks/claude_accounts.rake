# frozen_string_literal: true

namespace :claude_accounts do
  desc "Add a Claude account to the rotation pool. Usage: bin/rails 'claude_accounts:add[email@example.com,0]'"
  task :add, [ :email, :priority ] => :environment do |_t, args|
    email = args[:email]
    priority = args[:priority]&.to_i || 0
    abort "Usage: bin/rails 'claude_accounts:add[email@example.com,0]'" unless email.present?

    # Scope by runtime: email is unique per-runtime, so the same email may also
    # hold a separate Codex account. We look up / create only within the Claude
    # Code pool, never touching another runtime's row.
    account = ClaudeAccount.for_runtime(ClaudeAuthProvider::RUNTIME).find_or_initialize_by(email: email)

    if account.persisted?
      account.update!(priority: priority)
      puts "Updated existing account #{email} (priority: #{priority})"
    else
      account.priority = priority
      account.save!
      puts "Added account #{email} (priority: #{priority})"
    end

    # A row with no credentials cannot serve a session, and the way to give it
    # some is the Authenticate button on /inference: it drives an interactive login
    # in a scratch dir and writes the tokens straight to this row.
    #
    # This task used to capture them off `~/.claude/.credentials.json` when that
    # file happened to name the same address. It no longer does. Reading whose
    # tokens are on a shared file that Zimmer, the CLI and any operator all write
    # is the second-source-of-truth problem the credential rearchitecture removes
    # — and under session-scoped credentials there is nothing in that file to
    # read. See https://github.com/tadasant/zimmer/issues/618.
    puts "Next: open /inference and click Authenticate on #{email} to give it credentials." unless account.has_valid_config?
  end

  desc "Remove a Claude account from the rotation pool. Usage: bin/rails 'claude_accounts:remove[email@example.com]'"
  task :remove, [ :email ] => :environment do |_t, args|
    email = args[:email]
    abort "Usage: bin/rails 'claude_accounts:remove[email@example.com]'" unless email.present?

    account = ClaudeAccount.for_runtime(ClaudeAuthProvider::RUNTIME).find_by(email: email)
    abort "No ClaudeAccount found with email: #{email}" unless account

    if account.is_current?
      abort "Cannot remove the current active account (#{email}). Switch to another account first."
    end

    account.destroy!
    puts "Removed account #{email}"
  end

  desc "Remove ALL Claude accounts and their history. Usage: bin/rails claude_accounts:clear_all"
  task clear_all: :environment do
    # Scoped to Claude Code so it never touches Codex accounts in the shared pool.
    runtime = ClaudeAuthProvider::RUNTIME
    claude_ids = ClaudeAccount.for_runtime(runtime).pluck(:id)
    account_count = claude_ids.size

    # Each scope covers two populations: rows still attached to an account, and
    # rows an earlier single-account delete detached, which carry no foreign key
    # and are found by the runtime denormalized onto them. This task is the only
    # path that removes the second kind — /inference deliberately preserves it and
    # nothing prunes quota snapshots — so a "start over" that left it behind would
    # not be a start over.
    event_scope = AccountRotationEvent
      .where(rotated_from_id: claude_ids)
      .or(AccountRotationEvent.where(rotated_to_id: claude_ids))
      .or(AccountRotationEvent.where(rotated_from_id: nil, rotated_to_id: nil, runtime: runtime))
    snapshot_scope = ClaudeAccountQuotaSnapshot
      .where(claude_account_id: claude_ids)
      .or(ClaudeAccountQuotaSnapshot.where(claude_account_id: nil, account_runtime: runtime))
    attempt_scope = RuntimeLoginAttempt
      .where(claude_account_id: claude_ids)
      .or(RuntimeLoginAttempt.where(claude_account_id: nil, runtime: runtime))
    event_count = event_scope.count

    if account_count == 0 && event_count == 0 && snapshot_scope.count == 0 && attempt_scope.count == 0
      puts "No Claude accounts or history to remove."
      next
    end

    # Wrap in transaction so partial deletes don't leave orphaned data.
    # Delete dependent records first to avoid FK constraint violations. This task
    # is the deliberate "wipe it and start over" affordance, so it destroys the
    # history a single-account delete preserves.
    ActiveRecord::Base.transaction do
      event_scope.delete_all
      snapshot_scope.delete_all
      attempt_scope.delete_all
      ClaudeAccount.for_runtime(runtime).delete_all
    end

    puts "Removed #{account_count} account(s) and #{event_count} rotation event(s), plus their snapshots and login attempts."
    puts "Run `bin/rails 'claude_accounts:add[email]'` to set up accounts from scratch."
  end

  desc "List all Claude accounts in the rotation pool"
  task list: :environment do
    accounts = ClaudeAccount.for_runtime(ClaudeAuthProvider::RUNTIME).order(:priority)

    if accounts.empty?
      puts "No Claude accounts configured."
      next
    end

    puts "Claude Accounts (#{accounts.count}):"
    puts "-" * 70
    accounts.each do |account|
      current_marker = account.is_current? ? " [CURRENT]" : ""
      config_status = account.has_valid_config? ? "configured" : "needs tokens"
      puts "  #{account.priority}. #{account.email} — #{account.status}, #{config_status}#{current_marker}"
    end
  end

  desc "Capture OAuth tokens from ~/.claude.json and ~/.claude/.credentials.json for a given account email"
  task :capture_tokens, [ :email ] => :environment do |_t, args|
    email = args[:email]
    abort "Usage: bin/rails 'claude_accounts:capture_tokens[email@example.com]'" unless email.present?

    account = ClaudeAccount.for_runtime(ClaudeAuthProvider::RUNTIME).find_by(email: email)
    abort "No ClaudeAccount found with email: #{email}" unless account

    claude_json_path = ClaudeAuthProvider::CLAUDE_JSON_PATH
    credentials_json_path = ClaudeAuthProvider::CREDENTIALS_JSON_PATH

    oauth_config = {}

    if File.exist?(claude_json_path)
      oauth_config["claude_json"] = JSON.parse(File.read(claude_json_path))
      puts "Read #{claude_json_path}"
    else
      puts "Warning: #{claude_json_path} not found"
    end

    if File.exist?(credentials_json_path)
      oauth_config["credentials_json"] = JSON.parse(File.read(credentials_json_path))
      puts "Read #{credentials_json_path}"
    else
      abort "Error: #{credentials_json_path} not found — run `claude /login` first"
    end

    account.update!(oauth_config: oauth_config)
    puts "Stored tokens for #{email} (keys: #{oauth_config.keys.join(", ")})"
  end
end
