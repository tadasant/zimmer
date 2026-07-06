class RenameClaudeCliStartedMetadataKey < ActiveRecord::Migration[8.0]
  # The metadata flag that gates --resume vs --session-id on the next spawn is no
  # longer Claude-specific: it tracks whether the runtime CLI has been started for
  # this session at all. Rename the key in place so in-flight sessions (which may
  # have the old key set mid-execution) keep behaving identically across the
  # deploy. New code writes/reads "runtime_started" exclusively.
  #
  # NOTE: sessions.metadata is a `json` (not `jsonb`) column, so the key/merge
  # operators (`?`, `-`, `||`) are applied to a `::jsonb` cast and the result is
  # cast back to `::json` for storage.
  def up
    execute <<~SQL
      UPDATE sessions
      SET metadata = (
        (metadata::jsonb - 'claude_cli_started')
        || jsonb_build_object('runtime_started', metadata::jsonb -> 'claude_cli_started')
      )::json
      WHERE metadata::jsonb ? 'claude_cli_started'
    SQL
  end

  def down
    execute <<~SQL
      UPDATE sessions
      SET metadata = (
        (metadata::jsonb - 'runtime_started')
        || jsonb_build_object('claude_cli_started', metadata::jsonb -> 'runtime_started')
      )::json
      WHERE metadata::jsonb ? 'runtime_started'
    SQL
  end
end
