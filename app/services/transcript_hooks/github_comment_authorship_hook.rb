# frozen_string_literal: true

# Records the GitHub comments this session posted, so the comment poller never
# hands one back to an agent as if the human had written it.
#
# The problem this exists for: `gh` inside every session authenticates as the
# human, so an agent's comment carries `user.login == "tadasant"` exactly like a
# real one. GithubCommentPollerJob dispatches by author, so an agent-posted
# comment came back as "GitHub Comment Response Required" — to the session that
# posted it, and (because routing is by tracked PR URL, not by authorship) to
# every other session tracking that PR. Each reply would itself be a new comment
# by "tadasant", so the cycle has no natural end.
#
# GitHub cannot distinguish them. Zimmer can, because it watched the tool call:
# a shell command that posts a comment prints the comment's URL, and that URL
# carries the comment id (`#issuecomment-<id>` / `#discussion_r<id>`). This hook
# reads the id out of the result of a *posting* command and writes an
# AgentPostedGithubComment row.
#
# Only results of posting commands are scanned, mirroring GithubPrUrlHook's
# `gh pr create` correlation. Scanning every tool result would misfire on the
# common case of an agent *reading* a comment (`gh api .../issues/comments/<id>`
# returns a body containing that comment's own `html_url`) — which would suppress
# a human comment the agent merely looked at.
#
# The residual gap is a comment posted by a route this pattern doesn't recognize
# (a Python script, an MCP GitHub tool). Those are not recorded and can still be
# routed back; see docs/src/content/docs/limitations.md. Widening the pattern is
# how a new posting route gets covered.
#
# Registered by default via config/initializers/transcript_hooks.rb.
class TranscriptHooks::GithubCommentAuthorshipHook < TranscriptHooks::BaseHook
  # Shell commands that post a comment to GitHub. Matched anywhere in the command
  # so `cd x && gh pr comment ...` and Codex's joined argv both hit.
  #
  #   gh pr comment / gh issue comment  — a PR-level (issue) comment
  #   gh pr review --comment            — a review with a body comment
  #   gh api ... comments ... <write>   — the inline-review-reply shape that
  #                                       GithubCommentPromptBuilder itself hands
  #                                       the agent, plus any hand-rolled POST
  DIRECT_POST_PATTERNS = [
    /\bgh\s+(?:pr|issue)\s+comment\b/,
    /\bgh\s+pr\s+review\b/
  ].freeze

  # A `gh api` call only counts as a post when it targets a comments endpoint AND
  # carries a write flag. `gh api` defaults to POST once any field is supplied, so
  # a bare field flag is as much a write as an explicit --method POST.
  GH_API_PATTERN = /\bgh\s+api\b/
  GH_API_COMMENTS_PATTERN = /\bcomments\b/
  GH_API_WRITE_PATTERN = /(?:--method\s+POST|-X\s+POST|(?:\A|\s)(?:-f|-F|--field|--raw-field|--input)(?:\s|=))/

  # The two fragment shapes GitHub uses for a comment permalink. `gh pr comment`
  # prints the first as its only output; `gh api` prints a JSON body whose
  # `html_url` carries whichever applies. The host is pinned to github.com so a
  # lookalike domain in some other output cannot register an id.
  COMMENT_URL_PATTERNS = {
    "pr" => %r{https://github\.com/[\w.-]+/[\w.-]+/(?:pull|issues)/\d+#issuecomment-(\d+)},
    "review" => %r{https://github\.com/[\w.-]+/[\w.-]+/pull/\d+#discussion_r(\d+)}
  }.freeze

  # The PR/issue URL a comment permalink hangs off, used to record which PR the
  # comment landed on.
  PARENT_URL_PATTERN = %r{\A(https://github\.com/[\w.-]+/[\w.-]+/(?:pull|issues)/\d+)#}

  def call
    posted = extract_posted_comments
    return if posted.empty?

    recorded = posted.reject { |c| already_recorded?(c) }
    return if recorded.empty?

    recorded.each do |comment|
      with_db_retry do
        AgentPostedGithubComment.record!(
          session: session,
          comment_type: comment[:comment_type],
          comment_id: comment[:comment_id],
          comment_url: comment[:comment_url],
          pr_url: comment[:pr_url]
        )
      end
    end

    Rails.logger.info(
      "[GithubCommentAuthorshipHook] Recorded #{recorded.size} agent-posted GitHub comment(s) " \
      "for session #{session.id}: #{recorded.map { |c| "#{c[:comment_type]}##{c[:comment_id]}" }.join(', ')}"
    )
  end

  private

  # Every comment permalink found in the output of a comment-posting command.
  # @return [Array<Hash>] each { comment_type:, comment_id:, comment_url:, pr_url: }
  def extract_posted_comments
    post_call_ids = posting_tool_call_ids
    return [] if post_call_ids.empty?

    found = {}

    parser.tool_results.each do |result|
      next unless post_call_ids.include?(result[:id])
      # A failed post did not create a comment. Any URL in its output belongs to
      # something else (an error message quoting an existing thread, say).
      next if result[:is_error]
      next if result[:text].blank?

      COMMENT_URL_PATTERNS.each do |comment_type, pattern|
        result[:text].scan(pattern) do
          match = Regexp.last_match
          comment_id = match[1].to_i
          comment_url = match[0]
          key = [ comment_type, comment_id ]
          next if found.key?(key)

          found[key] = {
            comment_type: comment_type,
            comment_id: comment_id,
            comment_url: comment_url,
            pr_url: comment_url[PARENT_URL_PATTERN, 1]
          }
        end
      end
    end

    found.values
  end

  # Ids of the tool calls that posted a comment.
  def posting_tool_call_ids
    parser.shell_calls.filter_map do |call|
      call[:id] if posting_command?(call[:command])
    end
  end

  def posting_command?(command)
    return false if command.blank?
    return true if DIRECT_POST_PATTERNS.any? { |pattern| command.match?(pattern) }

    # `gh api` is broad enough to match reads, so it carries extra conditions.
    command.match?(GH_API_PATTERN) &&
      command.match?(GH_API_COMMENTS_PATTERN) &&
      command.match?(GH_API_WRITE_PATTERN)
  end

  def already_recorded?(comment)
    AgentPostedGithubComment.posted_by_agent(
      comment_type: comment[:comment_type],
      comment_id: comment[:comment_id]
    ).present?
  end

  def parser
    @parser ||= TranscriptHooks::ToolCallParser.for(session: session, parsed_transcript: parsed_transcript)
  end
end
