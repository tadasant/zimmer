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
#   1. CREATED — the URL appears in the output of a *successful* create: either
#      `gh pr create`, or a POST to a repo's REST `/pulls` collection
#      (`gh api repos/OWNER/REPO/pulls -X POST`), which is what an agent falls
#      back to when the GraphQL API behind `gh pr create` is down. The strongest
#      signal there is, so it holds for any repo: an agent running on
#      `owner/repo` that opens a PR against `other-org/other-repo` is tracked,
#      bounded only by the repo the command itself names — which a REST create
#      always does, in the endpoint path.
#   2. RE-CREATED — the URL appears in a *failed* create next to an "already
#      exists" message, i.e. the PR for the branch we just tried to push.
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
#   - The output of a `gh api repos/OWNER/REPO/pulls` that does not POST. Same
#     endpoint as the REST create above, opposite meaning: a GET is a *list* of
#     the repo's open PRs, which is the #214 shape again. Nor does a POST
#     somewhere else on the line make one: creates are read per command segment,
#     never across the whole script.
#   - The output of a command that merely *mentions* a create. `gh pr create`
#     inside a quoted argument to `grep`, `rg`, `sed` or `echo` is data, not an
#     invocation, and a command that searches this very file for the literal has
#     the header you are reading — example URL included — as its result (#772).
#     A create is read out of what a command runs, never out of what it quotes.
#   - A URL in a user message. Zimmer's own trigger prompts carry PR URLs
#     ("comment on your PR <url>"), so adopting them would let one misrouted
#     notification bootstrap a permanent wrong association.
#   - Anything in the part of a fork's transcript it did not write. A fork starts
#     life holding a copy of the source session's conversation, so the source's
#     own `gh pr create` sits in it as CREATED evidence. Only the messages after
#     the fork point are read; see `#own_parsed_transcript`.
#   - Anything at all in a status-summary fork's transcript, including the one
#     turn it writes itself. Such a fork exists to answer a question about
#     another session and opens nothing, ever. Guarded outright at the top of
#     `#call`, above and beyond the fork-point trim.
#
# Every rule above is a bet against the opposite failure — a session that opened a
# PR and has nothing recorded, which silently switches off every GitHub
# integration for it (#89). `.warn_if_pr_goal_captured_no_url` is the backstop:
# when a session with a PR-flavored goal comes to rest — finishing a turn,
# failing, or being archived — with an empty list, it says so once in the
# session timeline instead of failing quietly.
#
# Runtime support: both Claude Code and OpenAI Codex sessions are handled. The two
# runtimes write very different transcript shapes, so locating the creating
# invocations, their results, whether a result failed, and the agent's own prose is
# dispatched on the session's agent_runtime. That shape handling lives in
# TranscriptHooks::ToolCallParser, which this hook shares with
# GithubCommentAuthorshipHook.
#
# This hook is registered by default via the transcript hooks initializer.
#
class TranscriptHooks::GithubPrUrlHook < TranscriptHooks::BaseHook
  # A tool call's command is a whole shell script, and a create has to be read out
  # of the one command that ran it rather than the line it shares.
  include TranscriptHooks::ShellSegments

  # Regex pattern to match GitHub PR URLs
  # Captures URLs like: https://github.com/owner/repo/pull/123
  # Uses explicit character classes to prevent subdomain spoofing attacks
  # (e.g., github.com.evil.com would NOT match)
  GITHUB_PR_URL_PATTERN = %r{https://github\.com/[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+/pull/\d+}

  # `gh pr create` as a command being run — which is not the same thing as the
  # literal appearing in one. It is matched against the segment's #unquoted view
  # (TranscriptHooks::ShellSegments), so the same three words handed to another
  # command as *data* count for nothing: session 11898 ran
  # `grep -n "def \|pull/\|gh pr create\|..." github_pr_url_hook.rb` over this very
  # file, and its result — the header you are reading, example URL included — was
  # read as a PR that session had opened (#772). `rg 'gh pr create'`, an `echo`,
  # and a `sed` script are the same shape.
  #
  # Matched anywhere in what survives that, deliberately, rather than at the front
  # of the segment. A create sits behind all sorts of things in command position —
  # `cd ... &&`, `GH_TOKEN=x`, `timeout 120`, `until ...; do`, `sudo -E`, `xargs`,
  # Codex's `bash -lc` wrapper — and an anchor drops every one it does not
  # enumerate. Missing a real create is the worse failure of the two: it switches
  # every GitHub integration off for that session, in silence (#89).
  #
  # Still a heuristic, not a shell parser. Two shapes read as an invocation and are
  # not one: an unquoted mention (`echo gh pr create`, a `#` comment), and a line
  # of a heredoc body, which is quoted by the heredoc rather than by anything this
  # can see.
  GH_PR_CREATE_PATTERN = /\bgh\s+pr\s+create\b/

  # `gh pr create` goes through GitHub's GraphQL API, and when that API is down
  # the REST API usually is not — so the fallback an agent reaches for is
  # `gh api repos/OWNER/REPO/pulls -X POST`. A GitHub outage on 2026-08-17
  # produced exactly that, wrapped in a retry loop, and the PR it opened was
  # recorded nowhere: #89's failure arriving through a creation path this hook
  # did not know about.
  #
  # A REST create is recognised from three things holding in ONE command segment
  # (TranscriptHooks::ShellSegments): the segment runs `gh api`, it addresses a
  # repo's `/pulls` collection, and it POSTs. Segment, not shell line, because
  # `gh api repos/o/r/pulls --jq '.[]' && gh api repos/o/r/issues/1/comments -X POST`
  # is a *list* next to an unrelated write, and reading the two together adopts
  # every PR the list printed — #214 through a new door.
  GH_API_PATTERN = /\Agh\s+api\b/

  # An explicit method flag, whatever it names: `-X POST`, `-XPOST`,
  # `--method POST`, `--method=POST` — and equally `-X GET`, which is what makes
  # this a capture rather than a POST test. An explicit method is authoritative,
  # so `gh api repos/o/r/pulls -X GET -f state=open` stays a list.
  HTTP_METHOD_FLAG_PATTERN = /(?<![\w-])(?:-X|--method)[=\s]*["']?([A-Za-z]+)/

  # `gh api` sends GET until a parameter is supplied and POST from then on, so a
  # bare field flag is as much a create as an explicit method — and it is the
  # shorter spelling an agent is likely to reach for. (The sibling hook,
  # GithubCommentAuthorshipHook, reads `gh api` writes the same way.)
  GH_API_FIELD_FLAG_PATTERN = /(?<![\w-])(?:-f|-F|--field|--raw-field|--input)[=\s]/

  # The `repos/<slug>/pulls` collection, and nothing nested under it: a POST to
  # `.../pulls/7/reviews` or `.../pulls/7/comments` writes *about* a pull request
  # rather than opening one. The endpoint may be bare or a full
  # `https://api.github.com/...` URL; both carry this path.
  GH_API_PULLS_ENDPOINT_PATTERN = %r{\brepos/([^\s"';|&]+)/pulls(?![\w/])}

  # A slug that names its repo outright. An endpoint can also carry `gh`'s own
  # `{owner}/{repo}` placeholders or a shell variable the script expanded
  # (`repos/$SLUG/pulls`) — both of which resolve, in practice, to the clone the
  # command runs in, and neither of which can be read out of the text.
  STATIC_OWNER_REPO_PATTERN = %r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}

  # Cheap precheck before a command is segmented: most shell calls in a transcript
  # are neither kind of create, and segmenting every one of them (commands include
  # whole heredoc bodies) to find that out is wasted work.
  GH_CREATE_INVOCATION_PATTERN = /\bgh\s+(?:pr\s+create|api)\b/

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
                           "for it yet. Zimmer records only a PR it can see the session open (the result of a " \
                           "`gh pr create` or a REST create, or the agent saying it opened one), so GitHub " \
                           "comment and merge-conflict notifications are not running here."
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
    #
    # Kept as its own outright guard even though #own_parsed_transcript now drops
    # every fork's copied prefix. That trim would already have prevented the
    # production page — a summary fork is forked at the source's *last* message,
    # so the whole of the source's conversation, creates included, is prefix —
    # but it is not the same statement. This one says the stronger thing: a
    # session Zimmer created to write a blurb opens nothing, ever, so not even
    # its own turn counts. And it holds without depending on the fork point
    # having been recorded.
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

  # Evidence 1 and 2: the results of this session's own PR-creating calls —
  # `gh pr create`, and REST creates POSTing to a repo's `/pulls` collection.
  # A successful create vouches for any repo; a failed one vouches only for an
  # "already exists" URL on the session's own repo.
  #
  # What the creates in the command name — a `--repo` flag, or the endpoint a REST
  # create posts to — bounds what the result can vouch for. A command is a whole
  # shell script, so one result can hold URLs its create had nothing to do with:
  # `gh pr create --repo a/b && gh pr list --repo c/d` puts both repos' URLs in
  # one result, and without the bound the second repo's PRs would be adopted on
  # the strength of the first repo's create.
  #
  # For Claude the failure flag is the result's own is_error; for Codex it is
  # derived from the shell's exit code (see TranscriptHooks::CodexToolCallParser).
  def urls_from_pr_create_results
    return [] if pr_create_commands.empty?

    tool_results.flat_map do |result|
      command = pr_create_commands[result[:id]]
      next [] if command.nil? || result[:text].blank?

      target_repos = unbounded_create?(command) ? nil : create_repos(command)

      pr_urls_with_context(result[:text]).filter_map do |url, preceding|
        if result[:is_error]
          url if preceding.match?(PR_ALREADY_EXISTS_PATTERN) && same_repo?(url)
        elsif target_repos.nil? || same_repo?(url) || target_repos.include?(url_owner_repo(url))
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
  #
  # Built over #own_parsed_transcript, so every one of the three evidence rules
  # sees only what this session wrote.
  def parser
    @parser ||= TranscriptHooks::ToolCallParser.for(session: session, parsed_transcript: own_parsed_transcript)
  end

  # The part of this transcript that is this session's own.
  #
  # For everything except a fork that is the whole thing. A fork is different:
  # ForkSessionService gives it a *copy* of the source session's conversation up
  # to the fork point, so the source's own `gh pr create` — its output, the
  # command that produced it, and any prose claiming it — is sitting in the
  # fork's transcript from the moment the fork exists. Reading it credits the
  # fork with pull requests the source opened, and `Session.with_github_prs` then
  # enrols both sessions in all three GitHub pollers: one review comment draws
  # two independent agent responses, and the merge and merge-conflict notices go
  # to both (#556, the shape #214 warns about).
  #
  # Dropping the copied prefix — rather than declining to record anything for a
  # fork at all, which is what a status-summary fork gets — is what keeps the
  # other half true. A user fork is a live working session that may go on to open
  # pull requests of its own, and those must still be recorded, or the fix would
  # silently switch off every GitHub integration for a session that really did
  # open the PR (#89). The fork point is the line between the two: evidence at or
  # before `forked_at_message_index` is the source's, evidence after it is the
  # fork's.
  #
  # A transcript shorter than the prefix it is supposed to carry leaves nothing,
  # which is the right answer rather than a fallback: there is no message here
  # this session is known to have written.
  def own_parsed_transcript
    @own_parsed_transcript ||= parsed_transcript.drop(session.inherited_transcript_message_count)
  end

  # The PR-creating invocations in this transcript — `gh pr create` and REST
  # creates alike — keyed by tool-call id (Claude tool_use ids / Codex call_ids).
  # Their results are what this hook treats as authoritative for "this session
  # opened this PR", and their command text is what bounds the repo a result can
  # vouch for.
  #
  # @return [Hash{String => String}] tool-call id => shell command
  def pr_create_commands
    @pr_create_commands ||= parser.shell_calls.each_with_object({}) do |call, commands|
      next unless creates_pr?(call[:command])

      commands[call[:id]] = call[:command]
    end
  end

  # Whether +command+ opens a pull request at all, by either route.
  def creates_pr?(command)
    unbounded_create?(command) || create_repos(command).any?
  end

  # Whether any segment of +command+ opens a pull request without naming the repo
  # it lands on. `gh pr create` from a fork clone does exactly that — the PR lands
  # on the parent repo, which the command never mentions — so such a create keeps
  # vouching for any repo, as it always has. A REST create is never unbounded: its
  # endpoint names the repo.
  def unbounded_create?(command)
    return false unless command.match?(GH_CREATE_INVOCATION_PATTERN)

    segments_of(command).any? do |segment|
      gh_pr_create?(segment) && !segment.match?(REPO_FLAG_PATTERN)
    end
  end

  # Every repo the creates in +command+ name: the `--repo` of a `gh pr create`
  # segment, and the `/pulls` endpoint of a REST create segment. Read per segment,
  # so a `--repo` belonging to some other subcommand on the line cannot bound a
  # create, and a create in one segment cannot vouch for a list in another.
  #
  # The flag is read off the raw segment while the create is read off the unquoted
  # one, and the asymmetry is deliberate: `--repo "owner/name"` is a quoted *value*
  # that the create needs, where `gh pr create` inside quotes is somebody else's
  # argument.
  #
  # @return [Array<String>] downcased `owner/repo`, possibly empty
  def create_repos(command)
    return [] unless command.match?(GH_CREATE_INVOCATION_PATTERN)

    segments_of(command).flat_map do |segment|
      if gh_pr_create?(segment)
        segment.scan(REPO_FLAG_PATTERN).flatten.map { |repo| normalize_repo(repo) }
      elsif rest_pr_create?(segment)
        rest_create_repos(segment)
      else
        []
      end
    end.uniq
  end

  # Whether one command segment runs `gh pr create`, read against what the segment
  # runs rather than what it quotes (see GH_PR_CREATE_PATTERN). Memoized alongside
  # the split, since a transcript is rescanned on every broadcast and both
  # `unbounded_create?` and `create_repos` ask the same question of every segment.
  def gh_pr_create?(segment)
    @gh_pr_create ||= {}
    @gh_pr_create.fetch(segment) { @gh_pr_create[segment] = unquoted(segment).match?(GH_PR_CREATE_PATTERN) }
  end

  # Whether one command segment opens a pull request through the REST API: it runs
  # `gh api`, it addresses a repo's `/pulls` collection, and it POSTs. An explicit
  # method flag is authoritative — `-X GET` on that endpoint is a list, fields or
  # no fields — and without one, a field flag is what turns `gh api` into a POST.
  def rest_pr_create?(segment)
    return false unless segment.match?(GH_API_PATTERN)
    return false unless segment.match?(GH_API_PULLS_ENDPOINT_PATTERN)

    method = segment[HTTP_METHOD_FLAG_PATTERN, 1]
    return method.casecmp?("POST") if method

    segment.match?(GH_API_FIELD_FLAG_PATTERN)
  end

  # The repos a REST create segment names. Every `/pulls` endpoint in the segment
  # counts, because the first one is not reliably the one being posted to (a
  # `-f body="see repos/c/d/pulls"` puts another repo's path in front of it).
  #
  # A slug the text cannot resolve — `gh`'s `{owner}/{repo}` placeholders, or a
  # shell variable — is `gh`'s stand-in for the clone's own remote, so that is what
  # it resolves to. When the clone is not a GitHub repo there is nothing to resolve
  # it to and nothing to bound the result with; the segment then names no repo,
  # which leaves it as no evidence at all rather than as evidence for every URL in
  # its output.
  def rest_create_repos(segment)
    segment.scan(GH_API_PULLS_ENDPOINT_PATTERN).flatten.filter_map do |slug|
      slug.match?(STATIC_OWNER_REPO_PATTERN) ? normalize_repo(slug) : target_owner_repo
    end.uniq
  end

  # The commands inside one shell command, memoized: a transcript is rescanned on
  # every broadcast, and each of `creates_pr?`, `unbounded_create?` and
  # `create_repos` asks for the same split.
  def segments_of(command)
    @segments_of ||= {}
    @segments_of[command] ||= shell_segments(command)
  end

  def normalize_repo(repo)
    repo.downcase.delete_suffix(".git")
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
