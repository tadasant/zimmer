# frozen_string_literal: true

# Shared setup for the Zimmer plugin (ExternalApp) tests: a plugin allowlisted to
# some triggers, holding one minted key.
module ExternalAppTestHelpers
  # @return [Array(ExternalApp, String)] the app and its key's secret
  def create_plugin_with_key(name: "Housing search", triggers: [], enabled: true)
    app = ExternalApp.create!(name: name, description: "Kicks off vetting", enabled: enabled)
    app.replace_triggers!(triggers.map(&:id))
    _api_key, token = app.mint_key!
    [ app, token ]
  end

  # What a fire needs to create a session without starting an agent. The
  # triggers' `zimmer` root resolves from the test catalog.
  # The calling test file requires mocha/minitest.
  def stub_trigger_session_creation
    AgentSessionJob.stubs(:enqueue_new_session)
    AgentSessionJob.stubs(:enqueue_with_prompt)
  end
end
