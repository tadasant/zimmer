# frozen_string_literal: true

module Github
  # Polls the comments on a session's tracked pull requests and hands the ones a human
  # wrote back to the session as follow-up prompts.
  #
  # Driven by Github::PrPollPass, which owns the enumeration, the backoff gate and the
  # url parsing. Its two comment endpoints are the pass's only fetch that is NOT served
  # by Github::PrSnapshot — issue comments and review comments are separate resources
  # from the PR object, so they stay their own calls.
  #
  # Tracks comments in custom_metadata as github_comments:
  # {
  #   "github_comments" => {
  #     "https://github.com/owner/repo/pull/123" => {
  #       "pr_comments" => [
  #         { "id" => 123, "author" => "user", "attribution" => "user", "body" => "...", "url" => "...", "created_at" => "...", "dispatch_state" => "dispatched" },
  #         { "id" => 456, "author" => "agent-user", "attribution" => "self", "body" => "[CC Says]...", "url" => "...", "created_at" => "...", "dispatch_state" => "skipped:self_marker" }
  #       ],
  #       "review_comments" => [
  #         { "id" => 789, "author" => "user", "attribution" => "user", "body" => "...", "url" => "...", "path" => "...", "line" => 42, "diff_hunk" => "...", "created_at" => "...", "dispatch_state" => "dispatched" }
  #       ]
  #     }
  #   }
  # }
  #
  # Attribution logic:
  # - Comments containing "[CC Says]" are attributed to "self" (the agent)
  # - All other comments are attributed to the author username
  #
  # When a whitelisted user (tadasant, macoughl) makes a new comment,
  # a follow-up prompt is automatically enqueued for the session.
  #
  # `dispatch_state` records what the poller decided about each comment, so a comment
  # that never woke a session leaves a trace. It is one of:
  #   "dispatched"       — a follow-up prompt went out
  #   "dispatching"      — handed over, outcome not yet recorded (see DISPATCH_DISPATCHING)
  #   "deferred"         — not decidable yet; re-examined on the next poll
  #   "skipped:<reason>" — terminal; never reconsidered
  #
  # Three classes of comment are deliberately skipped even though their author is
  # whitelisted: comments a Zimmer session posted itself (see agent_posted_comment,
  # skipped:agent_posted), Zimmer's own automation reports (see
  # AUTOMATION_REPORT_HEADINGS) and bot commands (see BLACKLISTED_PATTERNS). Skipped
  # comments are still recorded in custom_metadata; they just don't wake the session,
  # and they get no 👀 reaction.
  #
  # Why agent-posted comments need their own check: every session's `gh` authenticates
  # as the human, so authorship cannot separate them. AgentPostedGithubComment carries
  # what GitHub can't — the comment ids Zimmer watched its own sessions post. The check
  # is global rather than per-session because the loop it closes is: routing is by
  # tracked PR URL, so session A's comment was dispatched to session B, which had no
  # way to recognize it as an agent's.
  #
  class CommentEvaluator
    include DatabaseRetry

    # Marker that identifies agent-generated comments
    AGENT_COMMENT_MARKER = "[CC Says]"

    # Patterns that should be ignored when processing comments for follow-up prompts
    # These are typically bot commands or automated messages that shouldn't trigger agent responses
    BLACKLISTED_PATTERNS = [
      /\A\/deploy staging\z/i  # Exact match for "/deploy staging" command
    ].freeze

    # Reports posted by Zimmer's own PR automation, matched by the heading they open with.
    #
    # These are published with `gh` authenticated as a human account -- the pr-merge-gate
    # rating comes from `tadasant` -- and carry no AGENT_COMMENT_MARKER, so neither the
    # author whitelist nor the attribution check keeps them out. Recognizing them here, in
    # Zimmer, is deliberate: an automation should not have to remember to opt in with a
    # marker for the session it reports on to stay asleep.
    #
    # Add the heading of any new automation report to this list. The match is on the whole
    # heading text, exactly, after downcasing and squishing -- heading level, leading emoji
    # and a closing "#" run are stripped, but nothing else is. A report that grew a suffix
    # ("## 🚀 Merge gate: AUTO-MERGE") no longer matches and needs its own entry.
    AUTOMATION_REPORT_HEADINGS = [
      "merge gate"  # pr-merge-gate's rating: "## 🚀 Merge gate"
    ].freeze

    # A Markdown heading, with the level, any emoji or other decoration before the text, and
    # a closing "#" run all discarded: "## 🚀 Merge gate", "### Merge gate", "# 🚦 merge
    # gate" and "## Merge gate ##" all yield "Merge gate".
    AUTOMATION_HEADING_PATTERN = /\A[#]{1,6}\s*\P{Alnum}*\s*(?<title>.+?)\s*[#]*\s*\z/

    # Maximum comments to fetch per API call (GitHub's default is 30, max is 100)
    MAX_COMMENTS_PER_PAGE = 100

    # Values of a comment's "dispatch_state" (see the class comment).
    DISPATCH_DISPATCHED = "dispatched"
    DISPATCH_DEFERRED = "deferred"
    # Written before the follow-up is handed over and replaced with the outcome after.
    # Terminal if the process dies in between: better a comment that says it was being
    # dispatched than one that is dispatched afresh on every poll.
    DISPATCH_DISPATCHING = "dispatching"

    # How long a comment must exist before the poller will act on it.
    #
    # Authorship is settled by TranscriptHooks::GithubCommentAuthorshipHook, which runs
    # when the posting session's transcript is next polled — a second or two while the
    # session is running, but not instantaneous. Without a hold-down, a poll that lands
    # in that window sees an agent's comment with no AgentPostedGithubComment row yet and
    # dispatches it, which is the whole bug. 60 seconds is far longer than the observed
    # hook latency and costs a human's comment at most one extra minute before it wakes
    # a session — on top of the poller's own 30-second cadence.
    ATTRIBUTION_GRACE_SECONDS = 60

    # How long to keep retrying a repo-visibility lookup that keeps failing before
    # giving up on the comment. Bounded so a permanently unanswerable repo (renamed,
    # deleted, access revoked) stops costing a `gh api` call every poll forever.
    VISIBILITY_RETRY_WINDOW_SECONDS = 1.hour.to_i

    # Wall-clock bounds on the `gh` children this job spawns, process group killed on
    # deadline. This job is a `total_limit: 1` singleton, so an unbounded hang holds the
    # only slot and every later tick is a no-op enqueue — comments stop waking sessions
    # with nothing raised and no watchdog to notice (#458).
    #
    # PER PAGE, not per fetch. The comment read is a pagination loop, and a bound on the
    # whole loop would either be too tight for a long thread or so loose it stopped
    # bounding anything. Each page is one `gh api` round trip and gets its own deadline;
    # a page that times out ends the loop exactly the way a non-zero exit already does —
    # return the pages we have, ask again next tick.
    COMMENT_PAGE_TIMEOUT = 20

    # The 👀 reaction is a single cheap POST and it is best-effort by design: the
    # follow-up prompt goes out whether or not the reaction lands. Shorter than the
    # reads, because waiting on it delays a prompt that does not depend on it.
    REACTION_TIMEOUT = 10

    # @param session [Session]
    # @param refs [Array<Github::PrRef>] the session's tracked PRs, already resolved
    # @return [void]
    def evaluate(session, refs)
      return if refs.empty?

      current_comments = session.custom_metadata&.dig("github_comments") || {}
      tracking_timestamps = session.custom_metadata&.dig("github_pr_tracking_started_at") || {}
      updated_comments = current_comments.deep_dup
      new_user_comments = []

      refs.each do |ref|
        pr_url = ref.url
        owner = ref.owner
        repo = ref.repo
        pr_number = ref.number
        pr_key = pr_url

        # Get the timestamp when this PR started being tracked by this session
        # Only comments created after this time should trigger follow-up prompts
        tracking_started_at = tracking_timestamps[pr_key]

        # Initialize structure for this PR if needed
        updated_comments[pr_key] ||= {}
        updated_comments[pr_key]["pr_comments"] ||= []
        updated_comments[pr_key]["review_comments"] ||= []

        # Fetch PR-level comments (issue comments on the PR)
        pr_comments = fetch_pr_comments(owner, repo, pr_number)
        if pr_comments
          new_user_comments.concat(
            evaluate_comments(
              type: "pr",
              fetched: pr_comments,
              stored: updated_comments[pr_key]["pr_comments"],
              tracking_started_at: tracking_started_at,
              pr_url: pr_url, owner: owner, repo: repo, pr_number: pr_number
            )
          )
        end

        # Fetch review comments (inline comments on diffs)
        review_comments = fetch_review_comments(owner, repo, pr_number)
        if review_comments
          new_user_comments.concat(
            evaluate_comments(
              type: "review",
              fetched: review_comments,
              stored: updated_comments[pr_key]["review_comments"],
              tracking_started_at: tracking_started_at,
              pr_url: pr_url, owner: owner, repo: repo, pr_number: pr_number
            )
          )
        end
      end

      # Persist before dispatching, so a comment cannot be handed to the session
      # repeatedly if the write later fails; the state recorded here is "dispatching",
      # which is terminal. A process killed mid-dispatch therefore leaves a comment that
      # says what happened to it rather than one that silently never arrives.
      persisted = persist_comments!(session, updated_comments, current_comments)

      # Each call records its own outcome on the (shared, mutable) comment hash, so the
      # second write persists the decision that was actually made. enqueue_follow_up_prompt
      # rescues its own errors, so this cannot skip that write.
      new_user_comments.each do |comment_info|
        comment_info[:data]["dispatch_state"] = enqueue_follow_up_prompt(session, comment_info)
      end

      persist_comments!(session, updated_comments, persisted)
    end

    private

    # Write the comment blob when it differs from what is already stored.
    #
    # @param previous [Hash] the blob as last persisted
    # @return [Hash] the blob now persisted (a snapshot, since updated_comments mutates)
    def persist_comments!(session, updated_comments, previous)
      return previous if updated_comments == previous

      with_db_retry { session.merge_custom_metadata!("github_comments" => updated_comments) }
      Rails.logger.info "[Github::CommentEvaluator] Updated comments for session #{session.id}"

      updated_comments.deep_dup
    end

    # Decide what to do with every comment of one kind on one PR, recording the
    # decision on each comment hash.
    #
    # Comments already stored are skipped unless they are "deferred" — those are the
    # ones whose authorship could not be settled yet, and they are re-examined until
    # they resolve. Everything else has a terminal state and is left alone.
    #
    # @return [Array<Hash>] comment_info hashes for the comments to dispatch
    def evaluate_comments(type:, fetched:, stored:, tracking_started_at:, pr_url:, owner:, repo:, pr_number:)
      to_dispatch = []

      fetched.each do |comment|
        existing = stored.find { |c| c["id"] == comment["id"] }

        if existing
          next unless existing["dispatch_state"] == DISPATCH_DEFERRED

          comment_data = existing
        else
          comment_data = if type == "review"
            build_review_comment_data(comment, pr_url, pr_number)
          else
            build_pr_comment_data(comment, pr_url, pr_number)
          end
          stored << comment_data
        end

        state = dispatch_state_for(comment_data, type: type, tracking_started_at: tracking_started_at)
        comment_data["dispatch_state"] = state
        next unless state == DISPATCH_DISPATCHING

        to_dispatch << { type: type, data: comment_data, pr_url: pr_url, owner: owner, repo: repo, pr_number: pr_number }
      end

      to_dispatch
    end

    # Whether a comment should wake the session, and if not, why not.
    #
    # Returns DISPATCH_DISPATCHING (enqueue_follow_up_prompt has the final say),
    # DISPATCH_DEFERRED, or "skipped:<reason>".
    def dispatch_state_for(comment_data, type:, tracking_started_at:)
      return "skipped:self_marker" if comment_data["attribution"] == "self"
      return "skipped:author_not_whitelisted" unless GithubCommentAllowlist.trusted?(comment_data["author"])

      ignored = ignored_reason(comment_data)
      return "skipped:#{ignored}" if ignored
      return "skipped:before_tracking" unless comment_created_after_tracking_started?(comment_data, tracking_started_at)

      posted = agent_posted_comment(comment_data, type: type)
      if posted
        Rails.logger.info "[Github::CommentEvaluator] Ignoring comment #{comment_data['id']} (#{comment_data['url']}): posted by session #{posted.session_id || 'unknown'}, not by a human"
        return "skipped:agent_posted"
      end

      return DISPATCH_DEFERRED unless attribution_settled?(comment_data)

      DISPATCH_DISPATCHING
    end

    # The record of a Zimmer session having posted this comment, or nil.
    #
    # This is the check the author name cannot make: `gh` in every session
    # authenticates as the human, so an agent's comment and a human's comment are the
    # same `user.login`. TranscriptHooks::GithubCommentAuthorshipHook writes the row
    # when it sees the posting tool call; the lookup is global, so a comment posted by
    # one session is suppressed for every session tracking the PR.
    def agent_posted_comment(comment_data, type:)
      AgentPostedGithubComment.posted_by_agent(comment_type: type, comment_id: comment_data["id"])
    rescue StandardError => e
      # Fail open rather than swallow the human's comment: a DB hiccup here must not
      # silence GitHub, and the duplicate-dispatch it risks is the pre-existing bug,
      # not a new one.
      Rails.logger.error "[Github::CommentEvaluator] Agent-authorship lookup failed for comment #{comment_data['id']}: #{e.class} - #{e.message}"
      nil
    end

    # Whether enough time has passed since the comment was created for the authorship
    # hook to have claimed it (see ATTRIBUTION_GRACE_SECONDS). A comment with no
    # parseable created_at cannot be held down, so it is treated as settled.
    def attribution_settled?(comment_data)
      created_at = comment_data["created_at"]
      return true if created_at.blank?

      deferred = Time.parse(created_at) > ATTRIBUTION_GRACE_SECONDS.seconds.ago
      if deferred
        Rails.logger.info "[Github::CommentEvaluator] Deferring comment #{comment_data['id']} (#{comment_data['url']}): younger than the #{ATTRIBUTION_GRACE_SECONDS}s authorship grace period"
      end
      !deferred
    rescue ArgumentError
      true
    end

    # Whether a comment is still young enough to be worth another visibility lookup.
    # A comment with no parseable created_at cannot be aged out, so it is not retried.
    def visibility_retry_window_open?(comment_info)
      created_at = comment_info.dig(:data, "created_at")
      return false if created_at.blank?

      Time.parse(created_at) > VISIBILITY_RETRY_WINDOW_SECONDS.seconds.ago
    rescue ArgumentError
      false
    end

    def fetch_pr_comments(owner, repo, pr_number)
      # Use gh CLI to get PR comments (issue comments) with pagination
      # Note: owner/repo are extracted via regex from validated PR URLs (github.com/[^/]+/[^/]+/pull/\d+)
      # which prevents path injection. pr_number is validated as digits only.
      fetch_paginated_comments("repos/#{owner}/#{repo}/issues/#{pr_number}/comments")
    end

    def fetch_review_comments(owner, repo, pr_number)
      # Use gh CLI to get review comments (inline comments on diffs) with pagination
      # Note: owner/repo are extracted via regex from validated PR URLs (github.com/[^/]+/[^/]+/pull/\d+)
      # which prevents path injection. pr_number is validated as digits only.
      fetch_paginated_comments("repos/#{owner}/#{repo}/pulls/#{pr_number}/comments")
    end

    # Fetches all comments from a paginated GitHub API endpoint
    # Returns all comments across all pages, or nil on failure
    def fetch_paginated_comments(api_path)
      all_comments = []
      page = 1

      loop do
        command = [
          "gh", "api",
          "#{api_path}?per_page=#{MAX_COMMENTS_PER_PAGE}&page=#{page}",
          "--jq", "."
        ]

        result = GithubCli.run(command, timeout: COMMENT_PAGE_TIMEOUT)

        # Every way this page can fail to produce a trustworthy answer — a non-zero exit,
        # an exit code lost to a reap, a page that hung until its deadline — lands here and
        # gives the tick the outcome it already has for a non-zero exit: return what we
        # have, retry next tick. See GithubCli.
        unless result.success?
          Rails.logger.warn "[Github::CommentEvaluator] Failed to fetch comments from #{api_path} " \
            "(page #{page}): #{result.failure_description}"
          return all_comments.any? ? all_comments : nil
        end

        page_comments = JSON.parse(result.stdout)
        break if page_comments.empty?

        all_comments.concat(page_comments)
        break if page_comments.length < MAX_COMMENTS_PER_PAGE

        page += 1
      end

      all_comments
    rescue JSON::ParserError => e
      Rails.logger.error "[Github::CommentEvaluator] Failed to parse comments from #{api_path}: #{e.message}"
      all_comments.any? ? all_comments : nil
    end

    def build_pr_comment_data(comment, pr_url, pr_number)
      author = comment.dig("user", "login") || "unknown"
      body = comment["body"] || ""

      {
        "id" => comment["id"],
        "author" => author,
        "attribution" => body.include?(AGENT_COMMENT_MARKER) ? "self" : author,
        "body" => body,
        "url" => comment["html_url"],
        "created_at" => comment["created_at"]
      }
    end

    def build_review_comment_data(comment, pr_url, pr_number)
      author = comment.dig("user", "login") || "unknown"
      body = comment["body"] || ""

      {
        "id" => comment["id"],
        "author" => author,
        "attribution" => body.include?(AGENT_COMMENT_MARKER) ? "self" : author,
        "body" => body,
        "url" => comment["html_url"],
        "path" => comment["path"],
        "line" => comment["line"] || comment["original_line"],
        "diff_hunk" => comment["diff_hunk"],
        "in_reply_to_id" => comment["in_reply_to_id"],
        "created_at" => comment["created_at"]
      }
    end

    # Check if a comment body matches any blacklisted pattern
    # Used to filter out bot commands
    def blacklisted_comment?(body)
      return false if body.blank?

      BLACKLISTED_PATTERNS.any? { |pattern| body.match?(pattern) }
    end

    # Check if a comment is a report from Zimmer's own PR automation, by the heading it
    # opens with. Only the first non-blank line is considered, so a human quoting a report
    # -- or writing about it -- is left alone.
    def automated_comment?(body)
      return false if body.blank?

      match = AUTOMATION_HEADING_PATTERN.match(body.strip.lines.first.to_s.strip)
      return false unless match

      AUTOMATION_REPORT_HEADINGS.include?(match[:title].downcase.squish)
    end

    # Why a comment must never trigger a follow-up prompt, whoever authored it, or nil
    # when neither filter catches it.
    #
    # Logged, because a filtered comment leaves no other trace: no reaction, no reply, no
    # session log -- and a heading that matched something a human wrote should be findable.
    def ignored_reason(comment_data)
      body = comment_data["body"]
      reason = if blacklisted_comment?(body)
        "bot_command"
      elsif automated_comment?(body)
        "automation_report"
      end
      return nil unless reason

      Rails.logger.info "[Github::CommentEvaluator] Ignoring comment #{comment_data['id']} by #{comment_data['author']} (#{comment_data['url']}): #{reason}"
      reason
    end

    # Check if a comment was created after tracking started for this PR
    # This prevents historical comments from being enqueued when a session
    # is associated with an existing PR that has prior comments
    #
    # @param comment_data [Hash] The comment data including "created_at" timestamp
    # @param tracking_started_at [String, nil] ISO8601 timestamp when tracking started, or nil if unknown
    # @return [Boolean] true if the comment should be processed, false if it's a historical comment
    def comment_created_after_tracking_started?(comment_data, tracking_started_at)
      # If we don't have a tracking timestamp (legacy sessions), allow all comments
      # This maintains backwards compatibility for sessions created before this feature
      return true if tracking_started_at.blank?

      comment_created_at = comment_data["created_at"]
      return true if comment_created_at.blank?

      begin
        # Parse both timestamps and compare
        # Comment must be created at or after tracking started
        Time.parse(comment_created_at) >= Time.parse(tracking_started_at)
      rescue ArgumentError => e
        Rails.logger.warn "[Github::CommentEvaluator] Failed to parse timestamp: #{e.message}"
        # If we can't parse timestamps, default to allowing the comment
        true
      end
    end

    # Add eyes emoji reaction to a GitHub comment to indicate we're processing it
    # Uses the GitHub API to create a reaction on the comment
    #
    # Only called once a follow-up is known to be going out: the reaction is a promise to
    # respond, so it must not be posted on a comment Zimmer has decided not to action.
    #
    # This is best-effort and won't block the enqueue if it fails
    def add_eyes_reaction(comment_info)
      owner = comment_info[:owner]
      repo = comment_info[:repo]
      comment_id = comment_info.dig(:data, "id")
      comment_type = comment_info[:type]

      return unless comment_id

      # Different API endpoints for PR comments vs review comments
      api_path = if comment_type == "review"
        "repos/#{owner}/#{repo}/pulls/comments/#{comment_id}/reactions"
      else
        "repos/#{owner}/#{repo}/issues/comments/#{comment_id}/reactions"
      end

      command = [
        "gh", "api",
        "--method", "POST",
        api_path,
        "-f", "content=eyes"
      ]

      result = GithubCli.run(command, timeout: REACTION_TIMEOUT)

      # A hung reaction arrives here as an ordinary failed call rather than an exception,
      # so it is logged and dropped like every other reaction failure. The `rescue
      # StandardError` below would have swallowed it either way — the point of routing it
      # through this branch is that it is logged with the same wording as the rest.
      unless result.success?
        Rails.logger.warn "[Github::CommentEvaluator] Failed to add eyes reaction to comment #{comment_id}: " \
          "#{result.failure_description}"
      end
    rescue StandardError => e
      # Don't let reaction failures prevent the follow-up prompt from being enqueued
      safe_comment_id = comment_info.dig(:data, "id") || "unknown"
      Rails.logger.warn "[Github::CommentEvaluator] Exception adding eyes reaction to comment #{safe_comment_id}: #{e.class} - #{e.message}"
    end

    # Hand a comment to the session, and report what happened so the caller can record
    # it on the comment.
    #
    # @return [String] the comment's final dispatch_state
    def enqueue_follow_up_prompt(session, comment_info)
      builder = GithubCommentPromptBuilder.new(
        session: session,
        comment_info: comment_info
      )

      # Decide whether the comment will be actioned before reacting to it. On a public repo
      # owned by someone we don't control, the agent isn't allowed to reply, commit, or
      # react without human approval -- so there is nothing to hand it, and a 👀 there is a
      # promise Zimmer is designed not to keep.
      unless builder.actionable?
        unless builder.visibility_lookup_failed?
          Rails.logger.info "[Github::CommentEvaluator] Skipping comment #{comment_info.dig(:data, 'id')} on #{comment_info[:owner]}/#{comment_info[:repo]} for session #{session.id}: public repository outside our control"
          return "skipped:not_actionable"
        end

        # `gh` couldn't tell us whether the repo is private, so "public" here is an
        # assumption, not an observation. Failing closed is still right -- acting
        # publicly on a repo we couldn't check is worse than answering late -- but a
        # transient rate limit or network blip must not drop a real comment forever, so
        # retry on later polls until the lookup answers or the comment ages out.
        if visibility_retry_window_open?(comment_info)
          Rails.logger.warn "[Github::CommentEvaluator] Deferring comment #{comment_info.dig(:data, 'id')} on #{comment_info[:owner]}/#{comment_info[:repo]} for session #{session.id}: repo visibility lookup failed, will retry"
          return DISPATCH_DEFERRED
        end

        Rails.logger.warn "[Github::CommentEvaluator] Skipping comment #{comment_info.dig(:data, 'id')} on #{comment_info[:owner]}/#{comment_info[:repo]} for session #{session.id}: repo visibility lookup still failing after #{VISIBILITY_RETRY_WINDOW_SECONDS}s, assuming public"
        return "skipped:visibility_unknown"
      end

      prompt = builder.build

      return "skipped:empty_prompt" if prompt.blank?

      # Only now, with a follow-up actually going out, mark the comment as seen
      add_eyes_reaction(comment_info)

      with_db_retry do
        # Use transaction with row-level locking to prevent race conditions
        # The state check and state change must happen atomically
        ActiveRecord::Base.transaction do
          # Lock the session row and reload to get current state
          session.lock!

          # If session is in needs_input state, send the message immediately
          # rather than queueing it (follows same pattern as SessionsController#follow_up)
          if session.needs_input?
            send_prompt_immediately(session, prompt, comment_info)
          else
            enqueue_prompt_for_later(session, prompt, comment_info)
          end
        end
      end

      DISPATCH_DISPATCHED
    rescue => e
      Rails.logger.error "[Github::CommentEvaluator] Failed to process follow-up prompt for session #{session.id}: #{e.message}"
      # The 👀 may already be posted and the prompt may or may not have landed, so
      # neither "dispatched" nor "deferred" is honest. Terminal, and named for what it
      # was: an error, findable in custom_metadata.
      "skipped:dispatch_error"
    end

    # Send prompt directly to the session, transitioning it to running
    # Used when session is in needs_input state
    #
    # Note: This method must be called within a transaction that has already
    # locked the session row to prevent race conditions.
    #
    # Note: GitHub comments don't have goals. The session's existing
    # goal is preserved (not modified like in SessionsController#follow_up).
    def send_prompt_immediately(session, prompt, comment_info)
      comment_type = comment_info[:type] == "review" ? "review comment" : "PR comment"
      comment_url = comment_info[:data]["url"]
      truncated_prompt = prompt.length > 200 ? "#{prompt[0..197]}..." : prompt

      # Log the immediate send
      session.logs.create!(
        content: "GitHub #{comment_type} from #{comment_info[:data]['author']} sent immediately (#{comment_url}): #{truncated_prompt}",
        level: "info"
      )

      session.deliver_follow_up!(prompt, clear_metadata_keys: Session::SIGTERM_RETRY_METADATA_KEYS)

      Rails.logger.info "[Github::CommentEvaluator] Sent immediate follow-up prompt for session #{session.id} from GitHub #{comment_type} by #{comment_info[:data]['author']}"
    end

    # Queue prompt as an enqueued message for later processing
    # Used when session is running or waiting
    #
    # Note: This method must be called within a transaction that has already
    # locked the session row to prevent race conditions.
    def enqueue_prompt_for_later(session, prompt, comment_info)
      comment_type = comment_info[:type] == "review" ? "review comment" : "PR comment"
      comment_url = comment_info[:data]["url"]

      max_position = session.enqueued_messages.maximum(:position) || 0
      next_position = max_position + 1

      session.enqueued_messages.create!(
        content: prompt,
        position: next_position,
        status: "pending"
      )

      session.logs.create!(
        content: "GitHub #{comment_type} from #{comment_info[:data]['author']} auto-enqueued as follow-up prompt (#{comment_url})",
        level: "info"
      )

      Rails.logger.info "[Github::CommentEvaluator] Enqueued follow-up prompt for session #{session.id} from GitHub #{comment_type} by #{comment_info[:data]['author']}"
    end
  end
end
