# frozen_string_literal: true

# What Zimmer can say about whether a session's goal has been met, read off state it
# already records.
#
# A goal is prompt text: AgentSessionJob#build_prompt_with_goal appends it and the
# agent is asked to obey it. This is the other half — the parts of that text a
# machine can read back. Each catalog goal lists its `checks` in config/goals.json,
# and each check is a criterion below, evaluated against:
#
# - `github_pull_request_urls` — the PRs GithubPrUrlHook saw the session open
# - `github_pull_request_statuses` / `_ci_statuses` — Github::PrStatusEvaluator
# - `github_pull_request_goal_facts` — Github::GoalFactsEvaluator: the Verification
#   heading, the checkbox counts and the labels, read off the `gh pr view` the poll
#   pass already makes
#
# ADVISORY, DELIBERATELY
# ----------------------
# The result is reported — on the session page, in `get_session`, in the REST
# session JSON — and nothing acts on it. It does not fail a session, block an
# archive, or re-prompt. A wrong enforcement is worse than the gap it closes: a
# check that misreads a PR (a template's commented-out checkbox, a repo with no CI,
# a label renamed) would trap a finished session or refuse to let it end, and the
# person who notices would be the one whose work stalled. Reporting first is also
# how the check earns trust — its false-positive rate can be read off real sessions
# before anything is allowed to depend on it (tadasant/zimmer#88).
#
# Computed on read, not stored: a pure function of the session's recorded state, so
# it can never disagree with the PR badge in the header, and there is no second copy to
# go stale. The poll pass is what keeps the inputs fresh.
class GoalCheck
  # Criterion key => the label a reader sees. The keys are what config/goals.json
  # names; GoalsConfig refuses to load a goal that names one not listed here.
  CRITERIA = {
    "no_pull_request" => "No pull request opened",
    "pull_request_open" => "A pull request is open or merged",
    "ci_green" => "CI is green",
    "verification_section" => "PR description has a Verification section",
    "verification_boxes_checked" => "Verification boxes checked, none left unchecked",
    "ready_to_merge_label" => "Label \"ready to merge\" applied"
  }.freeze

  # The criteria that need the PR description and labels. A session whose goal
  # names none of them has nothing for Github::GoalFactsEvaluator to record.
  PULL_REQUEST_FACT_CRITERIA = %w[verification_section verification_boxes_checked ready_to_merge_label].freeze

  READY_TO_MERGE_LABEL = "ready to merge"

  # Per-criterion statuses:
  #   met     — the recorded state satisfies it
  #   unmet   — the recorded state contradicts it
  #   pending — it is waiting on something that resolves by itself (CI running, a
  #             PR recorded but not read from GitHub yet)
  #   unknown — Zimmer has no reading that could decide it
  STATUSES = %w[met unmet pending unknown].freeze

  # What the check cannot see, said wherever the result is shown so a `met` is
  # never read as more than it is.
  NOT_CHECKED_NOTE = "Advisory only: nothing acts on this. It covers only what Zimmer records and " \
                     "reads from GitHub. Anything else the goal asks for, such as a review, a skill, " \
                     "or a screenshot, is still the agent's word."

  Criterion = Data.define(:key, :label, :status, :detail) do
    def to_h
      { key: key, label: label, status: status, detail: detail }
    end
  end

  # verdict — "met" when every criterion is met, "unmet" when any is, "pending"
  #   otherwise (nothing contradicts the goal, but not everything is known yet)
  # provisional — the session is still running, so an unmet criterion is work in
  #   progress rather than a claim of completion
  # observed_at — when the poll pass last read this session's PRs, or nil
  Result = Data.define(:goal_id, :goal_name, :verdict, :criteria, :observed_at, :provisional) do
    def met_count
      criteria.count { |c| c.status == "met" }
    end

    def to_h
      {
        goal_id: goal_id,
        goal_name: goal_name,
        verdict: verdict,
        provisional: provisional,
        observed_at: observed_at&.iso8601,
        criteria: criteria.map(&:to_h),
        note: NOT_CHECKED_NOTE
      }
    end
  end

  class << self
    # @param session [Session]
    # @return [Result, nil] nil when the goal is free text, or a catalog goal that
    #   declares no checks — there is nothing to report, which is not "met"
    def for(session)
      goal = GoalsConfig.resolve(session.goal)
      return nil if goal.nil? || goal.checks.empty?

      new(session, goal).result
    end

    # Whether the poll pass should record PR description facts for this session.
    def reads_pull_request_facts?(session)
      goal = GoalsConfig.resolve(session.goal)
      goal.present? && goal.checks.intersect?(PULL_REQUEST_FACT_CRITERIA)
    end
  end

  def initialize(session, goal)
    @session = session
    @goal = goal
    metadata = session.custom_metadata || {}
    @refs = Github::PrRef.for_session(session)
    @statuses = hash_at(metadata, "github_pull_request_statuses")
    @ci_statuses = hash_at(metadata, "github_pull_request_ci_statuses")
    @facts = hash_at(metadata, Github::GoalFactsEvaluator::METADATA_KEY)
    @polled_at = hash_at(metadata, "poller_last_polled_at")[Github::PrPollPass::POLL_BACKOFF_KEY]
  end

  def result
    criteria = @goal.checks.map { |key| evaluate(key) }

    Result.new(
      goal_id: @goal.id,
      goal_name: @goal.name,
      verdict: verdict_for(criteria),
      criteria: criteria,
      observed_at: parse_time(@polled_at),
      provisional: @session.running?
    )
  end

  private

  def verdict_for(criteria)
    statuses = criteria.map(&:status)
    return "unmet" if statuses.include?("unmet")
    return "met" if statuses.all?("met")

    "pending"
  end

  def evaluate(key)
    status, detail = send(:"check_#{key}")
    Criterion.new(key: key, label: CRITERIA.fetch(key), status: status, detail: detail)
  end

  # --- criteria ----------------------------------------------------------------

  def check_no_pull_request
    return [ "met", nil ] if @refs.empty?

    [ "unmet", "Opened #{@refs.map(&:to_s).join(', ')}" ]
  end

  def check_pull_request_open
    return [ "unmet", "No pull request is recorded for this session" ] if @refs.empty?
    return [ "met", subjects.map { |ref| "#{ref} #{@statuses[ref.url]}" }.join(", ") ] if subjects.any?
    return [ "pending", "Recorded, not read from GitHub yet" ] if live_refs.any?

    [ "unmet", "Every recorded pull request was closed without merging" ]
  end

  def check_ci_green
    per_subject do |ref|
      next [ "met", nil ] if merged?(ref)

      case @ci_statuses[ref.url]
      when "pass" then [ "met", nil ]
      when "fail" then [ "unmet", "failing" ]
      when "cancel" then [ "unmet", "cancelled" ]
      when "pending" then [ "pending", "running" ]
      when "skipping" then [ "unknown", "every check skipped" ]
      else [ "unknown", "no CI reading (no checks configured, or not read yet)" ]
      end
    end
  end

  def check_verification_section
    per_subject do |ref|
      facts = @facts[ref.url]
      next [ "unknown", "description not read yet" ] unless facts.is_a?(Hash)

      facts["verification_section"] ? [ "met", nil ] : [ "unmet", "no Verification heading" ]
    end
  end

  def check_verification_boxes_checked
    per_subject do |ref|
      facts = @facts[ref.url]
      next [ "unknown", "description not read yet" ] unless facts.is_a?(Hash)

      unchecked = facts["unchecked_boxes"].to_i
      if unchecked.positive?
        [ "unmet", "#{unchecked} unchecked #{unchecked == 1 ? 'box' : 'boxes'}" ]
      elsif facts["verification_checked_boxes"].to_i.zero?
        [ "unmet", "no checked box under Verification" ]
      else
        [ "met", nil ]
      end
    end
  end

  def check_ready_to_merge_label
    per_subject do |ref|
      next [ "met", nil ] if merged?(ref)

      facts = @facts[ref.url]
      next [ "unknown", "labels not read yet" ] unless facts.is_a?(Hash)

      labels = Array(facts["labels"])
      if labels.any? { |label| label.to_s.casecmp?(READY_TO_MERGE_LABEL) }
        [ "met", nil ]
      else
        [ "unmet", "label not applied" ]
      end
    end
  end

  # --- helpers -----------------------------------------------------------------

  # Recorded PRs that have not been closed without merging. A closed PR is work
  # the session abandoned or replaced, so it neither satisfies a PR goal nor
  # counts against one.
  def live_refs
    @live_refs ||= @refs.reject { |ref| @statuses[ref.url] == "closed" }
  end

  # Live PRs GitHub has actually been read for. These are what the per-PR
  # criteria judge; every one of them has to pass.
  def subjects
    @subjects ||= live_refs.select { |ref| %w[open merged].include?(@statuses[ref.url]) }
  end

  def merged?(ref)
    @statuses[ref.url] == "merged"
  end

  # Evaluate a per-PR criterion across every subject PR and fold the answers:
  # one unmet PR makes the criterion unmet, and so on down STATUSES' severity.
  def per_subject
    return [ "unknown", "No pull request to read" ] if subjects.empty?

    answers = subjects.map { |ref| [ ref, *yield(ref) ] }
    status = %w[unmet pending unknown met].find { |s| answers.any? { |_, answer, _| answer == s } }

    notes = answers.filter_map do |ref, answer, note|
      next if answer == "met" || note.blank?

      subjects.size > 1 ? "#{ref}: #{note}" : note
    end

    [ status, notes.join("; ").presence ]
  end

  def hash_at(metadata, key)
    value = metadata[key]
    value.is_a?(Hash) ? value : {}
  end

  def parse_time(value)
    Time.zone.parse(value.to_s) if value.present?
  rescue ArgumentError
    nil
  end
end
