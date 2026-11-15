# frozen_string_literal: true

# The one way Zimmer shells out to the `gh` CLI.
#
# Every `gh` invocation is a network call, and the failure that matters is not a
# non-zero exit — it is the call that never returns. During a GitHub REST incident
# a request can stall with the TCP connection half-open: no response, no reset. A
# bare `Open3.capture3` blocks the calling thread forever on that, and the PR poll
# pass (`GithubPrPollPassJob`, which fused the three GitHub pollers) is a
# `total_limit: 1` singleton, so one hung call holds the only slot and every
# subsequent tick is a no-op enqueue. Polling freezes with nothing raised and
# nothing alerted — and unlike `GithubTriggerPollerJob`, the pass has no heartbeat
# and no watchdog to notice (#458). Fusing the three pollers raised the stakes on
# that rather than lowering them: one hung call now stalls PR status, CI, merge
# conflicts and comments together.
#
# So this wrapper does three things:
#
#   1. Runs the command under `BoundedSubprocess`, which SIGKILLs the whole process
#      group on deadline. The caller passes the timeout, because the right bound is
#      a property of the call shape — a `gh pr view` is one cheap round trip, a
#      paginated `gh api` loop wants a per-page bound — not a global constant.
#   2. Hands back a Result rather than raising on timeout, so a hang arrives at the
#      call site as an ordinary failed call. Every one of these sites already has a
#      "the call failed" branch that logs and retries on the next tick; a timeout
#      belongs in that branch and nowhere else.
#
# That second point is the load-bearing one: **a timeout means "ask again next
# tick", never "the PR is gone".** A caller that mapped it onto a definite negative
# would turn a degraded API into a wrong answer about merge state, which is worse
# than the hang.
#
# The third is authentication. Zimmer can hold one GitHub token per repository
# owner (see GithubTokens), so each call runs with GH_TOKEN set to the token for
# the owner it acts on. The owner is read off the argv — `--repo owner/name`,
# `gh api repos/owner/…`, or a GraphQL `-F owner=…` — which covers every call
# site without each one having to name it; a caller with no repository in its
# argv (`gh api search/issues`) passes `owner:` itself. A call with no owner, or
# an owner with no token of its own, inherits the default GH_TOKEN.
#
# The fourth is the rate-limit breaker (GithubRateLimit). Before a call is sent, the
# wrapper asks whether its budget is spent or held in reserve. If it is, the call is answered
# locally with a failed Result whose `refusal` says why and until when, and GitHub never
# sees it. After a call fails, the wrapper hands GitHub's words to the breaker, so the first
# primary rate-limit refusal stops the next thousand. A refused Result is a failure like a
# timeout: no exit code, "ask again next tick", never a definite negative.
#
# Only the timeout is converted. `Errno::ENOENT` — no `gh` binary at all — still
# propagates, because that is a local, permanent condition callers distinguish
# (see `GithubSearchService#auth_preflight`) rather than a failed request.
module GithubCli
  # The outcome of one `gh` invocation: either the child ran to completion (with a
  # status that may itself be nil — see SubprocessStatus) or it hit its deadline.
  #
  # `#success?` is true only when the command demonstrably exited 0, so the three
  # ways a call can fail to produce a trustworthy answer — non-zero exit, lost exit
  # code, timeout — all reach the same branch.
  class Result
    attr_reader :stdout, :stderr, :status, :timeout_message, :refusal

    def initialize(stdout:, stderr:, status:, timeout_message: nil, refusal: nil)
      @stdout = stdout
      @stderr = stderr
      @status = status
      @timeout_message = timeout_message
      @refusal = refusal
    end

    # A call the rate-limit breaker answered without sending (see GithubRateLimit).
    def self.refused(refusal)
      new(stdout: "", stderr: refusal.message, status: nil, refusal: refusal)
    end

    # True when this call was never sent because its budget was spent or reserved.
    def refused?
      !@refusal.nil?
    end

    # True when the deadline was hit and the process group was killed.
    def timed_out?
      !@timeout_message.nil?
    end

    def success?
      return false if timed_out? || refused?

      SubprocessStatus.success?(status)
    end

    # Nil-safe exit code, and nil on timeout — so a caller comparing against a
    # specific code (`exit_code == 8` for "checks still pending") falls through to
    # its failure branch on a hang instead of reading a meaning into it.
    def exit_code
      return nil if timed_out? || refused?

      SubprocessStatus.exit_code(status)
    end

    # One line explaining why this call is being treated as failed, for a log line
    # or an exception message.
    #
    # The timeout form keeps the exception's own class name in front of the message
    # so the string a `BoundedSubprocess::TimeoutError` used to produce at these
    # sites is the string it still produces — log greps and alert rules that match
    # "TimeoutError" keep matching.
    def failure_description
      return "#{BoundedSubprocess::TimeoutError}: #{timeout_message}" if timed_out?
      return refusal.message if refused?

      SubprocessStatus.describe_failure(status, stderr)
    end
  end

  module_function

  # @param command [Array<String>] argv (no shell — pass args explicitly)
  # @param timeout [Numeric] wall-clock seconds before the process group is killed
  # @param owner [String, nil] the repository owner whose token to use; inferred
  #   from the argv when omitted
  # @param priority [Symbol] :poller lets the call spend the reserve GithubRateLimit
  #   keeps for the trigger poller; every other caller leaves it alone
  # @return [Result] never raises TimeoutError; a hang comes back as a failed Result
  def run(command, timeout:, owner: nil, priority: :normal)
    env = GithubTokens.env_for(owner || owner_for(command))

    refusal = GithubRateLimit.refusal_for(command, env: env, priority: priority)
    return Result.refused(refusal) if refusal

    stdout, stderr, status = if env.empty?
      BoundedSubprocess.run(command, timeout: timeout)
    else
      BoundedSubprocess.run(command, timeout: timeout, env: env)
    end
    result = Result.new(stdout: stdout, stderr: stderr, status: status)
    # Unconditional rather than `unless result.success?`: the breaker matches GitHub's
    # rate-limit sentence, which only a refused call prints, and the call site owns the
    # one read of the status it decides on.
    GithubRateLimit.observe_failure(command, stderr, env: env)
    result
  rescue BoundedSubprocess::TimeoutError => e
    Result.new(stdout: "", stderr: "", status: nil, timeout_message: e.message)
  end

  # The repository owner a `gh` argv acts on, or nil when it names none.
  #
  # @param command [Array<String>]
  # @return [String, nil]
  def owner_for(command)
    args = Array(command).map(&:to_s)

    args.each_with_index do |arg, index|
      slug = if [ "--repo", "-R" ].include?(arg)
        args[index + 1]
      elsif arg.start_with?("--repo=")
        arg.delete_prefix("--repo=")
      end
      return GithubTokens.owner_from_slug(slug.delete_prefix("github.com/")) if slug
    end

    if args[1] == "api"
      path = args.drop(2).find { |arg| arg.match?(%r{\A/?repos/}) }
      return GithubTokens.owner_from_slug(path.sub(%r{\A/?repos/}, "")) if path

      field = args.find { |arg| arg.start_with?("owner=") }
      return GithubTokens.owner_from_slug(field.delete_prefix("owner=")) if field
    end

    nil
  end
end
