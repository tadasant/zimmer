# frozen_string_literal: true

# PiAuthProvider — the RuntimeAuthProvider for the Pi coding agent.
#
# == Pi pools no accounts, and this class exists to say so ==
#
# ClaudeAuthProvider and CodexAuthProvider both manage a rotation pool: rows in
# `claude_accounts`, one marked current, credentials written to a host-global
# file, and rotation when one hits a quota wall. Pi is not authenticated that
# way. It resolves a provider credential per request, and the credential Zimmer
# supplies is an ordinary provider API key that reaches the process through the
# session's `.env` and SecretsLoader, the same path every other environment
# secret takes. There is no Zimmer-managed Pi identity, nothing to mark current,
# and nothing to rotate to.
#
# The key is `OPENROUTER_API_KEY`: every Pi model ModelCatalog offers is an
# `openrouter/*` id, so one key covers the whole list rather than one per vendor.
# `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` still drive the direct ids kept in that
# catalog, and nothing here stops them — they are simply not what this
# deployment supplies. The Inference page's Pi tab is where the key is set
# (ManagedSecret); this class still pools nothing, because a key is not an
# account.
#
# So every pooling method here is a deliberate, documented no-op rather than an
# unimplemented stub. `#accounts` returns the (always empty) `pi`-scoped relation
# rather than nil, because callers chain `.available.exists?` onto it and an
# AR relation is what makes that answer "no" instead of raising.
#
# == Why this class must exist at all ==
#
# `RuntimeAuthProvider.for` RAISES for an unregistered runtime, and several
# runtime-agnostic call sites pass `session.agent_runtime` straight into it —
# SessionStatusSummaryGenerator, ProcessLifecycleManager, AuthOutageParkService,
# QuotaAvailabilityMonitor. Registering Pi in RuntimeRegistry without also
# registering an auth provider would turn each of those into an ArgumentError on
# the first Pi session. A no-op provider is the honest answer; omitting one is a
# crash.
#
# Pi is deliberately NOT added to `RuntimeAuthProvider::RUNTIMES`. That constant
# drives the token-refresh dispatcher and the auth warm-up fan-out, and a runtime
# with no tokens to refresh has no business in either sweep.
#
# == The consequence worth knowing ==
#
# `SessionStatusSummaryGenerator#pool_exhausted?` reads
# `accounts.available.none?`, which is true here. So a Pi session's status
# summary is generated through the cheaper headless path rather than by forking
# the session. That is the correct outcome by accident and by argument: the fork
# would run on Pi and would need the same provider key the pool cannot vouch for.
# It is recorded in the limitations doc so it is a known property rather than a
# surprise.
class PiAuthProvider < RuntimeAuthProvider
  RUNTIME = "pi"

  def initialize(logger: Rails.logger)
    @logger = logger
  end

  def runtime
    RUNTIME
  end

  # Always empty: no ClaudeAccount row is ever created for the `pi` runtime (the
  # model's `RUNTIMES` inclusion validation would reject one). Returned as a
  # relation, not nil, so `.available.exists?` / `.available.none?` answer
  # rather than raise.
  def accounts
    ClaudeAccount.for_runtime(RUNTIME)
  end

  # No pooled identity — Pi authenticates per request from a provider API key in
  # the session environment.
  def current_account
    nil
  end

  def select_account_for(_session)
    nil
  end

  # Nothing to refresh. Reported as healthy rather than as a failure: a runtime
  # with no tokens is not a runtime whose tokens are broken.
  def refresh!(_account)
    Result.new(ok: true, error: nil)
  end

  # Nothing to inject. The provider key (OPENROUTER_API_KEY) reaches Pi through
  # the session `.env` that PiRuntimeAdapter loads at spawn, not through a
  # credentials file Zimmer writes — which is why setting it on the Pi tab is a
  # store write and not an account activation.
  def inject_for_session!(_session = nil, _working_directory = nil)
    nil
  end

  # Nothing to activate. Raising would be wrong — InferenceController only reaches
  # activate! for an account it found in this provider's pool, and this pool is
  # always empty, so this is unreachable in practice and returns the argument
  # unchanged rather than exploding if it ever is reached.
  def activate!(account)
    account
  end

  # No rotation schedule, because there is no pool to rotate. nil is what the
  # rotation scheduler reads as "never".
  def rotation_interval
    nil
  end
end
