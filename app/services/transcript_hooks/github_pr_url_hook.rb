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
#   - A same-repo URL sitting in an unrelated tool result. Matching on the repo
#     alone hands a session that merely ran `gh pr view` (a merge gate, a
#     reviewer, anything reading the repo's PR list) someone else's PR as its
#     own — and with it that PR's comments and merge-conflict notifications
#     (#214).
#   - A URL in a user message. Zimmer's own trigger prompts carry PR URLs
#     ("comment on your PR <url>"), so adopting them would let one misrouted
#     notification bootstrap a permanent wrong association.
#   - Anything at all in a status-summary fork's transcript, which is a copy of
#     the source session's and therefore shows the *source* opening PRs. See the
#     guard at the top of `#call`.
#
# Every rule above is a bet against the opposite failure — a session that opened a
# PR and has nothing recorded, which silently switches off every GitHub
# integration for it (#89). `.warn_if_pr_goal_captured_no_url` is the backstop:
# when a session with a PR-flavored goal comes to rest — finishing a turn,
# failing, or being archived — with an empty list, it says so once in the
# session timeline instead of failing quietly.
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
  # literal embedded in a heredoc body would also match). A false positive costs
  # the same-repo guard on that one tool result, which is why the repo a command
  # names (REPO_FLAG_PATTERN) bounds what its result can vouch for.
  GH_PR_CREATE_PATTERN = /\bgh\s+pr\s+create\b/

  # The `--repo owner/name` (or `-R owner/name`) a `gh` command targets.
  REPO_FLAG_PATTERN = /(?:--repo|-R)[=\s]+["']?([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)/

  # `gh pr create` exits non-zero when the branch already has a PR, printing
  # "a pull request for branch \"x\" into branch \"main\" already exists: <url>".
  # That URL is the PR for the branch this session just pushed, so it is ours —
  # unlike the other ways a create can fail (auth, protected branch), which do
  # not name a PR at all.
  PR_ALREADY_EXISTS_PATTERN = /already exists/i

  # A creation claim in the agent's own prose. Two shapes are accepted, both
  # requiring the claim to sit immediately before the URL with no sentence break
  # in between:
  #   - a completed creation verb running straight into the URL ("I've opened <url>")
  #   - a creation verb, a PR noun, then the URL ("Created the draft PR at <url>")
  #
  # Only inflected verbs count, never the bare stem. "Open" is an adjective as
  # often as it is a verb, and "the open PR: <url>" or "two open PRs: <url>" is
  # exactly how prose refers to *someone else's* PR — the reading this hook exists
  # to reject. For the same reason the adjacent-to-URL shape takes past tense only:
  # "Opening <url>" is what an agent says about a page it is about to read.
  #
  # The PR noun is what keeps "creating a plan to review <url>" out: an agent
  # narrating work *about* a PR does not use that shape.
  #
  # All three are case-insensitive in their own right: an interpolated Regexp
  # keeps its own flags, so an outer /i would not reach them ("Opened" would never
  # match a lowercase-only verb list).
  COMPLETED_CREATION_VERB = /(?:opened|created|submitted|raised|filed)/i
  CREATION_VERB = /(?:open(?:ed|ing)|creat(?:ed|ing)|submit(?:ted|ting)|rais(?:ed|ing)|fil(?:ed|ing))/i
  PR_NOUN = /(?:PRs?|pull\s+requests?)/i
  CREATION_CLAIM_PATTERN = /
    (?:
      \b#{COMPLETED_CREATION_VERB}\b[\s:\-—>*_`"']*             # verb runs into the URL
      |
      \b#{CREATION_VERB}\b[^.!?\n]{0,30}\b#{PR_NOUN}\b[^.!?]{0,25}   # verb ... PR ... URL
    )
    \z
  /x

  # How much text before a URL is examined for a creation claim (or an
  # "already exists" message). Long enough for a normal sentence, short enough
  # that an unrelated earlier sentence cannot vouch for the URL.
  CLAIM_WINDOW = 160

  # A goal that asks for a pull request to be *opened*. Goals are free text (the
  # goal catalog's description is copied onto the session), so this is a phrase
  # match, not an id lookup — and it has to be a phrase match rather than a bare
  # "does the goal say PR", because the catalog's read-only goal says "do not
  # create files, PRs, or branches", which mentions PRs precisely to forbid them.
  PR_GOAL_PATTERNS = [
    /\bopen-pr\b/i,                                                            # the skill that opens one
    /\b#{PR_NOUN}\b[^.\n]{0,25}\bis\s+open/i,                                  # "the PR is open"
    # "open a reviewed, green PR". Not the "file" stem: "files, PRs" is a noun.
    /\b(?:open|creat|submit|rais)\w*[,\s]+
     (?:(?:a|an|the|your|one|another|new|draft|reviewed|green|unmerged)[,\s]+)*
     #{PR_NOUN}\b/xi
  ].freeze

  # The warning a PR-flavored goal gets when nothing was recorded. Its opening
  # clause doubles as the marker that keeps a session pausing ten times from
  # warning ten times — deduplicating on the log itself rather than on a
  # custom_metadata flag keeps this path out of the way of the hook's own
  # concurrent writes to that column.
  MISSING_PR_URL_WARNING = "[GitHub] This session's goal asks for a pull request, and no PR URL has been captured " \
                           "for it yet. Zimmer records only a PR it can see the session open (a `gh pr create` " \
                           "result, or the agent saying it opened one), so GitHub comment and merge-conflict " \
                           "notifications are not running here."
  MISSING_PR_URL_WARNING_MARKER = "[GitHub] This session's goal asks for a pull request"

  # Warn — once, in the session's own timeline — when a session whose goal is
  # about opening a pull request reaches a rest state with no PR recorded. The
  # whole GitHub integration hangs off github_pull_request_urls, and its failure
  # mode is silence, so this is the one place that says the quiet part out loud.
  #
  # Called from the session state machine's three rest states: `pause` (turn
  # completion), `fail` and `archive` — the transitions after which nothing runs
  # unless a person comes back to the session. `pause` is every hand-back to the
  # user, not only the last one, so it catches the miss while the same session
  # can still act on it. `fail` and `archive` catch the ones `pause` never sees:
  # a session that dies mid-turn, or is trashed straight from `needs_input`,
  # would otherwise be recorded nowhere at all (#313).
  #
  # `failed` and `archived` are not literally terminal — `resume` runs from
  # `failed` and `unarchive_to_*` from `archived` — so this shares `pause`'s
  # point-in-time honesty: the warning states what was true when it was written
  # ("no PR URL yet") and is never retracted if the session is revived and does
  # open one.
  #
  # Repeats are the dedup guard's job, not the call site's. The guard below
  # looks for an existing MISSING_PR_URL_WARNING_MARKER log on the session, so
  # every call site shares one budget of one warning per session: a session that
  # pauses, warns, and later archives says it once. That is why adding call
  # sites costs nothing in timeline spam.
  #
  # Never raises: a warning that breaks a state transition would be worse than
  # the thing it warns about — and on `fail` and `archive` it would break a
  # transition that is running cleanup.
  #
  # @param session [Session]
  # @return [void]
  def self.warn_if_pr_goal_captured_no_url(session)
    # A status-summary fork is Zimmer's own throwaway and never opens anything.
    # It cannot be left to the goal check below: SessionStatusSummaryGenerator
    # strips the inherited goal in `prepare_fork`, but `abandon_fork` archives a
    # fork made before that point — which still carries the source's "open a PR"
    # and an empty URL list — so the goal is only usually nil by then.
    return if session.status_summary_fork?
    return if session.goal.blank?
    return unless PR_GOAL_PATTERNS.any? { |pattern| pattern.match?(session.goal) }

    return if session.custom_metadata&.dig("github_pull_request_urls").present?
    return if session.logs.where(level: "warning").where("content LIKE ?", "#{MISSING_PR_URL_WARNING_MARKER}%").exists?

    Rails.logger.warn(
      "[GithubPrUrlHook] Session #{session.id} came to rest with a pull-request goal but no PR URL " \
      "captured; GitHub comment and merge-conflict polling will not run for it"
    )
    session.logs.create!(level: "warning", content: MISSING_PR_URL_WARNING)
  rescue => e
    Rails.logger.error "[GithubPrUrlHook] Failed to warn about missing PR URL for session #{session.id}: #{e.message}"
  end

  def call
    # A status-summary fork opens nothing, and it is the one session whose
    # transcript is not its own: SessionStatusSummaryGenerator forks the source
    # session, so every `gh pr create` the source ever ran is sitting in the
    # fork's copied transcript. Every rule below then reads as CREATED evidence
    # and credits the fork with the source's pull requests.
    #
    # That is not a cosmetic misattribution. `Session.with_github_prs` is keyed
    # on this list for any session that is not archived or failed, so the
    # credited fork joins the PR, comment and
    # merge-conflict pollers — and the PR poller answers an open -> merged
    # transition by queueing "your PR merged, you may archive" onto it. The fork
    # is Zimmer's own throwaway: nobody reads it, and the harvest job archives it
    # as soon as the blurb is out, which retires that message `undelivered` and
    # pages. Production session 6335 was credited with all seven of session 684's
    # pull requests 16 seconds after it was forked, and stranded the merge
    # notification for one of them ~10 minutes later.
    #
    # `warn_if_pr_goal_captured_no_url` already declines to reason about a fork's
    # empty list for the same reason; this is the writing half of that guard.
    return if session.status_summary_fork?

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
  # When the command names its target with `--repo`, that name bounds what the
  # result can vouch for. A command is a whole shell line — `gh pr create --repo
  # a/b && gh pr list --repo c/d` puts both repos' URLs in one result — and
  # without the bound the second repo's PRs would be adopted on the strength of
  # the first repo's create.
  #
  # For Claude the failure flag is the result's own is_error; for Codex it is
  # derived from the shell's exit code (see TranscriptHooks::CodexToolCallParser).
  def urls_from_pr_create_results
    return [] if pr_create_commands.empty?

    tool_results.flat_map do |result|
      command = pr_create_commands[result[:id]]
      next [] if command.nil? || result[:text].blank?

      target_repo = repo_named_by(command)

      pr_urls_with_context(result[:text]).filter_map do |url, preceding|
        if result[:is_error]
          url if preceding.match?(PR_ALREADY_EXISTS_PATTERN) && same_repo?(url)
        elsif target_repo.nil? || same_repo?(url) || url_owner_repo(url) == target_repo
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

  # Whether +url+ points at the session's own repo. This qualifies the two weaker
  # kinds of evidence; it never stands in for evidence on its own.
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

  # The `gh pr create` invocations in this transcript, keyed by tool-call id
  # (Claude tool_use ids / Codex call_ids). Their results are what this hook
  # treats as authoritative for "this session opened this PR", and their command
  # text is what bounds the repo a result can vouch for.
  #
  # @return [Hash{String => String}] tool-call id => shell command
  def pr_create_commands
    @pr_create_commands ||= parser.shell_calls.each_with_object({}) do |call, commands|
      commands[call[:id]] = call[:command] if call[:command].match?(GH_PR_CREATE_PATTERN)
    end
  end

  # The `owner/repo` a command targets explicitly, or nil when it targets the
  # clone it runs in (the fork-and-upstream case, where the PR lands on a repo
  # the command never names).
  def repo_named_by(command)
    match = command.match(REPO_FLAG_PATTERN)
    match && match[1].downcase.delete_suffix(".git")
  end

  # The `owner/repo` a PR URL belongs to.
  def url_owner_repo(url)
    match = url.match(%r{github\.com/([^/]+/[^/]+)/pull/\d+})
    match && match[1].downcase.delete_suffix(".git")
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
