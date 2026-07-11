# frozen_string_literal: true

# Rake tasks for managing the OpenAI Codex CLI account pool. Codex accounts are
# ClaudeAccount records scoped to the "codex" runtime (the pool table is shared
# across runtimes). Two credential kinds are supported:
#
#   - ChatGPT OAuth — capture the ~/.codex/auth.json envelope after running
#     `codex login --device-auth` (see https://docs.zimmer.tadasant.com/auth/harness/).
#   - OPENAI_API_KEY — register a static API key via `codex_accounts:add_api_key`.
#
# Every task here is scoped to the codex runtime so it never touches Claude Code
# accounts in the same pool.
namespace :codex_accounts do
  desc "Add a Codex (ChatGPT OAuth) account to the rotation pool. Usage: bin/rails 'codex_accounts:add[email@example.com,0]'"
  task :add, [ :email, :priority ] => :environment do |_t, args|
    email = args[:email]
    priority = args[:priority]&.to_i || 0
    abort "Usage: bin/rails 'codex_accounts:add[email@example.com,0]'" unless email.present?

    # Scope by runtime: email is unique per-runtime, so the same email may also
    # hold a separate Claude Code account. We look up / create only within the
    # Codex pool, never touching another runtime's row.
    account = ClaudeAccount.for_runtime(CodexAuthProvider::RUNTIME).find_or_initialize_by(email: email)

    account.priority = priority
    account.save!
    puts(account.previously_new_record? ? "Added codex account #{email} (priority: #{priority})" : "Updated codex account #{email} (priority: #{priority})")
    puts "Next: run `codex login --device-auth` as #{email}, then `bin/rails 'codex_accounts:capture_tokens[#{email}]'`."
  end

  desc "Add a Codex account authenticated by an OPENAI_API_KEY. Usage: bin/rails 'codex_accounts:add_api_key[email@example.com,sk-...,0]'"
  task :add_api_key, [ :email, :api_key, :priority ] => :environment do |_t, args|
    email = args[:email]
    api_key = args[:api_key]
    priority = args[:priority]&.to_i || 0
    abort "Usage: bin/rails 'codex_accounts:add_api_key[email@example.com,sk-...,0]'" unless email.present? && api_key.present?

    # Scope by runtime (see codex_accounts:add): only the Codex pool is touched,
    # so a same-email Claude Code account is never clobbered.
    account = ClaudeAccount.for_runtime(CodexAuthProvider::RUNTIME).find_or_initialize_by(email: email)

    account.priority = priority
    account.oauth_config = { "api_key" => api_key }
    account.save!
    puts "Stored OPENAI_API_KEY for codex account #{email} (priority: #{priority})."
  end

  desc "Remove a Codex account from the rotation pool. Usage: bin/rails 'codex_accounts:remove[email@example.com]'"
  task :remove, [ :email ] => :environment do |_t, args|
    email = args[:email]
    abort "Usage: bin/rails 'codex_accounts:remove[email@example.com]'" unless email.present?

    account = ClaudeAccount.for_runtime(CodexAuthProvider::RUNTIME).find_by(email: email)
    abort "No codex ClaudeAccount found with email: #{email}" unless account

    if account.is_current?
      abort "Cannot remove the current active codex account (#{email}). Switch to another account first."
    end

    account.destroy!
    puts "Removed codex account #{email}"
  end

  desc "Remove ALL Codex accounts and their rotation events. Usage: bin/rails codex_accounts:clear_all"
  task clear_all: :environment do
    codex_ids = ClaudeAccount.for_runtime(CodexAuthProvider::RUNTIME).pluck(:id)
    account_count = codex_ids.size

    if account_count == 0
      puts "No codex accounts to remove."
      next
    end

    event_scope = AccountRotationEvent
      .where(rotated_from_id: codex_ids)
      .or(AccountRotationEvent.where(rotated_to_id: codex_ids))
    event_count = event_scope.count

    # Wrap in a transaction so partial deletes don't leave orphaned data.
    # Delete dependent records first to avoid FK constraint violations.
    ActiveRecord::Base.transaction do
      event_scope.delete_all
      ClaudeAccountQuotaSnapshot.where(claude_account_id: codex_ids).delete_all
      ClaudeAccount.for_runtime(CodexAuthProvider::RUNTIME).delete_all
    end

    puts "Removed #{account_count} codex account(s) and #{event_count} rotation event(s)."
    puts "Run `bin/rails 'codex_accounts:add[email]'` to set up codex accounts from scratch."
  end

  desc "List all Codex accounts in the rotation pool"
  task list: :environment do
    accounts = ClaudeAccount.for_runtime(CodexAuthProvider::RUNTIME).order(:priority)

    if accounts.empty?
      puts "No codex accounts configured."
      next
    end

    puts "Codex Accounts (#{accounts.count}):"
    puts "-" * 70
    accounts.each do |account|
      current_marker = account.is_current? ? " [CURRENT]" : ""
      kind = account.codex_api_key_account? ? "api_key" : "chatgpt_oauth"
      config_status = account.has_valid_config? ? "configured" : "needs tokens"
      puts "  #{account.priority}. #{account.email} — #{account.status}, #{kind}, #{config_status}#{current_marker}"
    end
  end

  desc "Capture OAuth tokens from ~/.codex/auth.json for a given Codex account email"
  task :capture_tokens, [ :email ] => :environment do |_t, args|
    email = args[:email]
    abort "Usage: bin/rails 'codex_accounts:capture_tokens[email@example.com]'" unless email.present?

    account = ClaudeAccount.for_runtime(CodexAuthProvider::RUNTIME).find_by(email: email)
    abort "No codex ClaudeAccount found with email: #{email}" unless account

    auth_json_path = CodexAuthProvider::AUTH_JSON_PATH
    abort "Error: #{auth_json_path} not found — run `codex login --device-auth` first" unless File.exist?(auth_json_path)

    auth_json = JSON.parse(File.read(auth_json_path))

    if auth_json.dig("tokens", "refresh_token").blank? && auth_json["OPENAI_API_KEY"].blank?
      abort "Error: #{auth_json_path} has neither ChatGPT OAuth tokens nor an OPENAI_API_KEY — run `codex login` first"
    end

    account.update!(oauth_config: { "auth_json" => auth_json })

    if account.codex_api_key_account?
      puts "Stored OPENAI_API_KEY for #{email} from #{auth_json_path}"
    else
      puts "Stored ChatGPT OAuth tokens for #{email} from #{auth_json_path} (account_id: #{account.codex_account_id || "unknown"})"
    end
  end
end
