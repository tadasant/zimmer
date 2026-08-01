# Hook that records the GitHub Pull Requests **this session opened**, storing them
# in the session's custom_metadata as github_pull_request_urls (an array).
#
# That list is provenance, not a bookmark folder: the comment poller, the
# merge-conflict poller and the session header all key off it, and anything on it
# will have GitHub activity routed back to this session. So the question the hook
# answers is not "did a PR URL appear in this transcript" — it is **"does this
# transcript show this session opening that PR"**. Reading about a PR is not
# opening one.
#
# Three kinds of evidence count, and nothing else does:
#
#   1. CREATED — the URL appears in the output of a *successful* `gh pr create`.
#      The strongest signal there is, so it holds for any repo: an agent running
#      on `owner/repo` that opens a PR against `other-org/other-repo` is tracked.
#   2. RE-CREATED — the URL appears in a *failed* `gh pr create` next to an
#      "already exists" message, i.e. the PR for the branch we just tried to push.
#      Weaker (the failure text is not ours), so it is held to the same-repo guard.
#   3. CLAIMED — the agent's own prose says it opened the PR ("Opened PR: <url>").
#      This is what catches creation paths that are not `gh pr create` — a wrapper
#      script, an MCP tool, the web UI. Weakest of the three, so it too is held to
#      the same-repo guard and to a creation phrase adjacent to the URL.
#
# What is deliberately NOT evidence:
#
#   - A same-repo URL sitting in any old tool result. This was the original
#     "same-repo fast path", and it is how a session that merely ran `gh pr view`
#     (a merge gate, a reviewer, anything reading the repo's PR list) got handed
#     someone else's PR as its own — and then received that PR's comments and
#     merge-conflict notifications (#214).
#   - A URL in a user message. Zimmer's own trigger prompts carry PR URLs
#     ("comment on your PR <url>"), so adopting them would let one misrouted
#     notification bootstrap a permanent wrong association.
#
# Every rule above is a bet against the opposite failure — a session that opened a
# PR and has nothing recorded, which silently switches off every GitHub
# integration for it (#89). `.warn_if_pr_goal_captured_no_url` is the backstop:
# when a session with a PR-flavored goal finishes a turn with an empty list, it
# says so once in the session timeline instead of failing quietly.
#
# Runtime support: both Claude Code and OpenAI Codex sessions are handled. The two
# runtimes write very different transcript shapes, so locating `gh pr create`
# invocations, their results, whether a result failed, and the agent's own prose is
# dispatched on the session's agent_runtime. That shape handling lives in
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

  # `gh pr create` exits non-zero when the branch already has a PR, printing
  # "a pull request for branch \"x\" into branch \"main\" already exists: <url>".
  # That URL is the PR for the branch this session just pushed, so it is ours —
  # unlike the other ways a create can fail (auth, protected branch), which do
  # not name a PR at all.
  PR_ALREADY_EXISTS_PATTERN = /already exists/i

  # A creation claim in the agent's own prose. Two shapes are accepted, both
  # requiring the claim to sit immediately before the URL with no sentence break
  # in between:
  #   - a creation verb running straight into the URL ("I've opened <url>")
  #   - a creation verb, a PR noun, then the URL ("Created the draft PR at <url>")
  # The PR noun is what keeps "creating a plan to review <url>" out: an agent
  # narrating work *about* a PR does not use this shape.
  # Both are case-insensitive in their own right: an interpolated Regexp keeps its
  # own flags, so the outer /xi would not reach them ("Opened" would never match a
  # lowercase-only verb list).
  CREATION_VERB = /(?:open(?:s|ed|ing)?|creat(?:e|es|ed|ing)|submit(?:s|ted|ting)?|rais(?:e|es|ed|ing)|fil(?:e|es|ed|ing))/i
  PR_NOUN = /(?:PRs?|pull\s+requests?)/i
  CREATION_CLAIM_PATTERN = /
    \b#{CREATION_VERB}\b
    (?:
      [\s:\-—>*_`"']*                                          # verb runs into the URL
      |
      [^.!?\n]{0,30}\b#{PR_NOUN}\b[^.!?\n]{0,25}                # verb ... PR ... URL
    )
    \z
  /x

  # How much text before a URL is examined for a creation claim (or an
  # "already exists" message). Long enough for a normal sentence, short enough
  # that an unrelated earlier sentence cannot vouch for the URL.
  CLAIM_WINDOW = 160

  # A goal that talks about pull requests. Goals are free text (the goal
  # catalog's description is copied onto the session), so this is a phrase match,
  # not an id lookup. Case-sensitive for the "PR" abbreviation so that prose like
  # "pr" inside another word does not count.
  PR_GOAL_PATTERNS = [ /\bPRs?\b/, /\bpull\s+requests?\b/i ].freeze

  # The warning a PR-flavored goal gets when nothing was recorded. Its opening
  # clause doubles as the marker that keeps a session pausing ten times from
  # warning ten times — deduplicating on the log itself rather than on a
  # custom_metadata flag keeps this path out of the way of the hook's own
  # concurrent writes to that column.
  MISSING_PR_URL_WARNING = "[GitHub] No pull request URL was captured for this session, but its goal is about " \
                           "opening a PR. Zimmer only records a PR it can see this session open (a `gh pr create` " \
                           "result, or the agent saying it opened one), so GitHub comment and merge-conflict " \
                           "notifications are not running here."
  MISSING_PR_URL_WARNING_MARKER = "[GitHub] No pull request URL was captured"

  # Warn — once, in the session's own timeline — when a session whose goal is
  # about opening a pull request finishes a turn with no PR recorded. The whole
  # GitHub integration hangs off github_pull_request_urls, and its failure mode
  # is silence, so this is the one place that says the quiet part out loud.
  #
  # Called from the session state machine's `pause` (turn completion). Never
  # raises: a warning that breaks a state transition would be worse than the
  # thing it warns about.
  #
  # @param session [Session]
  # @return [void]
  def self.warn_if_pr_goal_captured_no_url(session)
    return if session.goal.blank?
    return unless PR_GOAL_PATTERNS.any? { |pattern| pattern.match?(session.goal) }

    return if session.custom_metadata&.dig("github_pull_request_urls").present?
    return if session.logs.where(level: "warning").where("content LIKE ?", "#{MISSING_PR_URL_WARNING_MARKER}%").exists?

    Rails.logger.warn(
      "[GithubPrUrlHook] Session #{session.id} paused with a pull-request goal but no PR URL captured; " \
      "GitHub comment and merge-conflict polling will not run for it"
    )
    session.logs.create!(level: "warning", content: MISSING_PR_URL_WARNING)
  rescue => e
    Rails.logger.error "[GithubPrUrlHook] Failed to warn about missing PR URL for session #{session.id}: #{e.message}"
  end

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

  # The PR URLs this transcript shows this session opening.
  # @return [Array<String>]
  def extract_pr_urls
    (urls_from_pr_create_results + urls_claimed_by_agent).uniq
  end

  # Evidence 1 and 2: the results of this session's own `gh pr create` calls.
  # A successful create vouches for any repo; a failed one vouches only for an
  # "already exists" URL on the session's own repo.
  #
  # For Claude the failure flag is the result's own is_error; for Codex it is
  # derived from the shell's exit code (see TranscriptHooks::CodexToolCallParser).
  def urls_from_pr_create_results
    pr_create_ids = collect_pr_create_tool_use_ids
    return [] if pr_create_ids.empty?

    tool_results.flat_map do |result|
      next [] unless pr_create_ids.include?(result[:id])
      next [] if result[:text].blank?

      pr_urls_with_context(result[:text]).filter_map do |url, preceding|
        if !result[:is_error]
          url
        elsif preceding.match?(PR_ALREADY_EXISTS_PATTERN) && same_repo?(url)
          url
        end
      end
    end
  end

  # Evidence 3: the agent's own prose claiming it opened a PR on this repo.
  # Deliberately limited to assistant messages — tool results are the world
  # talking (a `gh pr view` dump can quote anyone's "created PR <url>"), and user
  # messages include Zimmer's own PR notifications.
  def urls_claimed_by_agent
    return [] if target_owner_repo.nil?

    parser.assistant_texts.flat_map do |text|
      pr_urls_with_context(text).filter_map do |url, preceding|
        url if same_repo?(url) && preceding.match?(CREATION_CLAIM_PATTERN)
      end
    end
  end

  # Each GitHub PR URL in +text+, paired with the CLAIM_WINDOW characters
  # immediately preceding it — the run-up that has to vouch for the URL.
  #
  # @param text [String]
  # @return [Array<Array(String, String)>] [url, preceding_text] pairs
  def pr_urls_with_context(text)
    results = []
    position = 0

    while (match = GITHUB_PR_URL_PATTERN.match(text, position))
      window_start = [ match.begin(0) - CLAIM_WINDOW, 0 ].max
      results << [ match[0], text[window_start...match.begin(0)].to_s ]
      position = match.end(0)
    end

    results
  end

  # Whether +url+ points at the session's own repo. This is the original
  # false-positive guard, now used to qualify the weaker two kinds of evidence
  # rather than to stand in for evidence on its own.
  def same_repo?(url)
    return false if target_owner_repo.nil?

    url_match = url.match(%r{github\.com/([^/]+/[^/]+)/pull/\d+})
    return false unless url_match

    url_match[1].downcase.delete_suffix(".git") == target_owner_repo
  end

  def target_owner_repo
    return @target_owner_repo if defined?(@target_owner_repo)

    @target_owner_repo = extract_owner_repo_from_git_root&.downcase
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
