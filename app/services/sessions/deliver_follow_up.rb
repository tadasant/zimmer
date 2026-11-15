# frozen_string_literal: true

module Sessions
  # Delivers a follow-up straight to an idle session: the REST endpoint's
  # (`POST /api/v1/sessions/:id/follow_up`) and the `action_session` MCP tool's
  # `follow_up` branch for a session that is `waiting` or `needs_input` with no
  # turn underway.
  #
  # The delivery itself is Session#deliver_follow_up! — the same writer the web
  # form, triggers, pollers and `message_parent` use: resume for a follow-up (so
  # the session's own pending wake-ups survive it, #898), stamp the tagged prompt
  # as `pending_follow_up_prompt` after the resume (#1023), enqueue the job and
  # record its id. What this service adds is the part the two API doors share and
  # the web form does not: the goal and the `prompt` column, written by
  # Sessions::FollowUpGoal in the one UPDATE they have always shared, and the
  # transaction around the whole sequence.
  #
  # The caller's block runs inside that transaction, after the goal and before
  # the job is enqueued. That is where a surface records what the job it starts
  # must already see — the uncle edge, the human message — and where a failed
  # delivery rolls them back with it.
  #
  # Scope: it does not check the session's state (each surface words its own
  # refusal, and REST discards staged attachments on it), does not decide
  # between delivering, queueing and interrupting, and renders nothing.
  class DeliverFollowUp
    # @param session [Session] an idle session (`waiting` or `needs_input`)
    # @param prompt [String] the follow-up text, already validated by the caller
    # @param goal [String, nil] normalized; a non-blank one overwrites the session's goal
    # @param source [TurnSource, nil] the surface's turn source
    # @param images [Array, nil] image paths forwarded to the job
    # @param files [Array, nil] file paths forwarded to the job
    # @yield inside the transaction, before the job is enqueued
    # @return [ActiveJob::Base] the enqueued job
    # @raise [ActiveRecord::RecordInvalid] when the goal or prompt fails a validation
    def self.call(session:, prompt:, goal:, source:, images: nil, files: nil, &before_enqueue)
      ActiveRecord::Base.transaction do
        FollowUpGoal.apply!(
          session: session,
          goal: goal,
          source: :follow_up,
          also_update: { prompt: prompt }
        )
        before_enqueue&.call
        session.deliver_follow_up!(prompt, images: images, files: files, source: source)
      end
    end
  end
end
