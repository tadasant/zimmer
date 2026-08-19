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
  # A tool call's command is a whole shell script; a post has to be read out of the
  # one command that ran it (see GH_API_PATTERN).
  include TranscriptHooks::ShellSegments

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
  # carries a write flag. `gh api` defaults to POST once any field is supplied, so a
  # bare field flag is as much a write as an explicit --method POST.
  #
  # All three must hold within ONE command segment. Matching them against the whole
  # shell line would read `gh api repos/o/r/issues/1/comments --paginate && rm -f x`
  # as a post, because `rm -f` supplies the write flag — and that command is a *read*
  # whose output carries every comment in the thread, including the human's. Recording
  # those would suppress real comments permanently and fleet-wide, which is worse than
  # the bug this hook exists to fix.
  GH_API_PATTERN = /\Agh\s+api\b/
  # A comments endpoint path, not the bare word: `/issues/1/comments`,
  # `/pulls/1/comments`, `/pulls/1/comments/2/replies`. Keeps `/tmp/comments.json` and
  # a body that merely says "comments" out.
  GH_API_COMMENTS_PATTERN = %r{/(?:issues|pulls)/(?:\d+/)?comments\b}
  GH_API_WRITE_PATTERN = /(?:--method[\s=]+POST|-X\s*POST|(?:\A|\s)(?:-f|-F|--field|--raw-field|--input)(?:\s|=))/

  # Segmentation — the split itself, and why it errs toward more segments — lives in
  # TranscriptHooks::ShellSegments, shared with GithubPrUrlHook. A mis-split can
  # lose a recording here (recoverable: the comment is treated as the human's, as
  # it was before this hook) rather than manufacture one (not recoverable: a
  # human's comment goes unanswered).

  # The two fragment shapes GitHub uses for a comment permalink. `gh pr comment`
  # prints the first as its only output; `gh api` prints a JSON body whose `html_url`
  # carries whichever applies. The host is pinned to github.com so a lookalike domain
  # in some other output cannot register an id.
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

    recorded = unrecorded(posted)
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
    kinds_by_call_id = posting_calls
    return [] if kinds_by_call_id.empty?

    found = {}

    parser.tool_results.each do |result|
      kind = kinds_by_call_id[result[:id]]
      next unless kind
      # A failed post did not create a comment. Any URL in its output belongs to
      # something else (an error message quoting an existing thread, say).
      next if result[:is_error]
      next if result[:text].blank?

      urls_from(result[:text], kind).each do |url|
        comment = comment_from_url(url)
        next unless comment
        next if found.key?([ comment[:comment_type], comment[:comment_id] ])

        found[[ comment[:comment_type], comment[:comment_id] ]] = comment
      end
    end

    found.values
  end

  # The comment permalinks a posting command's output vouches for.
  #
  # `gh api` echoes the created comment as JSON — including its `body`. An agent
  # replying to a human quotes that human's permalink (GithubCommentPromptBuilder
  # hands it to them under "Comment URL"), so free-text scanning would read the quoted
  # human comment as one the agent posted and silence it. Take the created resource's
  # own `html_url` and nothing else.
  #
  # `gh pr comment` / `gh issue comment` / `gh pr review` print the new comment's URL
  # and nothing else, so there is no body to confuse and the text is scanned directly.
  def urls_from(text, kind)
    return html_urls_from_json(text) if kind == :api

    COMMENT_URL_PATTERNS.each_value.flat_map do |pattern|
      text.to_enum(:scan, pattern).map { Regexp.last_match[0] }
    end.uniq
  end

  # The `html_url` of a `gh api` response. Returns [] when the output is not a JSON
  # object (e.g. `--jq` narrowed it) rather than falling back to a text scan: a
  # missed recording costs one comment its suppression, a wrong one costs a human
  # their reply.
  def html_urls_from_json(text)
    parsed = JSON.parse(text)
    case parsed
    when Hash then Array(parsed["html_url"])
    when Array then parsed.filter_map { |item| item["html_url"] if item.is_a?(Hash) }
    else []
    end
  rescue JSON::ParserError
    []
  end

  # Parse a permalink into the comment it identifies, or nil when it is not one
  # (wrong host, wrong shape).
  def comment_from_url(url)
    COMMENT_URL_PATTERNS.each do |comment_type, pattern|
      match = pattern.match(url)
      next unless match

      return {
        comment_type: comment_type,
        comment_id: match[1].to_i,
        comment_url: match[0],
        pr_url: match[0][PARENT_URL_PATTERN, 1]
      }
    end

    nil
  end

  # The tool calls that posted a comment, mapped to how they posted it.
  # @return [Hash{String => Symbol}] call id => :direct or :api
  def posting_calls
    parser.shell_calls.each_with_object({}) do |call, acc|
      kind = posting_kind(call[:command])
      acc[call[:id]] = kind if kind
    end
  end

  # :direct, :api, or nil — classified per command segment, never across the whole
  # shell line (see GH_API_PATTERN).
  def posting_kind(command)
    return nil if command.blank?

    segments = shell_segments(command)

    return :direct if segments.any? { |segment| DIRECT_POST_PATTERNS.any? { |pattern| segment.match?(pattern) } }
    return :api if segments.any? { |segment| gh_api_post?(segment) }

    nil
  end

  def gh_api_post?(segment)
    segment.match?(GH_API_PATTERN) &&
      segment.match?(GH_API_COMMENTS_PATTERN) &&
      segment.match?(GH_API_WRITE_PATTERN)
  end

  # Comments already on record, so a transcript rescanned every poll costs one query
  # rather than one per comment the session has ever posted.
  def unrecorded(comments)
    return [] if comments.empty?

    known = AgentPostedGithubComment
      .where(comment_type: comments.map { |c| c[:comment_type] }.uniq, comment_id: comments.map { |c| c[:comment_id] }.uniq)
      .pluck(:comment_type, :comment_id)
      .to_set

    comments.reject { |c| known.include?([ c[:comment_type], c[:comment_id] ]) }
  end

  def parser
    @parser ||= TranscriptHooks::ToolCallParser.for(session: session, parsed_transcript: parsed_transcript)
  end
end
