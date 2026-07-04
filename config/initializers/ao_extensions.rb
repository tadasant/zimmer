# frozen_string_literal: true

# Register the built-in AO Extensions (see app/services/ao/extension.rb) into
# Ao::ExtensionRegistry. Runs inside a to_prepare block so it re-runs on each dev
# reload (after Zeitwerk reloads the extension classes) and once at boot in
# production. register_builtins! resolves each extension by name via
# safe_constantize, so a removed extension directory is skipped cleanly.
Rails.application.config.to_prepare do
  Ao::ExtensionRegistry.reset!
  Ao::ExtensionRegistry.register_builtins!
end
