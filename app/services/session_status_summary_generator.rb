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
#   1. This service forks the session at its last transcript message and sends
#      the fork one follow-up prompt (the summary request), then marks the
#      summary record `pending`.
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
class SessionStatusSummaryGenerator
  # Marks a session as a summary fork. Read by SessionStateMachine (to route the
  # fork's pause into harvesting rather than into the user's action queue) and by
  # Session.excluding_status_summary_forks (to keep it out of every list an
  # operator reads).
  FORK_MARKER = "status_summary_for_session_id"

  Result = Struct.new(:outcome, :message, :fork_session, keyword_init: true) do
    def started? = outcome == :started
  end

  attr_reader :session, :force

  def initialize(session:, force: false, fork_service: ForkSessionService, file_system: nil)
    @session = session
    @force = force
    @fork_service = fork_service
    @file_system = file_system
    @logger = StructuredLogger.new({ session_id: session.id, service: "SessionStatusSummaryGenerator" })
  end

  def self.call(...) = new(...).call

  def call
    refusal = refuse_reason
    return refusal if refusal

    summary = session.status_summary || session.build_status_summary
    line_count = session.transcript_line_count

    return Result.new(outcome: :fresh, message: "Summary is current.") if !force && !summary.stale?(line_count)
    return Result.new(outcome: :pending, message: "A summary is already being generated.") if summary.pending?

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
      copy_exclusions: ForkSessionService::DEPENDENCY_DIRECTORIES
    }
    fork_args[:file_system] = @file_system if @file_system
    result = @fork_service.call(**fork_args)

    unless result.success?
      record_failure(summary, result.error)
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
      if session.reload.archived?
        abandon_fork(fork)
        return Result.new(outcome: :skipped, message: "Session is in the trash.")
      end

      prepare_fork(fork)

      # Marked pending BEFORE the fork is dispatched. The fork's turn can finish
      # (or die on spawn) before this method returns, and the harvest job keys off
      # this row — writing it afterwards would let a harvest land on a record that
      # names no fork, then be stomped back to `pending` here.
      summary.update!(
        state: "pending",
        requested_at: Time.current,
        requested_line_count: line_count,
        fork_session: fork,
        error: nil
      )

      fork.deliver_follow_up!(prompt_for(fork))
    rescue StandardError
      abandon_fork(fork)
      raise
    end

    @logger.info("Status summary generation started", fork_session_id: fork.id, transcript_line_count: line_count)
    Result.new(outcome: :started, message: "Generating summary…", fork_session: fork)
  rescue StandardError => e
    @logger.error("Failed to start status summary generation", error: e.message)
    record_failure(session.status_summary || session.build_status_summary, e.message)
    Result.new(outcome: :failed, message: e.message)
  end

  private

  # Reasons a session is not a candidate at all, as opposed to "not stale yet".
  def refuse_reason
    if session.status_summary_fork?
      Result.new(outcome: :skipped, message: "A status-summary fork does not summarize itself.")
    elsif session.archived?
      Result.new(outcome: :skipped, message: "Session is in the trash.")
    elsif session.transcript_line_count.zero?
      Result.new(outcome: :skipped, message: "Session has no transcript yet.")
    end
  end

  # A fork inherits the source's goal, and a goal is an instruction to act — a
  # summarizer carrying "open a PR and label it ready to merge" would go and do
  # that. It also inherits the source's title and heartbeat, neither of which
  # should follow a throwaway. Strip all three before handing it a prompt.
  #
  # FORK_MARKER is NOT set here — it is passed to the fork service so it is
  # present on the very first commit, before the dashboard broadcast fires.
  def prepare_fork(fork)
    fork.update!(
      goal: nil,
      title: "Status summary for session ##{session.id}",
      heartbeat_enabled: false
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
    fork.archive! if fork.may_archive?
  rescue StandardError => e
    @logger.error("Failed to abandon status summary fork", fork_session_id: fork&.id, error: e.message)
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
      - Do not run any tools. Answer from the conversation you already have.

      Links you can use:
      - A specific message in this session's transcript:
        [what happened there](#{session_url}#message-INDEX) — INDEX is the
        transcript index of the message, counting from 0 at the first line of the
        conversation. Prefer the message where a decision, a failure, or a
        deliverable actually appears.
      - Any pull request, issue, or run URL that came up in the conversation,
        linked by what it is ("PR #123", "the failing CI run").
      - Another Zimmer session: #{AppUrl.base_url}/sessions/ID.

      Reply with the summary text and nothing else.
    PROMPT
  end

  def session_url = "#{AppUrl.base_url}/sessions/#{session.id}"

  def record_failure(summary, error)
    summary.update!(state: "failed", error: error.to_s.truncate(500), fork_session: nil)
  rescue StandardError => e
    @logger.error("Failed to record status summary failure", error: e.message)
  end
end
