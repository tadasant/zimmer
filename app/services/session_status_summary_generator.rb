# frozen_string_literal: true

# Starts a fork-backed generation of a session's Status blurb.
#
# **Why a fork rather than a one-shot inference call.** The thing that makes a
# status blurb worth reading — "the PR is open but CI is red on the migration
# test, see message 214" — lives in the session's own conversation, tools and
# clone. A headless completion (SessionTitleJob's substrate) only ever sees a
# truncated, flattened rendering of the transcript, which is exactly where the
# specifics that justify a link get lost. Forking hands the summarizer the real
# conversation at the real point it stopped, and costs no new machinery: fork,
# ask, harvest, archive.
#
# The flow, end to end:
#
#   1. This service claims the summary record (marks it `pending`), forks the
#      session at its last transcript message, points the record at the fork,
#      and sends the fork one follow-up prompt (the summary request).
#   2. The fork runs a single agent turn and pauses.
#   3. SessionStateMachine's pause/fail hooks recognize the fork by its metadata
#      marker and enqueue SessionStatusSummaryHarvestJob instead of the usual
#      needs-input side effects (no push notification, no trigger fire).
#   4. That job lifts the fork's answer onto the source session's summary record
#      and archives the fork.
#
# Generation is refused when the session has not moved since the displayed
# summary was written — that refusal is the caching requirement, and it is why
# a page view can never trigger work.
#
# A FORCED generation needs no clone at all. DeferredCloneCleanupJob deletes an
# archived session's clone once the undo window (10 seconds) closes, so every
# archived session an operator actually opens later has no tree left — and an
# archived session is exactly the one someone opens later to ask what happened.
# The fork does not read that tree: it answers from the conversation it was
# forked with and is told not to run tools. So when the clone is gone, the fork
# is given an empty working directory instead (ForkSessionService's
# `scaffold_missing_clone`), and the summary is written anyway.
#
# An AUTOMATIC generation still refuses on a missing clone, and still skips the
# trash. Nothing enqueues one for an archived session on purpose, and paying to
# stand a fork up for a session nobody is looking at is the waste those two
# refusals exist to prevent.
class SessionStatusSummaryGenerator
  # Marks a session as a summary fork. Read by SessionStateMachine (to route the
  # fork's pause into harvesting rather than into the user's action queue) and by
  # Session.excluding_status_summary_forks (to keep it out of every list an
  # operator reads).
  FORK_MARKER = "status_summary_for_session_id"
  INLINE_TRANSCRIPT_MAX_CHARS = 80.kilobytes

  # Carried by BOTH summary prompts, which is the point of hoisting it into a
  # constant: the fork and the one-shot path write the same panel, so a rule
  # about what the panel may assert cannot live in only one of them.
  #
  # THE DEFECT THIS EXISTS FOR (#734). A blurb said, in the first person, "I've
  # scheduled a self-wake to re-poll at 22:45Z and apply the label once it turns
  # green" for a session that had scheduled no wake and had no trigger of any
  # kind. The session sat stranded for 16 hours reading, on the homepage, as a
  # healthy machine wait — the exact inversion of what the panel is for. The
  # summary is a description of state, not a plan: the summarizer is told not to
  # run tools, so an action it narrates in the future tense has nothing behind
  # it and no reader can check it.
  #
  # The second half is what keeps the rule from eating the panel's most useful
  # sentence. Waiting on a HUMAN is the commonest resting state there is, and no
  # transcript ever shows a session "arranging" it — so the rule bounds itself to
  # machine waits, and "waiting for your review" stays sayable.
  STATE_NOT_INTENT_RULE = <<~RULE.strip
    - Describe state, not intent. Never claim in the first person an action the
      session has not already taken — a scheduled wake, a follow-up, a retry, a
      label about to be applied. Say it is waiting on a machine event — a wake,
      a trigger, a check it is polling — only where the conversation shows it
      arranged that wait; a session that stopped without arranging one is
      waiting on a person, so say that instead.
  RULE

  # --- The pool-independent path (see #run_headless) --------------------------

  # Wall-clock budget for the one-shot completion. Generous enough for a long
  # excerpt on a small model, short enough that a sweep repairing a batch of
  # sessions cannot tie the queue up: the call is abandoned and the session stays
  # a candidate for the next sweep.
  HEADLESS_TIMEOUT = 90

  # A status blurb is the same shape of work as a session title, and
  # SessionTitleJob has run titles on Haiku all along. Matches ModelCatalog's
  # "haiku" id for claude_code.
  HEADLESS_MODEL = "haiku"

  # Smaller than the fork's inline cap. The fork is an agent with a full context
  # window; this is one prompt to a small model, and the tail of a conversation
  # is where "where does this stand" is answered.
  HEADLESS_TRANSCRIPT_MAX_CHARS = 24.kilobytes

  Result = Struct.new(:outcome, :message, :fork_session, keyword_init: true) do
    def started? = outcome == :started
  end

  attr_reader :session, :force, :headless

  # @param headless [Boolean] produce the blurb with a single pool-independent
  #   `claude -p` completion instead of forking. See #run_headless.
  def initialize(session:, force: false, headless: false, fork_service: ForkSessionService, file_system: nil,
                 inference_service: nil)
    @session = session
    @force = force
    @headless = headless
    @fork_service = fork_service
    @file_system = file_system
    @inference_service = inference_service
    # The `requested_at` this run wrote when it claimed the record, and the
    # attributes that claim displaced. Both nil until it has claimed. See #claim.
    @claim_token = nil
    @displaced = nil
    @logger = StructuredLogger.new({ session_id: session.id, service: "SessionStatusSummaryGenerator" })
  end

  def self.call(...) = new(...).call

  # Why a generation cannot run for this session at all — nil when one could.
  #
  # The three surfaces that offer "Regenerate" (the Status panel, the MCP
  # `action_session` action, the REST endpoint) ask this BEFORE they enqueue, so
  # a request that cannot possibly produce a summary is answered with the reason
  # instead of a job that declines in silence. All three pass `force: true`,
  # because all three ARE the forced path — they are asking whether the button
  # they are about to offer would do anything. It reads the session and, for an
  # automatic run, stats the clone directory; it writes nothing and enqueues
  # nothing, so rendering the panel still cannot trigger generation.
  def self.unavailable_reason(...) = new(...).unavailable_reason

  # The instance half of the class method above.
  #
  # The first two are genuinely impossible and refuse whatever the caller wants:
  # a fork asked to summarize itself has nothing to say, and a session with no
  # transcript has nothing to say it about. A missing clone is not in that class
  # — a forced run scaffolds one — so it only refuses an automatic run, and is
  # the only reason here that carries `:unavailable`.
  #
  # Every reason a FORCED run can hit is therefore answered by the three surfaces
  # BEFORE they enqueue, which is what keeps the panel off a spinner that never
  # resolves. A new reason that a forced run cannot resolve has to be answered the
  # same way — and, since #call would then reach it with a claim already taken,
  # would need #call to record it against the record on the way out.
  def unavailable_reason
    if session.status_summary_fork?
      Result.new(outcome: :skipped, message: "A status-summary fork does not summarize itself.")
    elsif !RuntimeConversationPresence.conversation?(session.transcript, session: session)
      # Line count is the wrong question here for the same reason it was the wrong
      # question in RuntimeConversationPresence (#519): a session wedged in its
      # opening seconds has a one-line transcript holding a title record and no
      # conversation. Forking on that spends an agent turn asking for a summary of
      # nothing, with neither a resume file nor an inline excerpt to answer from —
      # an invitation to invent one.
      Result.new(outcome: :skipped, message: "Session has no conversation to summarize yet.")
    elsif !force && !headless && !source_clone_available?
      Result.new(outcome: :unavailable, message: clone_unavailable_message)
    end
  end

  def call
    # Nothing is recorded against the panel here. Every refusal a forced run can
    # reach is one the three request surfaces already answered from
    # #unavailable_reason before enqueuing, so there is no click waiting on a
    # panel that would spin — and no claim has been taken yet to record against.
    refusal = refuse_reason
    return refusal if refusal

    summary = summary_record
    line_count = session.transcript_line_count

    return Result.new(outcome: :fresh, message: "Summary is current.") if !force && !summary.stale?(line_count)

    unless claim(summary, line_count)
      return Result.new(outcome: :pending, message: "A summary is already being generated.")
    end

    # The claim is taken the same way for both paths, so a fork and a one-shot
    # can never both be writing this record. Everything below it is the fork.
    #
    # The pool is re-checked here rather than trusted from the caller, because
    # the two forced surfaces do not check it at all: an operator pressing
    # Regenerate during an outage would otherwise pay for a clone copy, watch
    # the fork park, and be told the generation failed. A fork that cannot run
    # is not a better summary than a one-shot — it is no summary.
    return run_headless(summary, line_count) if headless || pool_exhausted?

    fork_args = {
      source_session: session,
      # NOT `line_count - 1`: the fork service indexes into the JSON-PARSED
      # transcript, which drops blank and unparseable lines. One blank line
      # would put the last raw index out of range and fail every automatic
      # generation for this session.
      message_index: ForkSessionService.parsed_messages(session.transcript).length - 1,
      extra_metadata: { FORK_MARKER => session.id },
      # The summarizer reads the conversation it was forked with and is told not
      # to run tools — it never builds or boots anything, so copying the
      # installed-dependency trees buys it nothing and costs it the tens of
      # seconds that make a concurrent-mutation race likely in the first place.
      # A user-initiated fork keeps them; it is a working session.
      copy_exclusions: ForkSessionService::DEPENDENCY_DIRECTORIES,
      # The whole reason Regenerate works on a session archived long ago: its
      # clone is gone, and this fork does not need it. Forced only — restoring
      # anything for a session nobody is looking at is the waste the automatic
      # path's refusals exist to prevent.
      scaffold_missing_clone: force
    }
    fork_args[:file_system] = @file_system if @file_system
    result = @fork_service.call(**fork_args)

    unless result.success?
      # The same benign outcome as the archived-check below, reached from the
      # losing side of the same race: the session went to the trash while its
      # clone was being copied, and the cleanup deleted the tree out from under
      # the copy. There is no fork to abandon and no failure worth recording —
      # nobody asked for this one — so the claim goes back exactly as it was
      # found and this is a skip, not a failure.
      #
      # Reachable in practice only on the automatic path: a forced run tells the
      # fork service to scaffold rather than fail when the tree is gone, so
      # losing that race costs it an empty directory instead of the generation.
      # A forced run can still be handed the flag if the scaffold could not be
      # started — the partial destination would not clear — and that is a real
      # failure it reports as one, below, rather than as a quiet skip.
      if result.source_clone_discarded && !force
        release_claim(summary)
        return Result.new(outcome: :skipped, message: "Session is in the trash.")
      end

      record_failure(result.error)
      return Result.new(outcome: :failed, message: result.error)
    end

    fork = result.forked_session

    # Everything from here to the follow-up has a fork on the floor. A fork that
    # is made and then never dispatched is the worst thing this service can
    # leave behind: it is hidden from every operator list by
    # `excluding_status_summary_forks`, and its clone is skipped by
    # OrphanCloneFilesystemCleanupJob precisely because a session row still
    # claims it — so a full copy of a repository sits there permanently. Dispose
    # of it on every exit that is not "dispatched".
    begin
      # #refuse_reason asked this before the fork, but the copy takes real time
      # and the answer can change during it. A fork of a session that has since
      # gone to the trash is a copy of a clone DeferredCloneCleanupJob is about
      # to delete, about a session nobody is looking at.
      #
      # `!force` for the same reason the trash is not a refusal for a forced run:
      # somebody pressed Regenerate on this session, so it is not one nobody is
      # looking at. The fork owns its own copy of the clone by now, so the
      # source's going to the trash costs the fork nothing.
      if !force && session.reload.archived?
        release_claim(summary)
        abandon_fork(fork)
        return Result.new(outcome: :skipped, message: "Session is in the trash.")
      end

      prepare_fork(fork)

      # The record names the fork BEFORE the fork is dispatched. The fork's turn
      # can finish (or die on spawn) before this method returns, and the harvest
      # job keys off this row — writing it afterwards would let a harvest land on
      # a record that names no fork, then be stomped back to `pending` here.
      #
      # Conditional on this runner still holding the claim it took before the
      # copy: a copy that outlived PENDING_TIMEOUT can have had the record taken
      # over by a newer generation, and pointing it back at this fork would make
      # the harvest of the newer one look stale and drop its answer.
      unless attach_fork(summary, fork)
        abandon_fork(fork)
        return Result.new(outcome: :pending, message: "A newer summary generation took over.")
      end

      fork.deliver_follow_up!(prompt_for(fork))
    rescue StandardError
      abandon_fork(fork)
      raise
    end

    @logger.info("Status summary generation started", fork_session_id: fork.id, transcript_line_count: line_count)
    Result.new(outcome: :started, message: "Generating summary…", fork_session: fork)
  rescue StandardError => e
    @logger.error("Failed to start status summary generation", error: e.message)
    record_failure(e.message)
    Result.new(outcome: :failed, message: e.message)
  end

  private

  # The row, guaranteed to exist and guaranteed to be one row.
  #
  # It used to be read-or-BUILT at the top of #call and inserted only after the
  # fork's filesystem copy had finished — a read-then-insert window seconds
  # wide, in which a second generation for the same session saw no row, built
  # its own, and lost on the unique index (PG::UniqueViolation). Creating it
  # here, before anything slow, gives the claim below something real to read and
  # makes every later write a plain UPDATE.
  #
  # `create_or_find_by!` rather than `find_or_create_by!`: the check-then-insert
  # in the latter is the same race one layer down. The plain `find_by` first is
  # only to keep the common path (a row that already exists) from issuing an
  # INSERT it knows will fail.
  def summary_record
    SessionStatusSummary.find_by(session_id: session.id) ||
      SessionStatusSummary.create_or_find_by!(session_id: session.id)
  end

  # Claims the record for THIS generation, and is the mutual exclusion for the
  # whole service: a locked read-and-write that exactly one runner can win, with
  # the losers returning before they have paid for anything.
  #
  # Claiming BEFORE the fork rather than after it is the point. The record used
  # to be marked `pending` once the clone copy had already finished, so the
  # guard could not see a competing generation that was still copying — and two
  # runners could each spend a full copy of a repository on one session.
  #
  # `requested_at` doubles as the claim token. Every later write this runner
  # makes is conditional on the row still carrying the timestamp it wrote, so a
  # runner whose claim aged past PENDING_TIMEOUT and was taken over by a newer
  # generation cannot stomp that newer one on its way out.
  def claim(summary, line_count)
    claimed = false

    summary.with_lock do
      next if summary.pending?

      # Snapshotted under the lock, so a release puts back what was actually
      # displaced rather than what a read before the lock thought was there.
      @displaced = summary.slice(:state, :error, :requested_at, :requested_line_count, :fork_session_id)

      summary.update!(
        state: "pending",
        requested_at: Time.current,
        requested_line_count: line_count,
        fork_session: nil,
        error: nil
      )
      claimed = true
    end

    # Read the token back rather than trusting the in-memory value: the token is
    # only useful if it is byte-for-byte what a later reload will compare against.
    @claim_token = summary.reload.requested_at if claimed
    claimed
  end

  # Points the claimed record at the fork that will answer it. False means the
  # claim was lost while the copy ran, and the caller disposes of the fork.
  def attach_fork(summary, fork)
    attached = false

    summary.with_lock do
      next unless holds_claim?(summary)

      summary.update!(fork_session: fork)
      attached = true
    end

    attached
  end

  # Puts the record back exactly the way it was found, for an exit that starts
  # nothing — a session that reached the trash during the copy. Without this the
  # claim would sit `pending` for the full PENDING_TIMEOUT with no fork behind
  # it; without restoring the whole snapshot, a previous failure's reason (which
  # the claim cleared) would be lost and the panel would say a summary failed
  # for no recorded reason.
  def release_claim(summary)
    summary.with_lock do
      next unless holds_claim?(summary)

      summary.update!(@displaced)
    end
  rescue StandardError => e
    @logger.error("Failed to release the status summary claim", error: e.message)
  end

  # Whether the row in the database is still the claim this runner took.
  # `with_lock` reloads first, so callers inside it are reading the DB.
  def holds_claim?(summary) = summary.state == "pending" && summary.requested_at == @claim_token

  # Reasons a session is not a candidate at all, as opposed to "not stale yet".
  #
  # Being archived is NOT one of them for a forced run, and neither is having no
  # clone left. Archive is how a Zimmer session finishes: its transcript stays
  # readable, it is exactly the kind of session someone opens later to ask "what
  # happened here", and the panel is what answers that. What generation actually
  # needs is the conversation, which is in the database — the fork's working
  # directory is scaffolded when the clone is gone. An AUTOMATIC generation still
  # skips both: nothing enqueues one for an archived session on purpose, and
  # standing up a fork for a session heading for deletion is waste.
  def refuse_reason
    unavailable_reason ||
      (Result.new(outcome: :skipped, message: "Session is in the trash.") if !force && session.archived?)
  end

  # Whether there is still a clone to fork. The same two conditions
  # ForkSessionService validates for a copy, asked here so an AUTOMATIC
  # generation declines before a job is enqueued rather than after one has
  # quietly declined. A forced run never asks: it scaffolds instead.
  #
  # `.to_s` because `metadata` is a JSON column: a non-string `clone_path` is
  # representable there, and `File.directory?` answers a TypeError rather than
  # false. This runs on the panel's render path and inside the panel broadcast,
  # neither of which may raise over a malformed row.
  def source_clone_available?
    clone_path = session.metadata&.dig("clone_path").to_s
    return false if clone_path.blank?

    file_system.directory?(clone_path)
  end

  # A separate ivar from `@file_system` deliberately: that one is passed on to
  # ForkSessionService and TranscriptRuntime only when a caller supplied it, and
  # both build their own default otherwise. Memoizing the default into it would
  # start handing them an adapter they were never given.
  def file_system = @resolved_file_system ||= (@file_system || RealFileSystemAdapter.new)

  # Why an AUTOMATIC generation declined. It reaches a log line and a Result, not
  # the panel — the three request surfaces are all forced, and a forced run
  # scaffolds rather than declines — so it is one sentence rather than prose
  # branched on how the clone came to be missing.
  def clone_unavailable_message
    "This session has no working clone on disk, so no summary is written for it automatically."
  end

  # A fork inherits the source's goal, and a goal is an instruction to act — a
  # summarizer carrying "open a PR and label it ready to merge" would go and do
  # that. It also inherits the source's title and heartbeat, neither of which
  # should follow a throwaway. Strip all three before handing it a prompt.
  #
  # A normal fork is treated as already-started because ForkSessionService
  # materializes a runtime transcript before the first follow-up. That is only
  # true for runtimes with a deterministic resume file. Codex rollouts cannot be
  # recreated at a deterministic path, so a status-summary fork must start as a
  # fresh one-shot turn and receive the copied conversation inline instead.
  #
  # FORK_MARKER is NOT set here — it is passed to the fork service so it is
  # present on the very first commit, before the dashboard broadcast fires.
  def prepare_fork(fork)
    metadata = fork.metadata.to_h
    metadata["runtime_started"] = false unless resumable_fork?(fork)

    fork.update!(
      goal: nil,
      title: "Status summary for session ##{session.id}",
      heartbeat_enabled: false,
      metadata: metadata
    )
    fork
  end

  # Disposes of a fork that was made but will never be prompted. Archiving is the
  # same path SessionStatusSummaryHarvestJob uses for a fork that has finished:
  # it reclaims the copied clone on the normal trash path rather than reaching
  # into the filesystem from here.
  def abandon_fork(fork)
    return if fork.nil?

    @logger.info("Abandoning an undispatched status summary fork", fork_session_id: fork.id)
    fork.archive_actor = "Zimmer's status-summary fork cleanup (never dispatched)"
    fork.archive! if fork.may_archive?
  rescue StandardError => e
    @logger.error("Failed to abandon status summary fork", fork_session_id: fork&.id, error: e.message)
  end

  # Writes the blurb with ONE `claude -p` completion and no fork at all.
  #
  # **Why this path exists.** The fork path needs a login-pool account, a copy of
  # the session's clone, and an agent turn. When the pool is exhausted the fork
  # is parked before it answers — and the pool is exhausted precisely when the
  # fleet is busiest, which is when the human most wants to read the queue. The
  # repair sweep that retries the fork used to stand down for the same outage,
  # so the retry was gated on the resource whose absence caused the failure it
  # was retrying: under sustained pressure the blurb was simply unreachable.
  #
  # A one-shot completion is not gated on any of that. It takes no account slot
  # (`claude -p` runs against the ambient credentials, so it never asks
  # `accounts.available`), copies no clone, boots no MCP server, and answers or
  # fails in HEADLESS_TIMEOUT seconds. It costs roughly what a session title
  # costs — SessionTitleJob has run on this substrate all along.
  #
  # What it gives up is the fork's reach: it answers from the rendered
  # conversation alone, so it cannot open a file or check a PR the way a forked
  # agent could. That is the trade, and it is the right way round — a slightly
  # terser blurb that is THERE beats a richer one that never arrives.
  def run_headless(summary, line_count)
    answer = StatusSummaryAnswer.clean(headless_answer)

    if answer.blank?
      record_failure(headless_failure_reason)
      return Result.new(outcome: :failed, message: headless_failure_reason)
    end

    unless publish(summary, answer, line_count)
      return Result.new(outcome: :pending, message: "A newer summary generation took over.")
    end

    @logger.info("Status summary written without a fork", transcript_line_count: line_count)
    note_headless_generation
    Result.new(outcome: :ready, message: "Summary written.")
  end

  # The raw completion, or nil. HeadlessInferenceService already swallows a
  # timeout or a non-zero exit into nil and logs it, so there is nothing to
  # rescue here — a nil is the failure, and #run_headless reports it as one.
  def headless_answer
    excerpt = StatusSummaryTranscriptExcerpt.render(session, max_chars: HEADLESS_TRANSCRIPT_MAX_CHARS)
    return nil if excerpt.blank?

    inference_service.generate(
      headless_prompt(excerpt),
      timeout: HEADLESS_TIMEOUT,
      model: HEADLESS_MODEL,
      single_line: false
    )
  end

  def inference_service = @inference_service ||= HeadlessInferenceService.new

  # Whether this runtime's login pool has anything left to run a fork on.
  #
  # Memoized, and deliberately fail-open: a pool that cannot be read is not
  # evidence of an outage, and guessing "exhausted" would silently downgrade
  # every generation to the cheaper path.
  def pool_exhausted?
    return @pool_exhausted unless @pool_exhausted.nil?

    @pool_exhausted =
      begin
        RuntimeAuthProvider.for(session.agent_runtime).accounts.available.none?
      rescue StandardError => e
        @logger.warn("Could not read the #{session.agent_runtime} account pool", error: e.message)
        false
      end
  end

  # Why nothing was stored, in terms the panel's reader can act on. Deliberately
  # does not distinguish "the model refused" from "the call failed": both mean
  # the same thing to the reader, and both are retried by the same sweep.
  def headless_failure_reason
    "Could not write a summary without a fork — the one-shot summary produced no usable answer. It will be retried."
  end

  # Writes the answer onto the claim this runner holds. Same lock-and-check
  # shape as #attach_fork and #record_failure: a runner whose claim aged past
  # PENDING_TIMEOUT and was taken over must not stomp the generation that
  # replaced it.
  def publish(summary, answer, line_count)
    published = false

    summary.with_lock do
      next unless holds_claim?(summary)

      summary.update!(
        summary: answer,
        generated_at: Time.current,
        transcript_line_count: line_count,
        state: "ready",
        error: nil,
        fork_session: nil
      )
      published = true
    end

    published
  end

  # Says on the session's own timeline that this blurb came from the cheap path,
  # so a reader who finds it terser than usual can see why. Best-effort: a
  # timeline write must not fail a summary that already landed.
  def note_headless_generation
    session.logs.create!(
      content: "Wrote the status summary with a one-shot inference call (no fork)",
      level: "info"
    )
  rescue StandardError => e
    @logger.error("Failed to note the headless status summary", error: e.message)
  end

  # The fork is asked to summarize a conversation it is already holding; this
  # asks the same question of a model that has only the text below. The rules
  # are the fork's rules minus the two that assume an agent — there are no tools
  # to decline to run, and no transcript beyond what is in the prompt.
  def headless_prompt(excerpt)
    <<~PROMPT
      Write the Status panel for this Zimmer session (##{session.id}). It is read
      at a glance, above the transcript, by someone deciding whether this session
      needs them right now.

      Rules:
      - 2-3 sentences. Not four. Say where things stand, not how you got here.
      - Link instead of explaining. If a detail is worth more than a clause, link
        to where it lives rather than spending a sentence on it.
      - Markdown links only, no headings, no bullet lists, no preamble, no
        trailing offer to help.
      - Answer only from the conversation below. Do not invent a detail it does
        not contain.
      #{STATE_NOT_INTENT_RULE}

      Links you can use:
      - Any pull request, issue, or run URL that appears in the conversation,
        linked by what it is ("PR #123", "the failing CI run").
      - Another Zimmer session: #{AppUrl.base_url}/sessions/ID.
      #{conversation_section(excerpt)}
      Reply with the summary text and nothing else.
    PROMPT
  end

  def prompt_for(fork)
    <<~PROMPT
      Write the Status panel for this Zimmer session (##{session.id}). It is read
      at a glance, above the transcript, by someone deciding whether this session
      needs them right now.

      Rules:
      - 2-3 sentences. Not four. Say where things stand, not how you got here.
      - Link instead of explaining. If a detail is worth more than a clause, link
        to where it lives rather than spending a sentence on it.
      - Markdown links only, no headings, no bullet lists, no preamble, no
        trailing offer to help.
      - Do not run any tools. Answer only from the conversation you already have,
        and do not invent a detail it does not contain.
      #{STATE_NOT_INTENT_RULE}

      Links you can use:
      - A specific message in this session's transcript:
        [what happened there](#{session_url}#message-INDEX) — INDEX is the
        transcript index of the message, counting from 0 at the first line of the
        conversation. Prefer the message where a decision, a failure, or a
        deliverable actually appears.
      - Any pull request, issue, or run URL that came up in the conversation,
        linked by what it is ("PR #123", "the failing CI run").
      - Another Zimmer session: #{AppUrl.base_url}/sessions/ID.
      #{inline_transcript_for(fork)}
      Reply with the summary text and nothing else.
    PROMPT
  end

  def session_url = "#{AppUrl.base_url}/sessions/#{session.id}"

  # Two conditions, because a fork resumes only when BOTH hold: the runtime has
  # a deterministic resume file at all (Codex does not), and ForkSessionService
  # actually wrote one. It declines to write for a source whose transcript holds
  # no conversation — a session wedged by #519 has only a title record — and says
  # so by leaving `runtime_started` off. Asking the path question alone would
  # send such a fork to `--resume` against a file that was never written.
  def resumable_fork?(fork)
    return false unless fork.metadata&.dig("runtime_started") == true

    working_directory = fork.metadata&.dig("working_directory")
    TranscriptRuntime.source_for(fork, file_system: @file_system)
      .resume_transcript_path(session: fork, working_directory: working_directory)
      .present?
  end

  def inline_transcript_for(fork)
    return "" if resumable_fork?(fork)

    excerpt = StatusSummaryTranscriptExcerpt.render(fork, max_chars: INLINE_TRANSCRIPT_MAX_CHARS)
    return "" if excerpt.blank?

    conversation_section(excerpt)
  end

  def conversation_section(excerpt)
    <<~TEXT

      Conversation so far:
      ```text
      #{excerpt}
      ```
    TEXT
  end

  # Records a failure against the row as it exists IN THE DATABASE.
  #
  # This handler used to re-run `session.status_summary || session.build_status_summary`
  # — the very read-or-build expression whose insert had just failed — so a
  # generation that died on a duplicate key died the same way while reporting
  # it, and the rescue below swallowed the second death. The record was left
  # `pending` and the panel spun on "Generating…" until PENDING_TIMEOUT. A
  # handler whose only job is to record a failure must not be able to fail the
  # way the thing it is recording failed.
  #
  # Under the row lock, like #attach_fork and #release_claim: checking the claim
  # and then writing outside the lock is the check-then-write shape this whole
  # rework exists to remove, and it would let a runner whose claim aged out in
  # the gap stomp the one that replaced it.
  def record_failure(error)
    row = summary_record

    row.with_lock do
      next unless may_record_outcome?(row)

      row.update!(state: "failed", error: error.to_s.truncate(SessionStatusSummary::MAX_ERROR_CHARS), fork_session: nil)
    end
  rescue StandardError => e
    @logger.error("Failed to record status summary failure", error: e.message)
  end

  # A runner writes an outcome only onto the claim it holds. A failure raised
  # before it ever claimed (creating or reading the row itself) is still worth
  # showing, but only when nobody else's generation is in flight to overwrite.
  def may_record_outcome?(row)
    return !row.pending? if @claim_token.nil?

    holds_claim?(row)
  end
end
