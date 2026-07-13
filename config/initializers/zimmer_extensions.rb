# frozen_string_literal: true

# Register the built-in Zimmer Extensions (see app/services/zimmer/extension.rb) into
# Zimmer::ExtensionRegistry. Runs inside a to_prepare block so it re-runs on each dev
# reload (after Zeitwerk reloads the extension classes) and once at boot in
# production. register_builtins! resolves each extension by name via
# safe_constantize, so a removed extension directory is skipped cleanly.
Rails.application.config.to_prepare do
  Zimmer::ExtensionRegistry.reset!
  Zimmer::ExtensionRegistry.register_builtins!
end
