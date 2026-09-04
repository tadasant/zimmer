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
# A posting command is read out of what a command segment *runs* rather than what it
# quotes, so a read that merely names one — `grep -rn "gh pr comment" docs/` over
# this very file — is not a post (#870).
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
  #
  # Matched against each segment's #unquoted view (TranscriptHooks::ShellSegments),
  # so the same words handed to another command as *data* count for nothing:
  # `grep -rn "gh pr comment" docs/`, `rg "gh pr review" app/` and an `echo` are
  # reads, and this repo's own source and docs quote both the literals and example
  # permalinks (#870, which is the shape #772 was in GithubPrUrlHook). Recording
  # what such a read printed suppresses those comment ids for every session,
  # permanently.
  #
  # Anywhere in what survives that, deliberately, rather than anchored to the front:
  # a post sits behind `cd ... &&`, `timeout 120`, `until ...; do`, `sudo -E`, and
  # Codex's `bash -lc` wrapper, and an anchor drops every prefix it does not
  # enumerate. Missing a real post is the self-reply loop this hook exists to break.
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
  # the bug this hook exists to fix. Classification is only where that discipline
  # starts: a tool result arrives as one blob rather than one per segment, so what the
  # result of a call that both posts and reads may vouch for is narrowed instead —
  # see #urls_from (#901).
  #
  # Which of the three reads the segment as written and which reads its #unquoted
  # view is not uniform, because the three are not the same kind of thing — the
  # asymmetry GithubPrUrlHook#create_repos draws between a create and its `--repo`:
  #
  #   invocation, write flag — shell syntax, never legitimately quoted. Read
  #     unquoted, so a segment's own argument cannot vouch for it. `gh api
  #     repos/o/r/issues/1/comments --jq 'map(select(.body | test("rm -f ")))'` is
  #     the `rm -f` case with nowhere for the splitter to cut: one command, whose
  #     write flag sits inside its own jq filter.
  #   endpoint — a value the write needs, and `gh api "repos/o/r/issues/1/comments"`
  #     is how plenty of agents write it. Read as written, so quoting the path
  #     cannot hide a real post. What that costs is a write elsewhere whose quoted
  #     data names a comments path — and that costs nothing in practice, because the
  #     id recorded comes from the *created* resource's `html_url` (see
  #     #html_urls_from_json), which for such a write is not a comment permalink.
  GH_API_PATTERN = /\Agh\s+api\b/
  # A comments endpoint path, not the bare word: `/issues/1/comments`,
  # `/pulls/1/comments`, `/pulls/1/comments/2/replies`. Keeps `/tmp/comments.json` and
  # a body that merely says "comments" out.
  GH_API_COMMENTS_PATTERN = %r{/(?:issues|pulls)/(?:\d+/)?comments\b}
  # An explicit method flag and whatever it names, in any of `gh`'s spellings:
  # `-X POST`, `-XPOST`, `--method=POST`, `-X get`. What it names is authoritative,
  # so `gh api -X GET repos/o/r/issues/7/comments -f per_page=100` — `gh`'s own idiom
  # for a GET with query parameters — is the read it is, rather than a "post" whose
  # output is the entire thread. GithubPrUrlHook#rest_pr_create? reads a create the
  # same way.
  GH_API_METHOD_FLAG_PATTERN = /(?<![\w-])(?:-X|--method)[=\s]*["']?([A-Za-z]+)/
  # Without an explicit method, a field flag is what turns `gh api` into a POST.
  GH_API_FIELD_FLAG_PATTERN = /(?:\A|\s)(?:-f|-F|--field|--raw-field|--input)(?:\s|=)/

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

  # A line whose whole content is one comment permalink: what a `:direct` post prints,
  # and all it prints. A JSON body never has that shape — `"html_url": "…",` carries
  # the key, the quotes and a comma on the same line — which is what makes this the
  # post's own output in a result that also carries another command's (#901, #urls_from).
  COMMENT_URL_LINE_PATTERNS = COMMENT_URL_PATTERNS.transform_values { |pattern| /\A#{pattern.source}\z/ }.freeze

  # Reaching GitHub, which is what it takes to print a comment permalink that the post
  # did not print. Counted over the segments' #unquoted views, so a permalink a command
  # merely quotes does not count, and generously — `gh` and `curl` in a shell comment
  # count too, and over-counting only tightens what the result vouches for.
  GITHUB_INVOCATION_PATTERN = /\bgh\b|\bcurl\b/

  # The PR/issue URL a comment permalink hangs off, used to record which PR the
  # comment landed on.
  PARENT_URL_PATTERN = %r{\A(https://github\.com/[\w.-]+/[\w.-]+/(?:pull|issues)/\d+)#}

  # The cheap precheck #posting_call runs before splitting a command at all: every
  # shape above names one of these, so a command naming none cannot be a post.
  POSTING_INVOCATION_PATTERN = /\bgh\s+(?:(?:pr|issue)\s+comment|pr\s+review|api)\b/

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
    posts_by_call_id = posting_calls
    return [] if posts_by_call_id.empty?

    found = {}

    parser.tool_results.each do |result|
      post = posts_by_call_id[result[:id]]
      next unless post
      # A failed post did not create a comment. Any URL in its output belongs to
      # something else (an error message quoting an existing thread, say).
      next if result[:is_error]
      next if result[:text].blank?

      urls_from(result[:text], post).each do |url|
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
  # A `:direct` post prints the new comment's URL and nothing else, so there is no body
  # to confuse — but the *result* is one blob for the whole tool call, and classifying
  # per segment (GH_API_PATTERN) does not split it. Free-text scanning it is therefore
  # only sound when the post was the only thing the call ran. `gh pr comment 7 --body x
  # && gh api repos/o/r/issues/7/comments` is the natural post-then-confirm move, and
  # scanning its blob records every comment the second segment listed — the human's
  # included, for every session, permanently (#901). When anything else in the call
  # reached GitHub, only the shape the post itself prints counts: a permalink that is
  # the whole of its line.
  #
  # `limit` bounds the case where that shape is not distinguishing either — a listing
  # narrowed with `--jq '.[].html_url'` prints a whole thread as bare URL lines. More of
  # them than the call had posting segments means they cannot all be posts and nothing
  # tells which are, so none is recorded: a lost recording costs a comment its
  # suppression, a wrong one costs a human their reply.
  def urls_from(text, post)
    return html_urls_from_json(text) if post[:kind] == :api
    return permalinks_anywhere(text) if post[:scan] == :whole_result

    lines = permalink_lines(text)
    return [] if post[:limit] && lines.size > post[:limit]

    lines
  end

  # Every comment permalink in +text+, wherever it sits.
  def permalinks_anywhere(text)
    COMMENT_URL_PATTERNS.each_value.flat_map do |pattern|
      text.to_enum(:scan, pattern).map { Regexp.last_match[0] }
    end.uniq
  end

  # The permalinks +text+ prints alone on a line. Deduplicated, so a post whose URL the
  # same call also `tee`d or echoed back counts once rather than against #urls_from's
  # limit twice.
  def permalink_lines(text)
    text.each_line.filter_map do |line|
      stripped = line.strip
      stripped if COMMENT_URL_LINE_PATTERNS.each_value.any? { |pattern| pattern.match?(stripped) }
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

  # The tool calls that posted a comment, mapped to how they posted it and to what
  # their result vouches for.
  # @return [Hash{String => Hash}] call id => the Hash #posting_call returns
  def posting_calls
    parser.shell_calls.each_with_object({}) do |call, acc|
      post = posting_call(call[:command])
      acc[call[:id]] = post if post
    end
  end

  # How +command+ posted a comment, or nil if it did not — classified per command
  # segment, never across the whole shell line (see GH_API_PATTERN). Each segment is
  # paired with its #unquoted view once, since every pattern below reads one or the
  # other of the two.
  #
  # The precheck is what keeps that off the overwhelming majority of commands, which
  # name no posting subcommand at all: splitting is not free, and a `Bash` command
  # can carry a whole heredoc body. It runs against the command as written, which is
  # a superset of every view classification reads, so it cannot hide a post.
  #
  # A `:direct` post also carries how much of the result it accounts for, because the
  # result is not split per segment the way this is (#901, and #urls_from for why each
  # is the reading it is):
  #
  #   :whole_result — the post was the whole command, and the only thing in it that
  #     reached GitHub, so everything the call printed is the post's own output.
  #   :permalink_lines — the call ran other commands too, so only the shape a post
  #     prints counts. `limit` is set when one of those commands reached GitHub and
  #     could therefore have printed permalinks in that same shape.
  #
  # @return [Hash, nil] { kind: :direct, scan:, limit: }, { kind: :api }, or nil
  def posting_call(command)
    return nil if command.blank?
    return nil unless command.match?(POSTING_INVOCATION_PATTERN)

    segments = shell_segments(command).map { |segment| [ segment, unquoted(segment) ] }
    posts, rest = segments.partition { |_written, runs| DIRECT_POST_PATTERNS.any? { |pattern| runs.match?(pattern) } }

    if posts.any?
      others = github_invocations(segments) - posts.size
      return { kind: :direct, scan: :whole_result } if rest.empty? && posts.size == 1 && others <= 0

      { kind: :direct, scan: :permalink_lines, limit: (posts.size if others.positive?) }
    elsif segments.any? { |written, runs| gh_api_post?(written, runs) }
      { kind: :api }
    end
  end

  # How many times +segments+ reach GitHub, read off what they run rather than what they
  # quote. One per posting segment means the posts are the only thing in the call that
  # could have put a comment permalink in its result.
  def github_invocations(segments)
    segments.sum { |_written, runs| runs.scan(GITHUB_INVOCATION_PATTERN).size }
  end

  # Whether one command segment posts a comment through the REST API: it runs
  # `gh api`, it addresses a comments endpoint, and it writes (see GH_API_PATTERN
  # for which of the three is read off which view of the segment).
  #
  # @param written [String] the segment as the agent wrote it
  # @param runs [String] its #unquoted view — what the segment runs, with what it
  #   was handed blanked out
  def gh_api_post?(written, runs)
    return false unless runs.match?(GH_API_PATTERN)
    return false unless written.match?(GH_API_COMMENTS_PATTERN)

    method = runs[GH_API_METHOD_FLAG_PATTERN, 1]
    return method.casecmp?("POST") if method

    runs.match?(GH_API_FIELD_FLAG_PATTERN)
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

  # The whole transcript, deliberately — including the part a fork copied from
  # the session it was forked from. GithubPrUrlHook trims that prefix off its own
  # parser, because crediting a fork with the source's *pull requests* enrols an
  # extra session in three pollers. Here the asymmetry is the point: this list is
  # read to SUPPRESS a comment, so inheriting the source's ids costs a
  # re-delivery that was never wanted rather than a wrong one that was. And it
  # costs nothing even then — `AgentPostedGithubComment` rows are global, with a
  # unique index on `[comment_type, comment_id]`, so a fork re-offering the
  # source's ids writes nothing new.
  def parser
    @parser ||= TranscriptHooks::ToolCallParser.for(session: session, parsed_transcript: parsed_transcript)
  end
end
