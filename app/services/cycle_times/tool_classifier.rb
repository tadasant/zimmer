# frozen_string_literal: true

module CycleTimes
  # Which category the time spent inside one tool call belongs to.
  #
  # The one place that decides "was this a network call, local I/O, or a wait".
  # Everything else asks here, so a heuristic is fixed once and the test file
  # next to this one is the list of what it recognizes.
  #
  # A call is classified by its tool name, and a shell call by its command. Shell
  # classification is a heuristic over the command text, applied in this order,
  # first match wins:
  #
  #   1. a CI watch (`gh pr checks --watch`, `gh run watch`, a loop polling
  #      `gh pr checks` / `gh run view`)           → wait_ci
  #   2. a plain `sleep N` with N >= SLEEP_FLOOR    → wait_sleep
  #   3. anything that talks to the network (gh, git push/fetch/pull/clone,
  #      curl, package installs, docker pull, ...)  → network
  #   4. everything else (tests, builds, greps)     → local_io
  #
  # Rule 2 sits above rule 3 because `sleep 60 && gh pr view` spends its minute
  # sleeping, not on the network; rule 1 sits above both because that same shape
  # aimed at checks is the CI wait we most want to see.
  module ToolClassifier
    Result = Data.define(:category, :detail)

    # A sleep shorter than this is a pause between retries, not a wait anyone
    # chose; it stays with whatever else the command does.
    SLEEP_FLOOR = 5

    DETAIL_LIMIT = 140

    LOCAL_TOOLS = %w[
      Read Edit Write MultiEdit NotebookEdit NotebookRead Grep Glob LS TodoWrite TodoRead Skill ToolSearch
      ExitPlanMode EnterPlanMode BashOutput KillShell KillBash TaskOutput TaskStop Monitor apply_patch
      update_plan view_image
    ].freeze

    NETWORK_TOOLS = %w[WebFetch WebSearch web_search web_fetch].freeze
    SUBAGENT_TOOLS = %w[Task Agent].freeze
    HUMAN_TOOLS = %w[AskUserQuestion].freeze
    SHELL_TOOLS = %w[Bash shell exec_command local_shell container.exec bash].freeze

    CI_WATCH = [
      /\bgh\s+pr\s+checks\b[^|;&]*--watch/,
      /\bgh\s+run\s+watch\b/,
      /\b(?:until|while)\b[^\n]*\bgh\s+(?:pr\s+checks|run\s+(?:view|list))\b/,
      /\bwait[-_]for[-_]ci\b/
    ].freeze

    NETWORK_COMMANDS = [
      /\bgh\s+\S+/,
      /\bgit\s+(?:push|fetch|pull|clone|ls-remote|submodule\s+update)\b/,
      /\b(?:curl|wget|ssh|scp|rsync|nc|dig|nslookup|ping)\b/,
      /\b(?:npm|pnpm|yarn)\s+(?:install|i|ci|add|publish|view|info)\b/,
      /\b(?:bundle|bundler)\s+(?:install|update|add|exec\s+bundle\s+install)\b/,
      /\bgem\s+(?:install|fetch|push)\b/,
      /\b(?:pip|pip3|uv|poetry)\s+(?:install|add|sync|lock)\b/,
      /\bdocker\s+(?:pull|push|login)\b/,
      /\b(?:kamal|doctl|gcloud|aws|terraform|flyctl|wrangler)\b/,
      /\bbrew\s+install\b/,
      /\b(?:apt|apt-get)\s+(?:update|install)\b/
    ].freeze

    module_function

    # @param tool_name [String] the transcript's tool name
    # @param arguments [Hash, nil] the call's input
    # @return [Result]
    def classify(tool_name, arguments = {})
      name = tool_name.to_s
      args = arguments.is_a?(Hash) ? arguments : {}

      return classify_mcp(name, args) if name.start_with?("mcp__")
      return classify_shell(shell_command(args)) if SHELL_TOOLS.include?(name)
      return Result.new("subagent", truncate("#{name}: #{args['description'] || args['subagent_type']}")) if SUBAGENT_TOOLS.include?(name)
      return Result.new("network", truncate("#{name} #{args['url'] || args['query']}")) if NETWORK_TOOLS.include?(name)
      return Result.new("wait_human", name) if HUMAN_TOOLS.include?(name)

      Result.new("local_io", truncate("#{name} #{local_argument(args)}".strip))
    end

    # The shell command's category, by the rules in the class comment.
    def classify_shell(command)
      text = command.to_s
      detail = truncate("$ #{text.strip.gsub(/\s+/, ' ')}")

      return Result.new("wait_ci", detail) if CI_WATCH.any? { |re| text.match?(re) }
      return Result.new("wait_sleep", detail) if long_sleep?(text)
      return Result.new("network", detail) if NETWORK_COMMANDS.any? { |re| text.match?(re) }

      Result.new("local_io", detail)
    end

    # MCP calls are network calls: every MCP server is a process or a remote
    # endpoint. Zimmer's own wake tools are no exception — the call returns at
    # once, and the sleep it arms is accounted when the session goes to sleep.
    def classify_mcp(name, args)
      _, server, tool = name.split("__", 3)
      detail = truncate("#{server} → #{tool}#{mcp_argument(args)}")
      Result.new("network", detail)
    end

    def long_sleep?(text)
      text.scan(/(?:^|[;&|(\s])sleep\s+(\d+(?:\.\d+)?)([smh]?)/).any? do |amount, unit|
        seconds = amount.to_f * { "m" => 60, "h" => 3600 }.fetch(unit, 1)
        seconds >= SLEEP_FLOOR
      end
    end

    def shell_command(args)
      command = args["command"] || args["cmd"]
      command = command.join(" ") if command.is_a?(Array)
      command.to_s.sub(/\Abash\s+-lc\s+/, "")
    end

    def local_argument(args)
      (args["file_path"] || args["path"] || args["pattern"] || args["skill"] || args["query"]).to_s
    end

    def mcp_argument(args)
      hint = args.values_at("action", "session_id", "url", "query", "name").compact.first
      hint.nil? ? "" : " (#{hint.to_s[0, 60]})"
    end

    def truncate(text)
      text.to_s.length > DETAIL_LIMIT ? "#{text[0, DETAIL_LIMIT - 1]}…" : text.to_s
    end
  end
end
