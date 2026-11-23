# frozen_string_literal: true

module Github
  # Drives the per-session PR pollers from GitHub's webhook instead of the clock.
  #
  # Polled, Github::PrPollPass learns every change to a tracked PR by asking GitHub: `gh pr view`
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
  #   webhook_with_poll_fallback  signals drive the evaluators. Polling continues as the backstop,
  #                               at FALLBACK_POLL_INTERVAL.
  #
  # COVERAGE
  # --------
  # A session is driven by signals only when every repository it tracks a PR in is COVERED: the
  # webhook delivered something from it within COVERAGE_WINDOW. A repository with no hook
  # (`pulsemcp/air`) never delivers, so its sessions keep the polled cadence. A hook that is deleted
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

    # How long after a comment before a comments signal is acted on. CommentEvaluator defers a
    # comment younger than its attribution grace, and a deferred comment read early would then
    # wait for the fallback; reading it once the grace has passed settles it in one read.
    COMMENT_SETTLE = (CommentEvaluator::ATTRIBUTION_GRACE_SECONDS + 5).seconds

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
    # `webhook_with_poll_fallback` to lose nothing; see docs/src/content/docs/operate/background-jobs.md
    # ("Driven by GitHub's webhook instead of the clock").
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

    # Whether deliveries are turned into signals and signals drive the pass.
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
      # @param ci_statuses [Hash{String => String}] the session's recorded CI status per PR url.
      #   A repository-wide `ci` signal counts only for a PR whose CI is pending or unrecorded:
      #   a commit status on some other branch says nothing about a PR whose checks finished.
      # @return [Reading, nil] nil in `poll`, where nothing reads signals
      def self.for(refs, now: Time.current, ci_statuses: {})
        return nil unless PrWebhookIngest.driving?
        return nil if refs.empty?

        pr_subjects = refs.map { |ref| GithubPrSignal.pr_subject(ref.owner, ref.repo, ref.number) }
        repo_subjects = refs.map { |ref| GithubPrSignal.repo_subject(ref.owner, ref.repo) }.uniq
        new(refs, GithubPrSignal.latest_for(pr_subjects + repo_subjects), now: now,
            ci_statuses: ci_statuses.is_a?(Hash) ? ci_statuses : {})
      end

      def initialize(refs, signals, now:, ci_statuses: {})
        @ci_statuses = ci_statuses
        @refs = refs
        @signals = signals
        @now = now
      end

      # Whether every repository this session tracks a PR in has delivered within COVERAGE_WINDOW.
      def covered?
        @refs.all? do |ref|
          delivered = @signals[[ GithubPrSignal.repo_subject(ref.owner, ref.repo), GithubPrSignal::DELIVERY ]]
          delivered.present? && delivered >= @now - COVERAGE_WINDOW
        end
      end

      # Whether signals decide this session's cadence: every repository is covered. (A Reading
      # exists only in `webhook_with_poll_fallback`.)
      def driving?
        covered?
      end

      # A status or CI signal for any of +refs+ (default: all) newer than +since+.
      def status_pending?(since, refs: @refs)
        refs.any? do |ref|
          newer?(signal(ref, GithubPrSignal::STATUS), since) ||
            (ci_unsettled?(ref) && newer?(repo_signal(ref, GithubPrSignal::CI), since))
        end
      end

      # A comments signal newer than +since+. With +settled+, only one that has had
      # COMMENT_SETTLE: one still settling becomes pending on a later tick.
      def comments_pending?(since, refs: @refs, settled: true)
        refs.any? do |ref|
          at = signal(ref, GithubPrSignal::COMMENTS)
          newer?(at, since) && (!settled || at <= @now - COMMENT_SETTLE)
        end
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

      def ci_unsettled?(ref)
        [ nil, "pending" ].include?(@ci_statuses[ref.url])
      end

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
  end
end
