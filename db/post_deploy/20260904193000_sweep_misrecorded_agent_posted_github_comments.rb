# frozen_string_literal: true

# Deletes the `agent_posted_github_comments` rows that a pre-#899 classifier wrote
# by mistake, and that are still silently suppressing human comments
# (https://github.com/tadasant/zimmer/issues/907).
#
# THE POINT OF THIS FILE: #899 taught `GithubCommentAuthorshipHook` to read what a
# command segment *runs* rather than what it quotes, so `grep -rn "gh pr comment"
# app/` over this repo — whose own source and docs carry example permalinks — is a
# read again instead of a post. That fix is forward-only. Every row an earlier
# false positive already wrote is still in the table, and those rows are what
# `Github::CommentEvaluator` reads. They are global (unique on
# `[comment_type, comment_id]`), so a HUMAN comment whose id got recorded that way
# is undeliverable to every session, permanently, and nothing logs the suppression.
# There is no symptom to look for and the harm does not decay. Merging #899
# restored nothing; this is the repair.
#
# It ships with the deploy because AGENTS.md ("ops actions ship with the deploy")
# leaves no other route: nobody has a shell on the production box, and what the
# sweep did has to be answerable without one. It is, in `post_deploy_task_runs` —
# on /health, in `GET /api/v1/health`, from `get_system_health` and at
# /supervisor/post_deploy_task_runs.
#
# HOW A WRONG ROW IS TOLD FROM A RIGHT ONE
#
# The signal is already on the row: `session_id` is the session whose transcript
# the hook read, and `Session#transcript` is that transcript, durably stored.
# So each row is re-derived — the fixed hook is driven as a pure classifier over
# its own recording session's transcript (`#posted_comments`, which is the same
# code path `#call` records from, not a copy of it) — and a row the fixed hook
# would still write is kept.
#
# THE BIAS, AND WHY IT DECIDES THE UNREACHABLE ROWS
#
# Both failure modes here are silent, and they are not symmetric:
#
#   too broad — a row deleted that was CORRECT re-opens the cross-session
#     self-reply loop #250 exists to stop, for that comment: the agent's own
#     comment is handed back to every session tracking the PR as if a human had
#     written it, and each reply is itself a new comment by "tadasant".
#   too narrow — a poisoned row left alone costs exactly what the status quo
#     already costs, and costs it to a population that is already paying.
#
# So: **keep the row unless the transcript positively says otherwise.** Deletion
# needs TWO facts, not one:
#
#   1. the fixed classifier does not read this comment as agent-posted, AND
#   2. the comment's permalink is still visible in the output of a command that
#      NAMES a posting invocation — the evidence the old classifier misread is
#      still there, in a result it could actually have been reading.
#
# The second half of (2) is a real restriction, not decoration. Scanning every
# tool result would let a `Read` of this repo's own limitations.md — which quotes
# example permalinks — stand in as evidence for deleting a row that `Read` could
# never have written, with an empty audit trail to show for it. Every
# classification the pre-#899 hook could make required the command to name `gh pr
# comment`, `gh issue comment`, `gh pr review` or `gh api`, so restricting to
# those is a strict superset of what it accepted: no intended deletion is lost.
#
# (2) is what separates "this was a grep, and now we read it as one" from "this
# transcript no longer mentions the comment at all", which is ambiguous: the row
# may predate a transcript this deployment no longer has in full, and a row whose
# evidence has gone is a row nothing can vouch for either way. Those are KEPT and
# counted, which is what makes this task's failure mode the survivable one. It is
# named here rather than left to fall out of the code: **this sweep is
# deliberately too narrow rather than too broad.**
#
# Rows the signal cannot reach at all take the same default, for the same reason:
#
#   session_id NULL         `belongs_to :session, optional: true`, and a row with
#                           no session names no transcript to re-derive from.
#   session deleted         a race only: the foreign key is `on_delete: :nullify`,
#                           so a destroyed session leaves the row in the case
#                           above. Kept as its own reason because a row loaded
#                           before the nullify still carries the stale id.
#   transcript blank/gone   nothing to classify. Also where a transcript stored in
#                           a shape this task cannot read lands, since the column
#                           is `json` and nothing constrains it to a string.
#   transcript unparsable   ditto; an empty parse is indistinguishable from a
#                           transcript in a shape this runtime's parser cannot
#                           read, and neither is evidence of a wrong row.
#
# All four are counted separately in `stats`, so "the sweep could not reach N
# rows" is a number a human can read off /health rather than a silence.
#
# ONE CASE THE BIAS DOES NOT COVER, stated rather than hidden: the verdict is
# derived per SESSION but the row is global. `AgentPostedGithubComment.record!`
# returns the existing row on a conflict, so `session_id` is whichever session
# recorded the comment FIRST. A comment genuinely posted by session B but first
# recorded by a false positive in session A is re-derived from A's transcript and
# can be deleted. It needs A to misread the id before B posted it, which is a
# narrow window, and there is no second signal to break the tie with — the row
# carries one session and that is the one the hook read.
#
# WHAT IT DOES NOT REPAIR
#
# #901 is a second, still-live source of the same poisoning — classification is
# per command segment but the *output* it then reads is the whole tool result, so
# `gh pr comment 7 --body x && gh api repos/o/r/issues/7/comments` records the
# listed human comments as the post's. Those rows are correct under the classifier
# as it stands today, so this sweep keeps them, and new ones keep arriving until
# #901 lands. Repairing them is that issue's job and needs a second task file.
#
# IDEMPOTENT. Deleting only shrinks the set: a second pass re-examines the rows
# that survived, reaches the same verdict on each (the inputs are a stored
# transcript and a deterministic classifier) and deletes nothing. Rows written
# after this task runs are examined by it only if it is still resuming; that is
# fine, since a row the current classifier vouches for is kept.
#
# EVIDENCE. `destroy!` leaves nothing behind, so every deletion is logged whole
# BEFORE the write — the row's own columns plus the shell commands whose output
# carried the permalink, which is the thing a human would want to see to believe
# the verdict ("it was a `grep`"). A bounded digest of the same goes into `stats`.
class SweepMisrecordedAgentPostedGithubComments < PostDeployTask
  # Rows per slice. Small on purpose: the per-row work is dominated by loading and
  # parsing a whole session transcript, which can be megabytes, and `sweep` only
  # checks the clock BETWEEN batches. Rows are grouped by session within a batch,
  # so a session that recorded twenty comments is parsed once.
  BATCH_SIZE = 25

  # `stats` is rendered verbatim in four places and the ledger row is never
  # deleted, so the digest is bounded on both axes. The log carries every
  # deletion, whole, and is the durable copy.
  MAX_DETAILED = 20
  MAX_COMMAND_CHARS = 200
  # Distinct commands quoted per deleted row. One is normally the whole story;
  # more than a couple is noise in a health panel.
  MAX_COMMANDS_PER_ROW = 3

  # Why a row was kept. A fixed vocabulary, so `kept_by_reason` stays a small
  # countable histogram.
  KEPT_STILL_A_POST = "classified_as_a_post_by_the_fixed_hook"
  KEPT_NO_EVIDENCE = "permalink_no_longer_in_the_transcript"
  KEPT_NO_SESSION = "row_has_no_recording_session"
  KEPT_SESSION_GONE = "recording_session_no_longer_exists"
  KEPT_NO_TRANSCRIPT = "recording_session_has_no_stored_transcript"
  KEPT_UNPARSABLE = "stored_transcript_parsed_to_nothing"

  # The reasons that mean "the signal could not be reached", as opposed to
  # "reached, and it said keep".
  UNREACHABLE_REASONS = [ KEPT_NO_SESSION, KEPT_SESSION_GONE, KEPT_NO_TRANSCRIPT, KEPT_UNPARSABLE ].freeze

  def up
    # Resumed from `stats`, not restarted: a sweep that returns CONTINUE picks up
    # at the cursor on the next tick, and counters that began again at zero would
    # report the last slice as if it were the whole run.
    @examined = stats["rows_examined"].to_i
    @kept_by_reason = Hash.new(0).merge(stats["kept_by_reason"] || {})
    @deleted_count = stats["rows_deleted"].to_i
    @deleted_details = Array(stats["deleted_details"])

    outcome = sweep(AgentPostedGithubComment.all, batch_size: BATCH_SIZE) do |batch|
      batch.group_by(&:session_id).each do |session_id, rows|
        examine(session_id, rows)
      end
      # Staged, NOT saved: `sweep` writes the cursor immediately after this block
      # returns, and that one write carries these counters with it. Saving here
      # instead would leave a window where a batch's counters are durable but its
      # cursor is not, so a resumed slice would re-examine the batch and count
      # every kept row in it a second time.
      stage_progress
    end

    stage_progress
    checkpoint!
    outcome
  end

  private

  # Every row recorded by one session, against one parse of that session's
  # transcript.
  def examine(session_id, rows)
    @examined += rows.size

    evidence = Evidence.for(session_id)
    if evidence.unreachable_reason
      rows.each { |row| keep(row, evidence.unreachable_reason) }
      return
    end

    rows.each do |row|
      key = [ row.comment_type, row.comment_id.to_i ]

      if evidence.posted?(key)
        keep(row, KEPT_STILL_A_POST)
      elsif evidence.mentions?(key)
        delete(row, evidence.commands_for(key))
      else
        keep(row, KEPT_NO_EVIDENCE)
      end
    end
  end

  def keep(row, reason)
    @kept_by_reason[reason] += 1
    return unless UNREACHABLE_REASONS.include?(reason)

    # Reachability is the one keep worth a line each: it is the population this
    # task is knowingly blind to, and the count alone does not say which rows.
    logger.info(
      "[SweepMisrecordedAgentPostedGithubComments] keeping #{row.comment_type}##{row.comment_id} " \
      "(row #{row.id}, session #{row.session_id.inspect}) — #{reason}"
    )
  end

  def delete(row, commands)
    record = {
      row_id: row.id,
      session_id: row.session_id,
      comment_type: row.comment_type,
      comment_id: row.comment_id,
      comment_url: row.comment_url,
      pr_url: row.pr_url,
      recorded_at: row.created_at&.iso8601,
      misread_commands: commands
    }

    # Before the write: `destroy!` leaves no trace of what was there.
    logger.info("[SweepMisrecordedAgentPostedGithubComments] deleting #{record.to_json}")
    row.destroy!
    @deleted_count += 1
    @deleted_details << record.as_json if @deleted_details.size < MAX_DETAILED
  end

  # The counters, assigned in memory for the next write to carry.
  #
  # Truthful as of the last COMPLETED batch. A slice killed part-way through one
  # loses that batch's counters, including deletions it had already made — those
  # rows are gone and can never be recounted, which is exactly why every deletion
  # is logged whole before the write. The log is the durable record; `stats` is
  # the copy reachable without a shell.
  def stage_progress
    run.stats = run.stats.merge(
      "rows_examined" => @examined,
      "rows_reachable" => @examined - unreachable_count,
      "rows_unreachable" => unreachable_count,
      "rows_kept" => @kept_by_reason.values.sum,
      "rows_deleted" => @deleted_count,
      "kept_by_reason" => @kept_by_reason,
      "deleted_details" => @deleted_details
    )
  end

  def unreachable_count
    UNREACHABLE_REASONS.sum { |reason| @kept_by_reason[reason] }
  end

  # One session's transcript, read once and asked three questions: what the fixed
  # classifier calls a post, which comment permalinks its tool results still carry
  # at all, and which commands produced the output carrying them.
  class Evidence
    # nil when the transcript answered; otherwise the reason it could not.
    attr_reader :unreachable_reason

    def self.for(session_id)
      return new(unreachable_reason: KEPT_NO_SESSION) if session_id.nil?

      session = Session.find_by(id: session_id)
      return new(unreachable_reason: KEPT_SESSION_GONE) if session.nil?

      content = transcript_content(session)
      return new(unreachable_reason: KEPT_NO_TRANSCRIPT) if content.blank?

      entries = content.lines.filter_map do |line|
        JSON.parse(line.strip)
      rescue JSON::ParserError
        nil
      end
      return new(unreachable_reason: KEPT_UNPARSABLE) if entries.empty?

      new(session: session, transcript_content: content, entries: entries)
    end

    # `Session#transcript` is a json column holding JSONL for every runtime in use,
    # with an array left over from an older format. Both are normalized to the
    # string the hook is handed by `TranscriptPollerService`, so the classifier sees
    # exactly what it saw when the row was written.
    #
    # Anything else reads as no transcript rather than raising. The column is
    # `json` and nothing constrains its shape, and a task that dies on one odd row
    # parks `failed` and repairs none of the others.
    def self.transcript_content(session)
      raw = session.transcript
      return raw.map(&:to_json).join("\n") if raw.is_a?(Array)

      raw if raw.is_a?(String)
    end
    private_class_method :transcript_content

    def initialize(session: nil, transcript_content: nil, entries: nil, unreachable_reason: nil)
      @session = session
      @transcript_content = transcript_content
      @entries = entries
      @unreachable_reason = unreachable_reason
    end

    # Would the FIXED hook write this row today?
    def posted?(key) = posted_keys.include?(key)

    # Is the permalink still in the output of a command that could have recorded
    # it? Tool results only, because that is the sole place any classifier read an
    # id from — and only results of commands NAMING a posting invocation, because
    # those are the only ones the pre-#899 hook could have read (see the file
    # header). A permalink in the agent's prose, or in a `Read` of a file that
    # quotes one, never recorded anything and must not delete anything.
    def mentions?(key) = mentions.key?(key)

    # The shell commands whose output carried the permalink — the audit trail for
    # a deletion, and usually the `grep` that started it.
    def commands_for(key)
      call_ids = mentions[key] || []
      call_ids
        .filter_map { |id| commands_by_call_id[id] }
        .uniq
        .first(MAX_COMMANDS_PER_ROW)
        .map { |command| command.truncate(MAX_COMMAND_CHARS) }
    end

    private

    def posted_keys
      @posted_keys ||= TranscriptHooks::GithubCommentAuthorshipHook
        .new(session: @session, transcript_content: @transcript_content, new_messages: [])
        .posted_comments
        .map { |comment| [ comment[:comment_type], comment[:comment_id] ] }
        .to_set
    end

    # { [comment_type, comment_id] => [tool call id, ...] }
    def mentions
      @mentions ||= parser.tool_results.each_with_object({}) do |result, acc|
        # A failed command's output is not evidence: the hook has always skipped
        # `is_error` results, before #899 as after it, so no row was ever written
        # from one. Counting it would only widen the deletion.
        next if result[:is_error]
        next unless posting_call_ids.include?(result[:id])

        text = result[:text]
        next if text.blank?

        TranscriptHooks::GithubCommentAuthorshipHook::COMMENT_URL_PATTERNS.each do |comment_type, pattern|
          text.scan(pattern) do
            key = [ comment_type, Regexp.last_match(1).to_i ]
            (acc[key] ||= []) << result[:id]
          end
        end
      end
    end

    def commands_by_call_id
      @commands_by_call_id ||= parser.shell_calls.each_with_object({}) do |call, acc|
        acc[call[:id]] = call[:command].to_s
      end
    end

    # The calls whose output the pre-#899 hook could have read an id from. The
    # hook's own cheap precheck, run against the command AS WRITTEN — which is a
    # superset of every view either classifier reads, so it cannot exclude a call
    # that classified as a post under either.
    def posting_call_ids
      @posting_call_ids ||= commands_by_call_id
        .select { |_id, command| command.match?(TranscriptHooks::GithubCommentAuthorshipHook::POSTING_INVOCATION_PATTERN) }
        .keys
        .to_set
    end

    def parser
      @parser ||= TranscriptHooks::ToolCallParser.for(session: @session, parsed_transcript: @entries)
    end
  end
end
