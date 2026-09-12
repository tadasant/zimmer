# frozen_string_literal: true

module Sessions
  # The Merge button on the dashboard's User view: a human's click turned into a
  # message the session holding the PR can act on.
  #
  # == Why this exists at all
  #
  # Zimmer's standing convention is that an agent does not merge its own work.
  # The pull request is the review gate and the session that opened one holds it
  # until a human decides. This service is that decision, delivered: the human's
  # click IS the sign-off, and the message it sends says so in terms the merging
  # session and anyone auditing the transcript later can both recognise (see
  # AutomatedPrompts::MERGE_AUTHORIZATION_MARKER).
  #
  # Three records are written, and they are not equal:
  #
  #   * a HumanMessage, written through WebUiHumanMessageCapture — the same
  #     attribution every other thing typed into the web UI gets. THIS is the
  #     proof a person did it. It has one writer, the browser controllers; the
  #     MCP and REST surfaces cannot create one. The `[HUMAN-AUTHORIZED MERGE]`
  #     marker in the message text is NOT proof on its own — `action_session`'s
  #     `follow_up` delivers any text, marker included — so an audit keys on the
  #     HumanMessage, not on the marker;
  #   * a session log line naming the PR and the surface;
  #   * `merge_authorized_prs` on the session's custom_metadata, keyed by PR url,
  #     which is what the button reads to show itself as already sent.
  #
  # == When an authorization stops counting
  #
  # The message tells the agent to come back to `needs_input` if it cannot merge —
  # a conflict it cannot resolve, CI gone red. A marker that never cleared would
  # leave that row reading "Merge sent" forever, with the server refusing the one
  # click that could retry. So an authorization is only LIVE while the session has
  # not yet come back to rest from it: once the session is in `needs_input` again,
  # has taken a turn since (its transcript grew), and holds no still-undelivered
  # copy of the message, the button is offered again.
  #
  # == Queued, not an interrupt
  #
  # The message goes through AutomatedSessionMessage, which delivers immediately
  # to a session parked in `needs_input` and queues it otherwise. It never
  # interrupts a running turn, and that is the right trade in both directions:
  #
  #   * The population this button exists for is the one parked in `needs_input`
  #     holding its own PR, and that is the immediate branch. The click reaches
  #     the agent as its next turn, now.
  #   * A session mid-turn is doing work the human did not ask to abort. A merge
  #     is not urgent to the second, so it waits for the turn boundary.
  #   * A session asleep in `waiting` on its own self-wake is the case worth being
  #     explicit about, because "queued" would otherwise mean "whenever it happens
  #     to wake". It does not: EnqueuedMessage's after_create_commit schedules
  #     EnqueuedMessageDrainJob for any session already idle by
  #     Session#idle_for_queued_delivery?, which covers BOTH resting states. The
  #     message wakes it.
  #
  # The origin stays `caller`, the default, rather than a new automated_* one.
  # These origins separate messages somebody is waiting on from notices Zimmer
  # addresses to itself, and a human is waiting on this one. It also means an
  # archive that discards it raises, which is correct — a merge authorization
  # thrown away is exactly the event that alert exists to report.
  class AuthorizeMerge
    include DatabaseRetry
    include AutomatedSessionMessage

    # Where the per-PR authorization record lives on custom_metadata.
    METADATA_KEY = "merge_authorized_prs"

    # What happened, so the controller can render one of three answers without
    # re-deriving any of it.
    #
    #   :sent          — the message was delivered or queued
    #   :already_sent  — this PR was already authorized; nothing was written
    #   :not_mergeable — the PR is not open-and-green (or there is no PR)
    #   :undeliverable — the session could not take the message
    Result = Data.define(:outcome, :pr_url, :message) do
      def sent? = outcome == :sent
      def ok? = outcome == :sent || outcome == :already_sent
    end

    # @param session [Session] the session holding the PR
    # @return [Result]
    def self.call(session:)
      new(session: session).call
    end

    def initialize(session:)
      @session = session
    end

    def call
      summary = PrSummary.for(@session)
      pr_url = summary.url

      if (reason = summary.merge_blocked_reason)
        return Result.new(outcome: :not_mergeable, pr_url: pr_url, message: "Cannot merge: #{reason}")
      end

      # Claimed BEFORE the send, and claimed under the session's row lock with a
      # fresh read. Two requests landing together — two tabs, a retried POST — each
      # loaded their own copy of the session before either wrote, so a check against
      # the in-memory copy would let both through and deliver two merge messages. A
      # send that then fails clears the claim below, so a transient failure does not
      # brick the button.
      unless claim_authorization!(pr_url)
        return Result.new(
          outcome: :already_sent,
          pr_url: pr_url,
          message: "Merge already authorized for #{pr_url} — the session has the message."
        )
      end

      delivered = deliver_automated_message(
        @session,
        AutomatedPrompts.merge_authorization_message(pr_url),
        event_description: "User authorized the merge of #{pr_url} with the Merge button in the Zimmer dashboard",
        origin: "caller"
      )

      unless delivered
        clear_authorization!(pr_url)
        return Result.new(
          outcome: :undeliverable,
          pr_url: pr_url,
          message: "Could not deliver the merge authorization to session #{@session.id}. Nothing was sent."
        )
      end

      Result.new(
        outcome: :sent,
        pr_url: pr_url,
        message: "Merge authorized. Session #{@session.id} has been told to merge #{pr_url}."
      )
    end

    # When this session was authorized to merge `pr_url`, or nil when there is no
    # LIVE authorization — none was ever given, or the session has since come back
    # to rest without merging (see the class comment).
    #
    # @param session [Session]
    # @param pr_url [String, nil]
    # @return [String, nil] an ISO8601 timestamp
    def self.authorized_at(session, pr_url)
      return nil if pr_url.blank?

      entry = (session.custom_metadata&.dig(METADATA_KEY) || {})[pr_url]
      return nil if entry.blank?
      return nil if stale?(session, entry)

      entry.is_a?(Hash) ? entry["at"] : entry.to_s
    end

    # Whether the session has come back to rest from this authorization without
    # merging. Three conditions, all required:
    #
    #   * it is in `needs_input` — a session still running or queued is working on
    #     it, and must keep reading "Merge sent";
    #   * its transcript has grown since the click — it took the turn; a click on a
    #     session that has not moved yet is not a failure to act on;
    #   * no undelivered copy of the message is still queued for it — a session that
    #     came to rest from OTHER work before the queued authorization drained has
    #     not answered it yet.
    def self.stale?(session, entry)
      return false unless entry.is_a?(Hash)
      return false unless session.needs_input?
      return false unless session.transcript_line_count.to_i > entry["transcript_line_count"].to_i

      session.enqueued_messages.pending.none? { |message| AutomatedPrompts.merge_authorization?(message.content) }
    end
    private_class_method :stale?

    private

    # Records the authorization unless a live one already exists, atomically.
    #
    # @return [Boolean] true when this call made the claim, false when a live
    #   authorization was already in place
    def claim_authorization!(pr_url)
      @session.with_lock do
        return false if self.class.authorized_at(@session, pr_url).present?

        existing = @session.custom_metadata&.dig(METADATA_KEY) || {}
        @session.merge_custom_metadata!(
          METADATA_KEY => existing.merge(
            pr_url => {
              "at" => Time.current.utc.iso8601,
              "transcript_line_count" => @session.transcript_line_count.to_i
            }
          )
        )
        true
      end
    end

    def clear_authorization!(pr_url)
      existing = @session.custom_metadata&.dig(METADATA_KEY) || {}
      @session.merge_custom_metadata!(METADATA_KEY => existing.except(pr_url))
    end
  end
end
