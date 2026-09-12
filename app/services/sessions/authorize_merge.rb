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
  # Three records carry the provenance, deliberately more than one:
  #
  #   * a HumanMessage, written through WebUiHumanMessageCapture — the same
  #     attribution every other thing typed into the web UI gets, and the record
  #     that says a PERSON did this;
  #   * a session log line naming the PR and the surface;
  #   * `merge_authorized_prs` on the session's custom_metadata, keyed by PR url,
  #     which is what makes a second click harmless and what the button reads to
  #     show itself as already sent.
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

      if authorized_at(pr_url).present?
        return Result.new(
          outcome: :already_sent,
          pr_url: pr_url,
          message: "Merge already authorized for #{pr_url} — the session has the message."
        )
      end

      # Recorded BEFORE the send, so a double-click that lands while the first is
      # still delivering finds the marker rather than sending a second copy. A
      # send that then fails clears it again below, so a transient failure does
      # not brick the button.
      record_authorization!(pr_url)

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

    # When this session was last authorized to merge `pr_url`, or nil.
    #
    # @param session [Session]
    # @param pr_url [String, nil]
    # @return [String, nil] an ISO8601 timestamp
    def self.authorized_at(session, pr_url)
      return nil if pr_url.blank?

      (session.custom_metadata&.dig(METADATA_KEY) || {})[pr_url].presence
    end

    private

    def authorized_at(pr_url)
      self.class.authorized_at(@session, pr_url)
    end

    def record_authorization!(pr_url)
      existing = @session.custom_metadata&.dig(METADATA_KEY) || {}
      @session.merge_custom_metadata!(METADATA_KEY => existing.merge(pr_url => Time.current.utc.iso8601))
    end

    def clear_authorization!(pr_url)
      existing = @session.custom_metadata&.dig(METADATA_KEY) || {}
      @session.merge_custom_metadata!(METADATA_KEY => existing.except(pr_url))
    end
  end
end
