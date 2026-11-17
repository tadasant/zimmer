# frozen_string_literal: true

require "tmpdir"
require "timeout"
require "fileutils"

module LiveConversations
  # Live Mode's Claude, for the `gpt_live_claude` engine's delegations
  # (ClaudeDelegate): one Claude Code run per delegation — `claude -p`, the real
  # CLI — on Zimmer's Claude Code subscription.
  #
  # Why the CLI and not the Messages API: Anthropic accepts the subscription's
  # OAuth token for Opus and Sonnet only from Claude Code. A raw Messages API
  # call on that token is refused (a 429 `rate_limit_error` whose message is
  # just "Error"), while the same account serves every agent session, which is
  # Claude Code. So a delegation is a Claude Code run, credentialed exactly like
  # the one-off `claude -p` inference behind session titles and summaries
  # (ClaudeHeadlessCredentials: the pool's current access token and the shared
  # headless config dir), and nothing else is used: no Anthropic API key.
  #
  # The run gets Live Mode's tools and nothing else:
  #
  #   --tools ""                no built-in tools (no Bash, no file access)
  #   --setting-sources ""      no user, project or local settings, hooks or CLAUDE.md
  #   --strict-mcp-config       no MCP server but the one named here
  #   --mcp-config              this conversation's ToolBridge, served by
  #                             LiveDelegationMcpController on a token minted for
  #                             this delegation (DelegationToken)
  #   --allowedTools            that server's tools may run without a prompt
  #   --disable-slash-commands  the request cannot open a skill or command
  #
  # Claude Code's own system prompt is kept and the delegation's instructions
  # are appended to it, so the run is the same shape as every other subscription
  # call Zimmer makes. Nothing private goes on the command line, where `ps`
  # shows it: the MCP config (with its token) and the instructions are mode-0600
  # files in the run's own directory, and the request goes on stdin. That
  # directory is named for headless inference, so TokenUsageIngestionService
  # accounts for the run's transcript like any other headless `claude -p` call.
  class ClaudeClient
    # A delegation is waited on by a voice call; a slow one is worth less than a
    # quick "I could not get that" the person hears.
    TIMEOUT_SECONDS = 90
    MAX_TURNS = 8
    MCP_SERVER = "zimmer_live"
    STDERR_LOG_CHARS = 300
    # Claude Code's telemetry, update checks and error reporting, none of which a
    # voice call should wait on: measured, a run with them on took anywhere from
    # 5 to 47 seconds against the same stand-in API; with them off, 4 to 5.
    QUIET_ENV = { "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" => "1" }.freeze

    # The prefix TokenUsageIngestionService::HEADLESS_DIR recognises once
    # Claude Code turns the directory into a project name.
    RUN_DIR_PREFIX = "headless_inference_live_delegation_"

    # `status` is the CLI's exit status (nil for a timeout or a run that never
    # started); `kind` what went wrong, for ClaudeDelegate to say: :auth (Claude
    # Code is not signed in or its credential was refused), :rate_limited,
    # :timeout, :max_turns, :failed. `usage` is what the run spent before it
    # failed, when the CLI reported it.
    class Error < StandardError
      attr_reader :kind, :status, :usage

      def initialize(message = nil, kind: :failed, status: nil, usage: nil)
        super(message)
        @kind = kind
        @status = status
        @usage = usage
      end
    end

    class NotConfiguredError < Error; end

    # What one run answered: the final text, the token usage across its turns,
    # how many turns it took, and the model that answered.
    Answer = Data.define(:text, :usage, :num_turns, :models, :duration_ms)

    # The current account's token and nil, or nil and why Live Mode cannot reach
    # Claude now. The test is the one sessions spawn on
    # (ClaudeAccount#usable_as_current?): an account out of quota, waiting to be
    # re-authenticated, or refused by Anthropic is unavailable, and the engine
    # falls back rather than failing every delegation mid-call.
    def self.credential
      account = ClaudeAccount.current_account(ClaudeAuthProvider::RUNTIME)
      return [ account.claude_access_token, nil ] if account&.usable_as_current?

      [ nil, refusal_for(account) ]
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn("[live.claude] could not read the current Claude Code account: #{e.class}")
      [ nil, "Zimmer's Claude Code accounts could not be read" ]
    end

    def self.refusal_for(account)
      if account.nil? then "Zimmer has no current Claude Code account"
      elsif account.claude_access_token.blank? then "Zimmer's current Claude Code account has no credentials"
      elsif account.credential_rejected? || account.needs_reauth? then "Zimmer's current Claude Code account needs re-authenticating (/inference)"
      elsif account.quota_exceeded? then "Zimmer's current Claude Code account is out of quota"
      else "Zimmer's current Claude Code account cannot serve right now"
      end
    end

    def self.unavailable_reason = credential.last

    # Environment variables that make Claude Code bill per token through the
    # Anthropic API. Claude Code prefers either over CLAUDE_CODE_OAUTH_TOKEN
    # when both are set, so their presence decides the basis.
    API_KEY_VARS = %w[ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN].freeze

    # How a run with this credential environment is paid for, as a
    # LiveUsageEvent billing basis: `subscription` when it authenticates with
    # the subscription's OAuth token, `metered` when an API key is in reach (or
    # nothing says it is covered). `env` is what the process sees: the worker's
    # own environment with the overlay on top, because spawn inherits it.
    def self.billing_basis_for(env)
      return "metered" if API_KEY_VARS.any? { |name| env[name].present? }
      return "subscription" if env["CLAUDE_CODE_OAUTH_TOKEN"].present?

      "metered"
    end

    def self.configured? = unavailable_reason.nil?

    # Where the CLI reaches this conversation's tools: Zimmer's own address, the
    # one agent sessions reach /mcp at (AppUrl).
    def self.mcp_url = "#{AppUrl.base_url}/live/delegation_mcp"

    def initialize(claude_binary: "claude", process_manager: nil, env: nil, mcp_url: self.class.mcp_url, timeout: TIMEOUT_SECONDS,
                   logger: Rails.logger)
      reason = self.class.unavailable_reason if env.nil?
      raise NotConfiguredError, reason if reason

      @claude_binary = claude_binary
      @process_manager = process_manager || SystemProcessManager.new
      credentials = env || ClaudeHeadlessCredentials.env
      raise NotConfiguredError, "Zimmer's current Claude Code account has no credentials" if credentials.blank?

      @env = credentials.merge(QUIET_ENV)

      @mcp_url = mcp_url
      @timeout = timeout
      @logger = logger
    end

    # How this client's runs are paid for: see billing_basis_for.
    def billing_basis = self.class.billing_basis_for(ENV.to_h.merge(@env))

    # One Claude Code run.
    #
    # @param prompt [String] the request
    # @param system [String] appended to Claude Code's system prompt
    # @param model [String] a Messages API model id
    # @param mcp_token [String] DelegationToken for this delegation
    # @return [Answer]
    # @raise [Error]
    def run(prompt:, system:, model:, mcp_token:)
      temp_dir = Dir.mktmpdir(RUN_DIR_PREFIX)
      files = write_inputs(temp_dir, prompt, system, mcp_token)
      out_file = File.join(temp_dir, "out.json")
      err_file = File.join(temp_dir, "err.txt")
      pid = @process_manager.spawn(@env, *command(model, files), chdir: temp_dir,
                                   in: [ files[:prompt], "r" ], out: [ out_file, "w" ], err: [ err_file, "w" ])
      status = Timeout.timeout(@timeout) { @process_manager.wait(pid) }
      process_status = status.is_a?(Array) ? status[1] : nil
      answer_from(File.read(out_file), process_status, File.exist?(err_file) ? File.read(err_file) : "")
    rescue Timeout::Error
      terminate(pid)
      raise Error.new("Claude Code did not answer within #{@timeout}s", kind: :timeout)
    rescue SystemCallError, IOError => e
      # The binary missing, the run directory unwritable: a run that never
      # started is a failure to say, not a 500 for the client.
      @logger.warn("[live.claude] could not run claude: #{e.class}: #{e.message.truncate(STDERR_LOG_CHARS)}")
      raise Error.new("Claude Code could not be started (#{e.class})", kind: :failed)
    ensure
      FileUtils.rm_rf(temp_dir) if temp_dir
    end

    # @param files [Hash] the paths write_inputs returned
    def command(model, files)
      [ @claude_binary,
        "--model", model,
        "--output-format", "json",
        "--max-turns", MAX_TURNS.to_s,
        "--tools", "",
        "--setting-sources", "",
        "--disable-slash-commands",
        "--strict-mcp-config",
        "--mcp-config", files[:mcp_config],
        "--allowedTools", "mcp__#{MCP_SERVER}",
        "--append-system-prompt-file", files[:system],
        "-p" ]
    end

    private

    def write_inputs(dir, prompt, system, mcp_token)
      mcp_config = { mcpServers: { MCP_SERVER => { type: "http", url: @mcp_url, headers: { "Authorization" => "Bearer #{mcp_token}" } } } }
      { prompt: private_file(dir, "prompt.txt", prompt.to_s), system: private_file(dir, "system.txt", system.to_s),
        mcp_config: private_file(dir, "mcp.json", mcp_config.to_json) }
    end

    def private_file(dir, name, content)
      path = File.join(dir, name)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(content) }
      path
    end

    # `claude -p --output-format json` prints one result object, error or not.
    def answer_from(stdout, process_status, stderr)
      exit_status = process_status&.exitstatus
      result = begin
        JSON.parse(stdout.to_s.strip.lines.last.to_s)
      rescue JSON::ParserError
        nil
      end
      unless result.is_a?(Hash)
        @logger.warn("[live.claude] claude exited #{exit_status.inspect} with no result: #{stderr.squish.truncate(STDERR_LOG_CHARS).presence || '(no stderr)'}")
        raise Error.new("Claude Code exited #{exit_status.inspect} without an answer", status: exit_status)
      end

      text = result["result"].to_s
      subtype = result["subtype"].to_s
      if result["is_error"] || subtype.start_with?("error") || !process_status&.success?
        kind = subtype == "error_max_turns" ? :max_turns : kind_of(text)
        raise Error.new("Claude Code: #{(text.presence || subtype.presence || 'no answer').truncate(300)}",
                        kind: kind, status: exit_status, usage: result["usage"])
      end

      Answer.new(text: text, usage: result["usage"] || {}, num_turns: result["num_turns"].to_i,
                 models: (result["modelUsage"] || {}).keys, duration_ms: result["duration_ms"])
    end

    def kind_of(text)
      case text
      when /not logged in|please run \/login|authentication_error|oauth token|invalid (api key|bearer)|\b401\b/i then :auth
      when /rate.?limit|usage limit|overloaded|\b429\b|\b529\b/i then :rate_limited
      else :failed
      end
    end

    def terminate(pid)
      return unless pid

      %w[TERM KILL].each do |signal|
        begin
          @process_manager.kill(signal, pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
        10.times do
          return if @process_manager.wait(pid, Process::WNOHANG)

          sleep 0.05
        end
      end
    rescue Errno::ECHILD
      nil
    end
  end
end
