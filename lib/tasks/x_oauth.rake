# frozen_string_literal: true

# One-time bootstrap for the durable X (Twitter) OAuth credential.
#
# Two-step, human-in-the-loop (a browser consent is unavoidable — X has no
# non-interactive user-context token grant):
#
#   1. bin/rails x_oauth:authorize
#      → prints an X consent URL. Open it, authorize, then copy the `code`
#        param out of the redirect URL bar (nothing listens on the redirect URI).
#
#   2. CODE=<pasted-code> bin/rails x_oauth:complete
#      → exchanges the code for tokens and stores them in x_oauth_credentials.
#
# Config via env (all optional):
#   ACCOUNT_KEY   human label for the account            (default: tadasayy)
#   ENV_VAR       .mcp.json env var to vend the token as (default: X_OAUTH_ACCESS_TOKEN)
#   REDIRECT_URI  must be registered on the X app        (default: http://localhost:8080/callback)
#
# Static client creds come from Rails credentials (mcp_secrets: X_OAUTH_CLIENT_ID
# / X_OAUTH_CLIENT_SECRET). The PKCE verifier is stashed between the two steps in
# the durable session scratch dir so it survives a restart between steps.
namespace :x_oauth do
  def x_oauth_pending_path
    base = ENV["AO_SESSION_SCRATCH_DIR"].presence || Rails.root.join("tmp").to_s
    FileUtils.mkdir_p(base)
    File.join(base, "x_oauth_pending.json")
  end

  def x_oauth_config
    {
      account_key: ENV["ACCOUNT_KEY"].presence || "tadasayy",
      env_var: ENV["ENV_VAR"].presence || "X_OAUTH_ACCESS_TOKEN",
      redirect_uri: ENV["REDIRECT_URI"].presence || XOauthBootstrap::DEFAULT_REDIRECT_URI
    }
  end

  desc "Step 1: print the X OAuth consent URL (PKCE) and stash the verifier"
  task authorize: :environment do
    client_id = XOauthCredential.client_id
    abort "X_OAUTH_CLIENT_ID not set in credentials (mcp_secrets)" if client_id.blank?

    cfg = x_oauth_config
    verifier = XOauthBootstrap.generate_verifier
    state = XOauthBootstrap.generate_state
    url = XOauthBootstrap.authorize_url(
      client_id: client_id, verifier: verifier, state: state, redirect_uri: cfg[:redirect_uri]
    )

    File.write(x_oauth_pending_path, JSON.pretty_generate(cfg.merge(verifier: verifier, state: state)))

    puts "\n=== X (Twitter) OAuth bootstrap — Step 1 ==="
    puts "Account:      #{cfg[:account_key]}"
    puts "Env var:      #{cfg[:env_var]}"
    puts "Redirect URI: #{cfg[:redirect_uri]} (must be registered on the X app)"
    puts "Scopes:       #{XOauthBootstrap::SCOPES}"
    puts "\nOpen this URL, authorize, then copy the `code` param from the redirect URL:\n\n"
    puts url
    puts "\nThen run:  CODE=<pasted-code> bin/rails x_oauth:complete\n\n"
  end

  desc "Step 2: exchange CODE=<code> for tokens and store the credential"
  task complete: :environment do
    code = ENV["CODE"].presence
    abort "Provide the authorization code: CODE=<code> bin/rails x_oauth:complete" if code.blank?

    pending_path = x_oauth_pending_path
    abort "No pending flow found at #{pending_path}. Run x_oauth:authorize first." unless File.exist?(pending_path)
    pending = JSON.parse(File.read(pending_path))

    credential = XOauthBootstrap.complete!(
      account_key: pending["account_key"],
      env_var: pending["env_var"],
      code: code,
      verifier: pending.fetch("verifier"),
      redirect_uri: pending["redirect_uri"] || XOauthBootstrap::DEFAULT_REDIRECT_URI
    )

    File.delete(pending_path) if File.exist?(pending_path)

    puts "\n=== X (Twitter) OAuth bootstrap — complete ==="
    puts "Stored XOauthCredential ##{credential.id} (account=#{credential.account_key}, env_var=#{credential.access_token_env_var})"
    puts "Granted scopes: #{credential.scopes}"
    puts "Access token expires: #{credential.expires_at}"
    puts "Refresh token stored: #{credential.refresh_token.present? ? "yes (#{credential.refresh_token.length} chars)" : "no"}"
    puts "(token values not printed)\n\n"
  end

  desc "Show the current X OAuth credential status (no secrets printed)"
  task status: :environment do
    XOauthCredential.find_each do |c|
      puts "##{c.id} account=#{c.account_key} env_var=#{c.access_token_env_var} " \
           "active=#{c.active?} expires_at=#{c.expires_at} scopes=#{c.scopes.inspect} " \
           "can_refresh=#{c.can_refresh?} last_refresh_error=#{c.last_refresh_error.inspect}"
    end
    puts "(no credentials)" if XOauthCredential.count.zero?
  end
end
