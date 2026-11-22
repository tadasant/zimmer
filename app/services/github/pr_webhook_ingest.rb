# frozen_string_literal: true

module Github
  # Drives the per-session PR pollers from GitHub's webhook instead of the clock.
  #
  # Github::PrPollPass used to learn every change to a tracked PR by asking GitHub: `gh pr view`
  # and `gh pr checks` (GraphQL) every 30 seconds per active session, two REST pages of comments
  # on the same cadence, and a REST mergeability read every two minutes. The comment pages are
  # the bulk of the REST budget: two calls per open PR per tick, for every session a human has
  # touched in the last half hour.
  #
  # Webhooks::GithubController hands every verified delivery to .record_delivery!, which turns it
  # into GithubPrSignal rows: "this PR's status / comments / mergeability may have changed". The
  # pass reads them through a Reading and runs an evaluator when a signal for it is newer than the
  # evaluator's last run, and otherwise only on a slow fallback cadence.
  #
  # MODES (GITHUB_PR_INGEST_MODE, read through Webhooks::Source.github_prs)
  # ---------------------------------------------------------------------
  #   poll                        the default. No signal is written and the pass polls exactly as
  #                               it always has.
  #   webhook_shadow              signals are written and the pass still polls on its old cadence.
  #                               Whenever a poll finds a change on a covered repository, it logs
  #                               whether a signal arrived for it first (`webhook_shadow hit` /
  #                               `miss`). It is the rehearsal before the next mode.
  #   webhook_with_poll_fallback  signals drive the evaluators. Polling continues as the backstop,
  #                               at FALLBACK_POLL_INTERVAL. A fallback poll that finds a change no
  #                               signal announced is logged as a miss.
  #
  # COVERAGE
  # --------
  # A session is driven by signals only when every repository it tracks a PR in is COVERED: the
  # webhook delivered something from it within COVERAGE_WINDOW. A repository with no hook
  # (`pulsemcp/air`) never delivers, so its sessions keep today's cadence. A hook that is deleted
  # or broken stops delivering, so its repository falls back to full polling once the window
  # passes. The mode switch is the operator's statement that the hooks subscribe to every event
  # in EVENT_KINDS; coverage is how Zimmer notices a hook that stopped.
  #
  # A delivery carries no authority here. A signal only makes an evaluator read GitHub sooner, so
  # a forged delivery can spend an extra read and cannot announce a merge, a green CI run or a
  # comment that did not happen.
  module PrWebhookIngest
    # The backstop cadence for a covered session's pass, comments and merge-conflict reading.
    FALLBACK_POLL_INTERVAL = 10.minutes.to_i

    # The orphaned-PR sweep's backstop for a covered session, in place of its 15 minutes.
    ORPHAN_FALLBACK_POLL_INTERVAL = 1.hour.to_i

    # How recently a repository must have delivered something to count as covered.
    COVERAGE_WINDOW = 6.hours

    # How long after a push before a merge-conflict signal is acted on. GitHub recomputes
    # mergeability in the background after a push, and a REST read straight after it answers
    # `null`. That reading is "not computed yet", so the evaluator does nothing with it, and the
    # next reading would be FALLBACK_POLL_INTERVAL later. Waiting a minute gets an answer.
    MERGE_CONFLICT_SETTLE = 60.seconds

    # The pull_request actions that can change what PrStatusEvaluator or GoalFactsEvaluator
    # records: the lifecycle, the labels, the description and the head (which CI keys on).
    STATUS_ACTIONS = %w[
      opened reopened closed synchronize edited labeled unlabeled ready_for_review converted_to_draft
    ].freeze

    # The pull_request actions after which mergeability is worth re-reading: a new head, a
    # reopened PR, or a base branch changed by an edit.
    MERGE_CONFLICT_ACTIONS = %w[synchronize reopened].freeze

    # Event => what it signals. The list the repository hooks must subscribe to for
    # `webhook_with_poll_fallback` to lose nothing; see docs/src/content/docs/sessions/github-prs.md.
    EVENT_KINDS = {
      "pull_request" => "status, and merge_conflict on synchronize, reopened or a base change",
      "issue_comment" => "comments, for a comment on a pull request",
      "pull_request_review" => "comments",
      "pull_request_review_comment" => "comments",
      "check_suite" => "status, for each pull request it names",
      "check_run" => "status, for each pull request it names",
      "status" => "ci, for every tracked pull request in the repository",
      "push" => "base_push, for a push to the default branch"
    }.freeze

    module_function

    def source
      Webhooks::Source.github_prs
    end

    # Whether deliveries should be turned into signals at all.
    def receiving?
      source.receiving?
    end

    # Whether signals drive the pass, rather than only being observed.
    def driving?
      source.webhook_enabled?
    end

    # Turn one verified delivery into signals.
    #
    # @param event [String] the X-GitHub-Event header
    # @param payload [Hash] the parsed body
    # @return [Array<Array(String, String)>] the [subject, kind] pairs signalled
    def record_delivery!(event, payload, at: Time.current)
      pairs = signals_for(event, payload)
      GithubPrSignal.signal!(pairs, at: at)
      pairs
    end

    # The [subject, kind] pairs one delivery signals. Pure: reads the payload's identifiers and
    # nothing else.
    def signals_for(event, payload)
      repository = payload["repository"]
      full_name = repository.is_a?(Hash) ? repository["full_name"].to_s : ""
      owner, repo = full_name.split("/", 2)
      return [] if owner.blank? || repo.blank? || repo.include?("/")

      repo_subject = GithubPrSignal.repo_subject(owner, repo)
      pr = ->(number, kind) { [ GithubPrSignal.pr_subject(owner, repo, number), kind ] if number.to_s.match?(/\A\d+\z/) }
      action = payload["action"].to_s

      pairs = [ [ repo_subject, GithubPrSignal::DELIVERY ] ]
      pairs.concat(
        case event
        when "pull_request" then pull_request_signals(payload, action, pr)
        when "issue_comment"
          issue = payload["issue"]
          issue.is_a?(Hash) && issue["pull_request"].present? && action == "created" ? [ pr.(issue["number"], GithubPrSignal::COMMENTS) ] : []
        when "pull_request_review", "pull_request_review_comment"
          [ pr.(payload.dig("pull_request", "number"), GithubPrSignal::COMMENTS) ]
        when "check_suite", "check_run"
          Array(payload.dig(event, "pull_requests")).filter_map do |linked|
            pr.(linked["number"], GithubPrSignal::STATUS) if linked.is_a?(Hash)
          end
        when "status"
          [ [ repo_subject, GithubPrSignal::CI ] ]
        when "push"
          default_branch = repository["default_branch"].to_s
          default_branch.present? && payload["ref"] == "refs/heads/#{default_branch}" ? [ [ repo_subject, GithubPrSignal::BASE_PUSH ] ] : []
        else
          []
        end
      )
      pairs.compact.uniq
    end

    def pull_request_signals(payload, action, pr)
      number = payload.dig("pull_request", "number")
      pairs = []
      pairs << pr.(number, GithubPrSignal::STATUS) if STATUS_ACTIONS.include?(action)
      base_changed = action == "edited" && payload.dig("changes", "base").present?
      pairs << pr.(number, GithubPrSignal::MERGE_CONFLICT) if MERGE_CONFLICT_ACTIONS.include?(action) || base_changed
      pairs
    end

    # What the webhook has said about one session's tracked PRs, read once per pass.
    class Reading
      # @param refs [Array<Github::PrRef>]
      # @return [Reading, nil] nil in `poll`, where nothing reads signals
      def self.for(refs, now: Time.current)
        return nil unless PrWebhookIngest.receiving?
        return nil if refs.empty?

        pr_subjects = refs.map { |ref| GithubPrSignal.pr_subject(ref.owner, ref.repo, ref.number) }
        repo_subjects = refs.map { |ref| GithubPrSignal.repo_subject(ref.owner, ref.repo) }.uniq
        new(refs, GithubPrSignal.latest_for(pr_subjects + repo_subjects), now: now, driving: PrWebhookIngest.driving?)
      end

      def initialize(refs, signals, now:, driving:)
        @refs = refs
        @signals = signals
        @now = now
        @driving = driving
      end

      # Whether every repository this session tracks a PR in has delivered within COVERAGE_WINDOW.
      def covered?
        @refs.all? do |ref|
          delivered = @signals[[ GithubPrSignal.repo_subject(ref.owner, ref.repo), GithubPrSignal::DELIVERY ]]
          delivered.present? && delivered >= @now - COVERAGE_WINDOW
        end
      end

      # Whether signals decide this session's cadence: the mode says so and every repository
      # is covered.
      def driving?
        @driving && covered?
      end

      # A status or CI signal for any of +refs+ (default: all) newer than +since+.
      def status_pending?(since, refs: @refs)
        refs.any? { |ref| newer?(signal(ref, GithubPrSignal::STATUS), since) || newer?(repo_signal(ref, GithubPrSignal::CI), since) }
      end

      def comments_pending?(since, refs: @refs)
        refs.any? { |ref| newer?(signal(ref, GithubPrSignal::COMMENTS), since) }
      end

      # A merge-conflict or base-push signal newer than +since+ that has had
      # MERGE_CONFLICT_SETTLE to settle. One still settling is not pending yet; it becomes
      # pending on a later tick.
      def merge_conflict_pending?(since)
        @refs.any? do |ref|
          [ signal(ref, GithubPrSignal::MERGE_CONFLICT), repo_signal(ref, GithubPrSignal::BASE_PUSH) ].any? do |at|
            newer?(at, since) && at <= @now - MERGE_CONFLICT_SETTLE
          end
        end
      end

      private

      def signal(ref, kind)
        @signals[[ GithubPrSignal.pr_subject(ref.owner, ref.repo, ref.number), kind ]]
      end

      def repo_signal(ref, kind)
        @signals[[ GithubPrSignal.repo_subject(ref.owner, ref.repo), kind ]]
      end

      def newer?(at, since)
        at.present? && (since.nil? || at > since)
      end
    end

    # Log, for each change a poll found on a covered session, whether the webhook announced it
    # first. In `webhook_shadow` this is the comparison that says the webhook is ready to drive;
    # in `webhook_with_poll_fallback` every miss is a change the fallback caught that the webhook
    # did not, which is the number to watch before lengthening the fallback.
    #
    # Two changes are compared: a recorded PR or CI status that moved (status / ci signals) and
    # a comment the evaluator had not stored before (comments signals). Mergeability is not:
    # a conflict usually appears because something ELSE was pushed, which no single signal for
    # this PR names.
    #
    # @param before [Hash] the session's custom_metadata before the pass's evaluators ran
    # @param after [Hash] the same, after
    # @param stamps [Hash{String => Time, nil}] the evaluators' previous stamps, by backoff key
    def observe(session, reading, refs, before:, after:, stamps:)
      return if reading.nil? || !reading.covered?

      mode = source.mode
      refs.each do |ref|
        if status_moved?(ref.url, before, after)
          log_observation(session, ref, "status", mode, reading.status_pending?(stamps[:status], refs: [ ref ]))
        end
        if before&.dig("github_comments", ref.url).is_a?(Hash) && comment_count(after, ref.url) > comment_count(before, ref.url)
          log_observation(session, ref, "comments", mode, reading.comments_pending?(stamps[:comments], refs: [ ref ]))
        end
      end
    end

    # A PR this pass read for the first time has no previous status, and its first reading is a
    # baseline rather than a change; the same goes for its first comment thread below.
    def status_moved?(url, before, after)
      return false if before&.dig("github_pull_request_statuses", url).nil?

      %w[github_pull_request_statuses github_pull_request_ci_statuses].any? do |key|
        before&.dig(key, url) != after&.dig(key, url)
      end
    end

    def comment_count(metadata, url)
      thread = metadata&.dig("github_comments", url)
      return 0 unless thread.is_a?(Hash)

      Array(thread["pr_comments"]).size + Array(thread["review_comments"]).size
    end

    def log_observation(session, ref, kind, mode, hit)
      Rails.logger.info "[Github::PrWebhookIngest] #{mode} #{hit ? 'hit' : 'miss'}: #{kind} change on #{ref} " \
                        "for session #{session.id} #{hit ? 'was' : 'was NOT'} signalled by the webhook first"
    end
  end
end
