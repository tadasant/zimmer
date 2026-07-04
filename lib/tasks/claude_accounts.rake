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

    # If the filesystem currently holds this email's oauth tokens (i.e. the
    # user just ran `claude /login`), capture them automatically. This
    # removes the old 3-step footgun where forgetting `capture_tokens` left
    # the account as an empty shell that silently broke every downstream
    # feature (quotas, rotation, probing).
    fs_email = ClaudeAccount.filesystem_oauth_email
    if fs_email == email
      synced = ClaudeAccount.sync_from_filesystem!
      if synced
        puts "Captured OAuth tokens from filesystem for #{email}"
        puts "Marked #{email} as current (no prior current account)" if synced.is_current? && ClaudeAccount.for_runtime(ClaudeAuthProvider::RUNTIME).where.not(id: synced.id).where(is_current: true).none?
      end
    elsif fs_email.present?
      puts "Note: filesystem holds tokens for a different account (#{fs_email}). Run `claude /login` as #{email}, then re-run this command (or use `claude_accounts:capture_tokens`)."
    else
      puts "Note: no filesystem tokens detected. Run `claude /login` as #{email}, then run `bin/rails 'claude_accounts:capture_tokens[#{email}]'`."
    end
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

  desc "Remove ALL Claude accounts and rotation events. Usage: bin/rails claude_accounts:clear_all"
  task clear_all: :environment do
    # Scoped to Claude Code so it never touches Codex accounts in the shared pool.
    claude_ids = ClaudeAccount.for_runtime(ClaudeAuthProvider::RUNTIME).pluck(:id)
    account_count = claude_ids.size

    if account_count == 0
      puts "No Claude accounts to remove."
      next
    end

    event_scope = AccountRotationEvent
      .where(rotated_from_id: claude_ids)
      .or(AccountRotationEvent.where(rotated_to_id: claude_ids))
    event_count = event_scope.count

    # Wrap in transaction so partial deletes don't leave orphaned data.
    # Delete dependent records first to avoid FK constraint violations.
    ActiveRecord::Base.transaction do
      event_scope.delete_all
      ClaudeAccountQuotaSnapshot.where(claude_account_id: claude_ids).delete_all
      ClaudeAccount.for_runtime(ClaudeAuthProvider::RUNTIME).delete_all
    end

    puts "Removed #{account_count} account(s) and #{event_count} rotation event(s)."
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
