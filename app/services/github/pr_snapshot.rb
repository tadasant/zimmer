# frozen_string_literal: true

module Github
  # One reading of one pull request object, taken with a single `gh pr view`.
  #
  # This is the call that used to be two. `GitHubPullRequestPollerJob` asked for
  # `state,mergedAt` every 30 seconds and `GitHubMergeConflictPollerJob` asked the REST
  # endpoint for `.mergeable` every two minutes — two round trips to the same resource,
  # from two processes, to answer two questions about it. `Github::PrPollPass` takes one
  # reading per PR per pass and hands it to both evaluators.
  #
  # WHAT IS NOT ASKED FOR
  # ---------------------
  # `mergeStateStatus` would be the richer conflict signal (`DIRTY` is unambiguous), but
  # GitHub only serves it to a viewer with push access to the repository, and `gh` fails
  # the WHOLE query when one requested field is refused. Adding it would trade a better
  # conflict reading for the chance of losing PR status entirely on any repo the token
  # can read but not push to — and PR status is the fleet's archive signal. `mergeable`
  # answers the conflict question on its own.
  class PrSnapshot
    # The fields the evaluators between them need. Kept as one string because that
    # is the shape `gh --json` takes.
    #
    # `body` and `labels` are for Github::GoalFactsEvaluator — what a PR goal asks the
    # description and the labels to carry. Both are readable by any viewer who can
    # read the PR at all, so neither can be the one refused field that fails the
    # whole query (see WHAT IS NOT ASKED FOR above).
    #
    # `headRefOid` is for Github::MergeConflictEvaluator, which records the head it
    # notified about so a push re-arms the notice. Readable by any viewer too.
    JSON_FIELDS = "state,mergedAt,mergeable,body,labels,headRefOid"

    # Wall-clock bound on the `gh` child, process group killed on deadline. See
    # GithubCli: a timeout arrives as a failed Result, and this class turns that into
    # nil, which every caller already reads as "no reading this tick".
    #
    # Deliberately generous, and unchanged from the bound the PR poller applied to the
    # same call: the failure being bounded is a hang, not slowness, and a bound tight
    # enough to fire on a merely-degraded API would trade a rare wedge for a spurious
    # failure on every tick. `gh pr view` is one round trip.
    TIMEOUT = 20

    # GraphQL's MergeableState, which is NOT the REST `mergeable` boolean the merge
    # conflict poller used to read. REST answered "true"/"false"/"null"; this answers
    # MERGEABLE/CONFLICTING/UNKNOWN, and UNKNOWN carries REST null's meaning — GitHub
    # has not finished computing mergeability, so there is no reading yet.
    MERGEABLE_CLEAN = "MERGEABLE"
    MERGEABLE_CONFLICTING = "CONFLICTING"
    MERGEABLE_UNKNOWN = "UNKNOWN"

    attr_reader :ref, :state, :merged_at, :mergeable, :body, :labels, :head_sha

    # Take a reading of one PR.
    #
    # @param ref [Github::PrRef]
    # @return [PrSnapshot, nil] nil when the call did not complete or its output could
    #   not be parsed. Anything short of a demonstrable exit 0 — a non-zero exit, a lost
    #   exit code, a timeout — means we did not learn this PR's state. nil says exactly
    #   that; it must never be read as "the PR is gone". See GithubCli.
    def self.fetch(ref)
      command = [ "gh", "pr", "view", ref.number.to_s, "--repo", ref.slug, "--json", JSON_FIELDS ]

      result = GithubCli.run(command, timeout: TIMEOUT)

      unless result.success?
        Rails.logger.warn "[Github::PrSnapshot] gh pr view failed for #{ref}: #{result.failure_description}"
        return nil
      end

      data = JSON.parse(result.stdout)
      new(
        ref: ref,
        state: data["state"],
        merged_at: data["mergedAt"],
        mergeable: data["mergeable"],
        body: data["body"],
        labels: Array(data["labels"]).filter_map { |label| label["name"] if label.is_a?(Hash) },
        head_sha: data["headRefOid"].presence
      )
    rescue JSON::ParserError => e
      Rails.logger.error "[Github::PrSnapshot] Failed to parse gh pr view output for #{ref}: #{e.message}"
      nil
    end

    # This snapshot with its mergeability re-read from the REST pulls endpoint, for
    # the one question that has to trust it: does this open PR conflict?
    #
    # REST is the reading the merge-conflict poller this pass replaced trusted, with
    # a comment saying GraphQL's `mergeable` was the less reliable of the two for
    # conflict detection; fusing the pollers (#711) dropped it. A REST read of a PR
    # whose mergeability is stale is also documented to start GitHub's background
    # recomputation, answering `null` until it lands.
    #
    # The case that put it back: tadasant/zimmer#1284 conflicted with `main` on
    # 2026-10-15 after its stack parent squash-merged, and through hours of polling,
    # three of them with session 24237 idle in `needs_input` where a confirmed
    # conflict is delivered at once, the evaluator never confirmed it. A human typed
    # "Merge conflicts". Which reading GraphQL gave in that window is not on record,
    # so this restores the reading that was known to work rather than claiming a
    # diagnosis. MergeConflictEvaluator#notified_for_head? closes the other way that
    # session could have gone unnotified.
    #
    # Asked only on a merge-conflict-gated evaluation and only for open PRs, so it
    # costs one REST call per open PR every two minutes at most, which is less than
    # the old poller spent. A failed call keeps the GraphQL value: an answer we have
    # is better than none.
    #
    # @return [PrSnapshot] self when the PR is not open or REST could not be read,
    #   a copy carrying REST's answer otherwise
    def with_rest_mergeability
      return self unless status == "open"

      rest_mergeable, rest_head_sha = self.class.fetch_rest_mergeable(ref)
      return self if rest_mergeable.nil?

      # The head comes from the same REST reading, so a push between the two calls
      # cannot pair one commit's mergeability with another commit's sha.
      self.class.new(
        ref: ref, state: state, merged_at: merged_at, mergeable: rest_mergeable, body: body, labels: labels,
        head_sha: rest_head_sha.presence || head_sha
      )
    end

    # REST's `mergeable` for one PR, in GraphQL's vocabulary, and the head commit it
    # was read on — or nil when the call did not complete.
    #
    # @param ref [Github::PrRef]
    # @return [Array(String, String), nil] [MERGEABLE_CLEAN, MERGEABLE_CONFLICTING or
    #   MERGEABLE_UNKNOWN, head sha or nil]
    def self.fetch_rest_mergeable(ref)
      # The only call here that puts the url's parts into an API path rather than
      # passing them as arguments, so it refuses anything that could walk out of it.
      unless ref.number.to_s.match?(/\A\d+\z/) && ref.slug.match?(%r{\A[\w.-]+/[\w.-]+\z}) && !ref.slug.include?("..")
        Rails.logger.warn "[Github::PrSnapshot] Refusing a REST mergeability read for #{ref}"
        return nil
      end

      command = [ "gh", "api", "repos/#{ref.slug}/pulls/#{ref.number}", "--jq", REST_JQ ]
      result = GithubCli.run(command, timeout: TIMEOUT)

      unless result.success?
        Rails.logger.warn "[Github::PrSnapshot] REST mergeability read failed for #{ref}: #{result.failure_description}"
        return nil
      end

      raw_mergeable, raw_sha = result.stdout.to_s.split
      mergeable =
        case raw_mergeable
        when "true" then MERGEABLE_CLEAN
        when "false" then MERGEABLE_CONFLICTING
        when "null", nil then MERGEABLE_UNKNOWN
        end
      return nil if mergeable.nil?

      [ mergeable, raw_sha&.match?(/\A\h{40}\z/) ? raw_sha : nil ]
    end

    # "<mergeable> <head sha>" on one line: `true`/`false`/`null`, then the sha.
    REST_JQ = '"\(.mergeable) \(.head.sha)"'


    # `body` and `labels` default to "not read" so a reading built by hand for a
    # caller that only asks about lifecycle or conflicts need not invent them.
    def initialize(ref:, state:, merged_at:, mergeable:, body: nil, labels: [], head_sha: nil)
      @ref = ref
      @state = state
      @merged_at = merged_at
      @mergeable = mergeable
      @body = body
      @labels = labels
      @head_sha = head_sha
    end

    # The two #status values a PR never comes back from. Named here because this class
    # owns the vocabulary, and read by everything that has to ask "is this PR over":
    # Github::CommentEvaluator, which stops polling its comments, and
    # GithubPullRequestMergeability, which reads it as a positive reason a queued
    # conflict notice is moot.
    TERMINAL_STATUSES = %w[merged closed].freeze

    # The PR's lifecycle status in Zimmer's vocabulary — "open", "merged", "closed" — or
    # nil when GitHub answered with a state this does not recognise.
    #
    # `mergedAt` is a timestamp string when merged and null otherwise, and it wins over
    # `state`: a merged PR reports state MERGED, which neither branch below would catch.
    def status
      return "merged" if merged_at.present?

      case state&.downcase
      when "open" then "open"
      when "closed" then "closed"
      end
    end

    # Whether this PR has merge conflicts.
    #
    # @return [Boolean, nil] true when conflicting, false when clean, nil when GitHub
    #   has not computed mergeability yet (UNKNOWN) or answered with something else.
    #   nil is never "conflicting": the merge conflict evaluator leaves its markers
    #   alone on nil and asks again on its next gate.
    def conflicting?
      case mergeable
      when MERGEABLE_CONFLICTING then true
      when MERGEABLE_CLEAN then false
      when MERGEABLE_UNKNOWN, nil then nil
      else
        Rails.logger.warn "[Github::PrSnapshot] Unexpected mergeable value '#{mergeable}' for #{ref}"
        nil
      end
    end
  end
end
