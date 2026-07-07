# frozen_string_literal: true

# AuthWarmupService — write each runtime's DB-current login identity to disk at
# worker boot, before GoodJob starts consuming jobs.
#
# Zimmer maintains a pool of login accounts per runtime (Claude, Codex) and writes
# the active account's credentials to the runtime's canonical filesystem location
# (~/.claude.json + ~/.claude/.credentials.json for Claude, ~/.codex/auth.json for
# Codex) LAZILY — on the first session that runs on a worker container. On a
# deploy or any worker recreation, the new container's overlay filesystem starts
# without those identity files, so GoodJob can begin pulling AgentSessionJobs
# before the first session has written them. Those early sessions then fail with
# "Not logged in / Please run /login" until the lazy write happens.
#
# This service closes that cold-start gap. The worker's boot command runs it (via
# the `auth:warm_boot` rake task) BEFORE `good_job start`, so the DB-current
# identity is on disk for every runtime before any job is consumed. Each runtime's
# warm-up delegates to the same RuntimeAuthProvider#inject_for_session!
# reconciliation the per-spawn path uses, so boot warm-up and steady-state share
# one identity-write seam (and one set of invariants — owner marker, completeness
# guard).
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
    # inject_for_session! reconciles disk against the DB-current account regardless.
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
