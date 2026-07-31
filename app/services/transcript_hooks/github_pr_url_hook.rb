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
# runtimes write very different transcript shapes, so locating `gh pr create`
# invocations, their results, and whether a result failed is dispatched on the
# session's agent_runtime. That shape handling lives in
# TranscriptHooks::ToolCallParser, which this hook shares with
# GithubCommentAuthorshipHook.
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
      # shell's exit code (see TranscriptHooks::CodexToolCallParser).
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

  # The runtime-aware view of this transcript's tool calls and results. The
  # Claude and Codex shapes both live in TranscriptHooks::ToolCallParser.
  def parser
    @parser ||= TranscriptHooks::ToolCallParser.for(session: session, parsed_transcript: parsed_transcript)
  end

  # Collect the tool-call ids for any invocation whose command contains `gh pr
  # create`. The corresponding tool result is what we treat as authoritative for
  # "this session opened this PR".
  #
  # @return [Array<String>] tool-call ids (Claude tool_use ids / Codex call_ids)
  def collect_pr_create_tool_use_ids
    parser.tool_call_ids_matching(GH_PR_CREATE_PATTERN)
  end

  # Every tool result in the transcript, so extract_pr_urls stays runtime-agnostic.
  #
  # @return [Array<Hash>] each { id: String, text: String, is_error: Boolean }
  def tool_results
    parser.tool_results
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
