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
    # The fields the two evaluators between them need. Kept as one string because that
    # is the shape `gh --json` takes.
    JSON_FIELDS = "state,mergedAt,mergeable"

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

    attr_reader :ref, :state, :merged_at, :mergeable

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
      new(ref: ref, state: data["state"], merged_at: data["mergedAt"], mergeable: data["mergeable"])
    rescue JSON::ParserError => e
      Rails.logger.error "[Github::PrSnapshot] Failed to parse gh pr view output for #{ref}: #{e.message}"
      nil
    end

    def initialize(ref:, state:, merged_at:, mergeable:)
      @ref = ref
      @state = state
      @merged_at = merged_at
      @mergeable = mergeable
    end

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
