# frozen_string_literal: true

# Answers one question about an `AgentSessionJob` that is identified only by its
# ActiveJob id: was it enqueued to SPAWN a turn, or only to MONITOR one that is
# already running?
#
# The distinction matters exactly once, in the monitoring loop's ownership backstop.
# That backstop terminates this job's agent process the moment `running_job_id` names
# somebody else, on the premise that the new owner has replaced our turn. The premise
# holds for every job that spawns — and fails for a job enqueued with
# `resume_monitoring: true`, which by construction spawns nothing and exists purely to
# re-attach to a process someone else started. Terminating for one of those leaves the
# session with no live agent at all, and the adopting job then reconnects to a corpse.
# That is zimmer#489.
#
# The intent is read from the job's own serialized arguments rather than inferred from
# session state, because it is a property of the enqueue, fixed at the moment the
# decision was made, and session state is precisely what is racing.
class AgentJobIntent
  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  class << self
    # @param active_job_id [String, nil] the ActiveJob id recorded in `running_job_id`
    # @return [Boolean] true only when the job is provably an AgentSessionJob enqueued
    #   with `resume_monitoring: true`. Anything unknown — no such row, a different job
    #   class, unreadable arguments — answers false, which leaves every caller on its
    #   pre-existing behaviour.
    def monitor_only?(active_job_id)
      return false if active_job_id.blank?

      # `good_jobs.active_job_id` is a uuid column, and ActiveRecord silently casts a
      # non-uuid string to NULL — which would turn this lookup into `IS NULL` and match
      # a row that has nothing to do with the id asked about. Every real ActiveJob id is
      # a uuid; anything else can only be a test fixture, and answering from the
      # in-memory adapter is the right answer for one of those.
      job = GoodJob::Job.find_by(active_job_id: active_job_id) if UUID_PATTERN.match?(active_job_id)
      return monitor_only_arguments?(job.serialized_params&.dig("arguments")) if job

      monitor_only_in_test_adapter?(active_job_id)
    rescue StandardError => e
      # A failure here must not change what the caller does: false is the answer that
      # preserves the behaviour that predates this class.
      Rails.logger.error("[AgentJobIntent] Could not read intent for job #{active_job_id}: #{e.class}: #{e.message}")
      false
    end

    private

    # AgentSessionJob's enqueue helpers all pass options as the third positional
    # argument, so a monitoring job serializes as
    # `[session_id, nil, {"resume_monitoring" => true, ...}]`.
    def monitor_only_arguments?(arguments)
      return false unless arguments.is_a?(Array)

      options = arguments[2]
      return false unless options.is_a?(Hash)

      options["resume_monitoring"] == true || options[:resume_monitoring] == true
    end

    # The ActiveJob test adapter keeps enqueued jobs in memory rather than in
    # `good_jobs`, so tests exercising the backstop have nothing to find above.
    def monitor_only_in_test_adapter?(active_job_id)
      return false unless Rails.env.test?

      adapter = ActiveJob::Base.queue_adapter
      jobs = (adapter.try(:enqueued_jobs) || []) + (adapter.try(:performed_jobs) || [])
      jobs.any? do |job|
        job["job_id"] == active_job_id &&
          job["job_class"] == "AgentSessionJob" &&
          monitor_only_arguments?(job["arguments"])
      end
    end
  end
end
