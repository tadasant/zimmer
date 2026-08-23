# frozen_string_literal: true

# The rollout switch for issue #618's credential-ownership rearchitecture: run
# each Claude Code session under its own CLAUDE_CONFIG_DIR with an access token
# handed in via CLAUDE_CODE_OAUTH_TOKEN, so the DB is the sole owner of the
# subscription refresh chain.
#
# Ships OFF. The off path is the existing shared-file behaviour, unchanged, which
# is what makes flipping this back the rollback.
class AddSessionScopedCredentialsEnabledToAppSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :app_settings, :session_scoped_credentials_enabled, :boolean, default: false, null: false
  end
end
