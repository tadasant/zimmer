# frozen_string_literal: true

# Rewrites any `sessions.execution_provider = 'remote_sandbox'` row to
# `local_filesystem`.
#
# `remote_sandbox` was an accepted value on `Session::EXECUTION_PROVIDERS` and is not
# anymore, because the provider behind it never existed — every method on
# `Execution::Providers::RemoteSandbox` returns `Result.failure("not yet implemented")`.
# Dropping it from the enum without touching stored rows would leave any row holding it
# failing `validates :execution_provider, inclusion:` on its next save, which on a
# Session means a state transition can no longer persist.
#
# Rewriting is not a guess about what those rows meant. `lib/execution/` is unwired from
# `app/` — `AgentSessionJob` spawns the process directly and never consults
# `execution_provider` — so a session carrying `remote_sandbox` ran on the local
# filesystem regardless. This records what happened rather than changing it.
#
# Expected to be a no-op: nothing in the product ever set the value, so it could only
# have been reached by an API or MCP caller who read the enum and picked it.
class NormalizeRemoteSandboxExecutionProvider < ActiveRecord::Migration[8.0]
  STUB_PROVIDER = "remote_sandbox"
  REAL_PROVIDER = "local_filesystem"

  def up
    normalized = execute(<<~SQL.squish).cmd_tuples
      UPDATE sessions
      SET execution_provider = #{connection.quote(REAL_PROVIDER)}
      WHERE execution_provider = #{connection.quote(STUB_PROVIDER)}
    SQL

    say "Rewrote #{normalized} session(s) from #{STUB_PROVIDER} to #{REAL_PROVIDER}"
  end

  # Irreversible by intent, not by omission. The rewritten rows are indistinguishable
  # from rows that always held `local_filesystem`, and restoring them would recreate
  # values the model no longer accepts.
  def down
    say "No-op: #{STUB_PROVIDER} is not a value the model accepts, so there is nothing to restore"
  end
end
