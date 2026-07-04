# Hook that extracts GitHub Pull Request URLs from tool result output
# When PR URLs are found in tool results (format: https://github.com/.../pull/...),
# they're stored in the session's custom_metadata as github_pull_request_urls (array)
#
# A PR URL in a tool result is associated with the session if EITHER:
#   1. The PR's owner/repo matches the session's git_root (the same-repo fast path), OR
#   2. The tool result is the response to a `gh pr create` invocation — i.e.,
#      the session itself opened the PR. This covers the cross-repo case (an agent
#      running on `owner/repo` that opens a PR against `other-org/other-repo`).
#
# This two-path design preserves the original false-positive guard (so a stray PR URL
# from `gh pr view <unrelated>` or a WebFetch of a PR page is NOT auto-tracked) while
# allowing the user-relevant case where the session genuinely opened a PR on a foreign
# repo to surface in the session header.
#
# Runtime support: both Claude Code and OpenAI Codex sessions are handled. The two
# runtimes write very different transcript shapes, so the shape-dependent parsing
# (locating `gh pr create` invocations, their results, and whether a result failed)
# is dispatched on the session's agent_runtime:
#   - Claude Code: tool_use/tool_result blocks; `gh pr create` lives in a Bash
#     tool_use `input.command`; a result's failure is its own `is_error` flag.
#   - Codex: response_item function_call/local_shell_call (shell argv) and
#     function_call_output (result text); a shell's exit code lives on a separate
#     `exec_command_end` event_msg line, correlated by call_id. The OpenTranscripts
#     normalizer intentionally drops those UI-side event_msg lines, so the hook
#     reads exit codes straight from the rollout rather than from normalized events.
# If more hooks need cross-runtime tool correlation, the codex_*/claude_* helpers
# below are the natural extraction point for a shared runtime-aware parser.
#
# This hook is registered by default via the transcript hooks initializer.
#
class TranscriptHooks::GithubPrUrlHook < TranscriptHooks::BaseHook
  # Regex pattern to match GitHub PR URLs
  # Captures URLs like: https://github.com/owner/repo/pull/123
  # Uses explicit character classes to prevent subdomain spoofing attacks
  # (e.g., github.com.evil.com would NOT match)
  GITHUB_PR_URL_PATTERN = %r{https://github\.com/[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+/pull/\d+}

  # Matches `gh pr create` anywhere inside a shell command. This is a
  # heuristic — it correctly handles common shapes (`cd ... && gh pr create`,
  # env-var prefixes like `FOO=bar gh pr create`, and Codex argv arrays joined
  # into `bash -lc cd ... && gh pr create`) but is not airtight (a `gh pr create`
  # literal embedded in a heredoc body would also match). Consequence of a false
  # positive is just relaxed filtering for that single tool call, so this is
  # acceptable.
  GH_PR_CREATE_PATTERN = /\bgh\s+pr\s+create\b/

  def call
    new_pr_urls = extract_pr_urls
    return if new_pr_urls.empty?

    existing_urls = get_custom_metadata("github_pull_request_urls") || []
    # Add new URLs to the end (most recent last), avoiding duplicates
    updated_urls = existing_urls + (new_pr_urls - existing_urls)

    return if updated_urls == existing_urls

    # Track when each PR URL was first associated with this session
    # This timestamp is used to filter out historical comments that existed
    # before the session started tracking the PR
    existing_timestamps = get_custom_metadata("github_pr_tracking_started_at") || {}
    updated_timestamps = existing_timestamps.dup
    current_time = Time.current.iso8601

    (new_pr_urls - existing_urls).each do |pr_url|
      # Only set timestamp for truly new PR URLs (not already tracked)
      updated_timestamps[pr_url] ||= current_time
    end

    updates = { "github_pull_request_urls" => updated_urls }
    updates["github_pr_tracking_started_at"] = updated_timestamps if updated_timestamps != existing_timestamps

    update_custom_metadata(updates)
    Rails.logger.info "[GithubPrUrlHook] Found #{new_pr_urls.size} new PR URL(s) for session #{session.id}: #{new_pr_urls.join(', ')}"
  end

  private

  def extract_pr_urls
    target_owner_repo = extract_owner_repo_from_git_root&.downcase
    pr_create_tool_use_ids = collect_pr_create_tool_use_ids

    # If we have neither a same-repo target nor any `gh pr create` invocations,
    # there's nothing to extract.
    return [] if target_owner_repo.nil? && pr_create_tool_use_ids.empty?

    matching_urls = []

    tool_results.each do |result|
      # Skip the cross-repo path for failed tool results. A failing `gh pr
      # create` (auth error, "a pull request for branch X already exists:
      # <url>", etc.) can still embed a GitHub PR URL in its output, and we
      # don't want to attribute those PRs to this session. Same-repo matching is
      # still allowed since git_root is a strong signal. For Claude the failure
      # flag is the result's own is_error; for Codex it is derived from the
      # shell's exit code (see codex_tool_results).
      is_pr_create_result = pr_create_tool_use_ids.include?(result[:id]) && !result[:is_error]

      next if result[:text].blank?

      result[:text].scan(GITHUB_PR_URL_PATTERN).each do |url|
        next if matching_urls.include?(url)

        if is_pr_create_result
          # The session itself opened this PR — track regardless of repo
          matching_urls << url
        elsif target_owner_repo
          # Otherwise fall back to same-repo matching to filter false positives
          url_match = url.match(%r{github\.com/([^/]+/[^/]+)/pull/\d+})
          next unless url_match

          url_owner_repo = url_match[1].downcase.delete_suffix(".git")
          matching_urls << url if url_owner_repo == target_owner_repo
        end
      end
    end

    matching_urls
  end

  # True when the session ran on the OpenAI Codex runtime, selecting the Codex
  # transcript-shape parsers below. Any other value (including a blank/unknown
  # runtime) falls back to the Claude Code parsers, preserving prior behavior.
  def codex_runtime?
    session.agent_runtime == "codex"
  end

  # Collect the tool-call ids for any invocation whose command contains `gh pr
  # create`. The corresponding tool result is what we treat as authoritative for
  # "this session opened this PR".
  #
  # @return [Array<String>] tool-call ids (Claude tool_use ids / Codex call_ids)
  def collect_pr_create_tool_use_ids
    codex_runtime? ? codex_pr_create_tool_use_ids : claude_pr_create_tool_use_ids
  end

  # Flatten the transcript into a uniform list of tool results so extract_pr_urls
  # can stay runtime-agnostic.
  #
  # @return [Array<Hash>] each { id: String, text: String, is_error: Boolean }
  def tool_results
    codex_runtime? ? codex_tool_results : claude_tool_results
  end

  # --- Claude Code transcript shape ------------------------------------------

  # Walk the transcript and collect tool_use ids for any Bash invocation whose
  # command contains `gh pr create`.
  def claude_pr_create_tool_use_ids
    ids = []

    parsed_transcript.each do |message|
      message_data = message["message"] || message
      content = message_data["content"]
      next unless content.is_a?(Array)

      content.each do |block|
        next unless block["type"] == "tool_use"
        next unless block["name"] == "Bash"

        command = block.dig("input", "command")
        next unless command.is_a?(String)
        next unless command.match?(GH_PR_CREATE_PATTERN)

        ids << block["id"] if block["id"]
      end
    end

    ids
  end

  # Tool results are user-message content blocks of type "tool_result", matched
  # back to their invocation via tool_use_id.
  def claude_tool_results
    results = []

    parsed_transcript.each do |message|
      message_data = message["message"] || message
      content = message_data["content"]
      next unless content.is_a?(Array)

      content.each do |block|
        next unless block["type"] == "tool_result"

        result_content = block["content"]
        next unless result_content.is_a?(String)

        results << { id: block["tool_use_id"], text: result_content, is_error: !!block["is_error"] }
      end
    end

    results
  end

  # --- Codex rollout transcript shape ----------------------------------------

  # Codex shell calls are response_item payloads of type "function_call" (name
  # "shell", JSON-encoded `arguments` with a `command` argv array) or
  # "local_shell_call" (argv under `action.command`). Collect the call_ids whose
  # command runs `gh pr create`.
  def codex_pr_create_tool_use_ids
    ids = []

    codex_response_items.each do |payload|
      command = codex_shell_command(payload)
      next if command.blank?
      next unless command.match?(GH_PR_CREATE_PATTERN)

      call_id = payload["call_id"]
      ids << call_id if call_id
    end

    ids
  end

  # Codex tool results are response_item payloads of type "function_call_output"
  # / "custom_tool_call_output". A shell's failure is not on the output payload
  # itself — it lives on the matching `exec_command_end` event_msg line — so we
  # correlate the exit code by call_id and mark the result as an error when the
  # exit code is present and non-zero.
  def codex_tool_results
    exit_codes = codex_exit_codes_by_call_id
    results = []

    codex_response_items.each do |payload|
      next unless %w[function_call_output custom_tool_call_output].include?(payload["type"])

      call_id = payload["call_id"]
      text = codex_output_text(payload["output"])
      next if text.blank?

      exit_code = exit_codes[call_id]
      results << { id: call_id, text: text, is_error: exit_code.present? && exit_code != 0 }
    end

    results
  end

  # Map call_id -> exit_code from `exec_command_end` event_msg lines. These
  # UI-side lines are the only place Codex records a shell's exit status, so the
  # failed-`gh pr create` guard reads them directly from the rollout.
  def codex_exit_codes_by_call_id
    map = {}

    parsed_transcript.each do |line|
      next unless line["type"] == "event_msg"

      payload = line["payload"]
      next unless payload.is_a?(Hash) && payload["type"] == "exec_command_end"

      call_id = payload["call_id"]
      next if call_id.nil?

      map[call_id] = payload["exit_code"]
    end

    map
  end

  # Every response_item payload hash in the rollout.
  def codex_response_items
    parsed_transcript.filter_map do |line|
      next unless line["type"] == "response_item"

      payload = line["payload"]
      payload if payload.is_a?(Hash)
    end
  end

  # Extract the shell command string from a Codex tool-call payload, or nil if
  # the payload is not a shell invocation. The argv array is joined into a single
  # string so GH_PR_CREATE_PATTERN can match across tokens.
  def codex_shell_command(payload)
    case payload["type"]
    when "function_call"
      return nil unless payload["name"] == "shell"

      args = parse_codex_arguments(payload["arguments"])
      codex_command_to_string(args["command"])
    when "local_shell_call"
      action = payload["action"]
      return nil unless action.is_a?(Hash)

      codex_command_to_string(action["command"])
    end
  end

  def codex_command_to_string(command)
    case command
    when String then command
    when Array then command.join(" ")
    end
  end

  # The Codex `function_call` arguments field is a JSON-encoded String. Parse it
  # into a Hash; return an empty Hash when it is absent or not a JSON object.
  def parse_codex_arguments(arguments)
    return {} if arguments.blank?
    return arguments if arguments.is_a?(Hash)

    parsed = JSON.parse(arguments)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  # Codex serializes a tool output as either a bare String or an array of content
  # items ({ "type", "text" }). Fold into a single String for URL scanning.
  def codex_output_text(output)
    case output
    when String
      output
    when Array
      output.filter_map { |item| item["text"] if item.is_a?(Hash) }.join("\n")
    else
      ""
    end
  end

  # Extract owner/repo from the session's git_root URL
  # @return [String, nil] The owner/repo string (e.g., "owner/repo") or nil if not a GitHub URL
  def extract_owner_repo_from_git_root
    git_root = session.git_root
    return nil if git_root.blank?

    # Handle HTTPS URLs: https://github.com/owner/repo.git or https://github.com/owner/repo
    if git_root.match?(%r{github\.com/})
      match = git_root.match(%r{github\.com/([^/]+/[^/]+?)(?:\.git)?(?:/|$)})
      return match[1] if match
    end

    # Handle SSH URLs: git@github.com:owner/repo.git
    if git_root.match?(/git@github\.com:/)
      match = git_root.match(%r{git@github\.com:([^/]+/[^/]+?)(?:\.git)?$})
      return match[1] if match
    end

    nil
  end
end
