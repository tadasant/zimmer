# frozen_string_literal: true

# AuthWarmupService — settle each runtime's DB-current login identity at worker
# boot, before GoodJob starts consuming jobs.
#
# Zimmer maintains a pool of login accounts per runtime, and what "settling" one
# means differs by runtime:
#
#   * Codex writes the active account's credentials to ~/.codex/auth.json, and it
#     does so LAZILY — on the first session that runs on a worker container. On a
#     deploy or any worker recreation, the new container's overlay filesystem
#     starts without that file, so GoodJob can begin pulling AgentSessionJobs
#     before the first session has written it. Those early sessions then fail with
#     "Not logged in / Please run /login" until the lazy write happens.
#   * Claude Code writes nothing (issue #618). Every session is spawned with its
#     own CLAUDE_CONFIG_DIR and the current account's access token, so there is no
#     cold-start file gap — but there IS a cold-start POOL question, and it now
#     matters more rather than less: a spawn with no usable current account fails
#     outright instead of falling back to a file. Settling the pool on boot is
#     what makes sure it does not have to.
#
# The worker's boot command runs this (via the `auth:warm_boot` rake task) BEFORE
# `good_job start`. Each runtime's warm-up delegates to the same
# RuntimeAuthProvider#inject_for_session! the per-spawn path uses, so boot
# warm-up and steady state share one seam and one set of invariants.
#
# It is best-effort and resilient: a failure to warm one runtime (no account in
# the pool, a transient token-refresh error) is logged and does NOT block the
# worker from booting. The lazy per-session path remains the backstop — a runtime
# that fails to warm here simply falls back to the prior (gap-prone) behavior for
# that one runtime, rather than taking the whole worker down.
class AuthWarmupService
  # Outcome of warming a single runtime.
  #   runtime - the runtime identifier (e.g. "claude_code")
  #   account - the account written to disk, or nil when none was warmed
  #   error   - nil on success; :no_account when the pool was empty, or the raised
  #             exception when warming blew up
  Result = Data.define(:runtime, :account, :error) do
    def ok? = error.nil?
    def no_account? = error == :no_account
  end

  def initialize(logger: StructuredLogger.new({ service: "AuthWarmupService" }))
    @logger = logger
  end

  # Warm every registered runtime, writing its DB-current identity to disk.
  #
  # @return [Array<Result>] one Result per registered runtime, in registry order
  def warm_all
    RuntimeAuthProvider.registered.map { |provider| warm(provider) }
  end

  private

  # Warm a single runtime. Never raises — a failure is captured in the Result so
  # one runtime's problem can't abort the boot sequence for the others.
  def warm(provider)
    # Boot warm-up has no session/working-directory context; pass nil explicitly.
    # Neither runtime's implementation uses them.
    account = provider.inject_for_session!(nil, nil)

    if account
      @logger.info("Warmed runtime auth on boot", runtime: provider.runtime, email: account.email)
      Result.new(runtime: provider.runtime, account: account, error: nil)
    else
      # No available account to write. Logged at info, not warn: some
      # environments legitimately run a runtime with an empty pool (e.g. no
      # Codex accounts configured), and the lazy per-session path will surface a
      # real auth problem if a session for that runtime is ever spawned.
      @logger.info("No account available to warm runtime auth on boot", runtime: provider.runtime)
      Result.new(runtime: provider.runtime, account: nil, error: :no_account)
    end
  rescue => e
    # A failed warm-up degrades to the prior lazy-write behavior for this runtime
    # (the per-session path still runs inject_for_session! before each spawn), so
    # it self-resolves rather than requiring intervention — warn, not error.
    @logger.warn("Failed to warm runtime auth on boot", runtime: provider.runtime, error: e.message)
    Result.new(runtime: provider.runtime, account: nil, error: e)
  end
end
