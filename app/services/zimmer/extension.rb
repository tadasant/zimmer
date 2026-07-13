# frozen_string_literal: true

module Zimmer
  # Base class for a **Zimmer Extension** — a self-contained, individually-deletable
  # bundle of optional behavior that plugs into Zimmer's core seams without the core
  # ever naming it.
  #
  # This is deliberately distinct from an AIR "session plugin" (PluginsConfig):
  # a session plugin injects skills / MCP servers / hooks INTO an agent session's
  # workspace. A Zimmer Extension, by contrast, alters how Zimmer itself drives a
  # runtime — which CLI adapter it spawns, which print-inference backend it uses,
  # what env it hands the child process. The word "plugin" is reserved for the
  # AIR concept; this layer is "extensions".
  #
  # == Why this exists ==
  #
  # Zimmer is being extracted from the monorepo as standalone OSS. Some features
  # (the PTY transport, in particular) depend on internal-only techniques we do
  # not want to publish. An extension is the seam that lets such a feature live
  # entirely under app/extensions/<id>/ and be removed wholesale for the OSS
  # build — delete the directory and everything still works, falling back to the
  # native path. The core resolves extensions through Zimmer::ExtensionRegistry and
  # never references a concrete extension class, so a missing extension is not an
  # error: its hooks simply do not contribute.
  #
  # == The contract ==
  #
  # A concrete extension subclasses this and, at minimum, overrides #id. It may
  # override any of the hook methods to contribute behavior; the defaults are all
  # inert (nil / no-op), so an extension only pays for the seams it uses.
  #
  #   class PtyTransportExtension < Zimmer::Extension
  #     def id = "pty_transport"
  #     def title = "PTY headless inference"
  #     def cli_adapter_override(runtime) = runtime == "claude_code" ? PtyClaudeCliAdapter : nil
  #     ...
  #   end
  #
  # Enablement is persisted per-id in AppSetting#extension_states (a JSONB map),
  # so adding an extension requires no migration — the load-bearing property for
  # a drop-in OSS extension.
  class Extension
    # The registry API this extension targets. Bump when the hook contract below
    # changes in a backwards-incompatible way; the registry warns when an
    # extension declares a version it does not understand.
    API_VERSION = 1

    # ---- Identity / metadata -------------------------------------------------

    # Stable string id. Used as the enablement key in AppSetting#extension_states
    # and as the registry lookup key. MUST be unique and stable across releases.
    def id
      raise NotImplementedError, "#{self.class} must define #id"
    end

    # Human-facing label for the settings UI.
    def title
      id.to_s.humanize
    end

    # One-line description for the settings UI.
    def description
      ""
    end

    # Whether this extension is experimental — surfaced under the settings
    # "Experimental" section and off by default. Extensions are experimental
    # unless they opt out.
    def experimental?
      true
    end

    # Whether the extension is on when the settings row has no explicit state for
    # it. Defaults off, so an experiment never activates itself on first boot.
    def default_enabled?
      false
    end

    # The API version this extension was written against.
    def api_version
      self.class::API_VERSION
    end

    # Whether the extension is currently enabled, per the persisted settings row
    # (falling back to #default_enabled? when unset or unreadable).
    def enabled?
      AppSetting.extension_enabled?(id, default: default_enabled?)
    end

    # ---- Hooks (override to contribute; defaults are inert) -------------------

    # Return a CLI adapter *class* to use in place of the runtime's default
    # adapter for the given runtime, or nil to defer. Only consulted for enabled
    # extensions (see RuntimeRegistry.cli_adapter_class_for).
    #
    # @param runtime [String] the session's agent_runtime (e.g. "claude_code")
    # @return [Class, nil]
    def cli_adapter_override(runtime)
      nil
    end

    # Whether this extension provides a print-mode inference backend. A cheap
    # predicate the print seam can consult without constructing a backend.
    def provides_print_runner?
      false
    end

    # Return an instantiated print-mode inference runner (responding to
    # #run(prompt:, timeout:) -> ClaudePrintRunner::Result), or nil to defer.
    # Receives the same construction kwargs ClaudePrintRunner.build would pass a
    # backend; unknown kwargs should be ignored.
    #
    # @return [#run, nil]
    def print_runner_backend(claude_binary:, model:, process_manager:, logger:)
      nil
    end

    # Return a hash of environment variables to merge into a spawned child's env.
    # Merged over Zimmer's baseline env (so an extension can override a baseline
    # default). Keys/values are stringified by the registry.
    #
    # @param context [Hash] spawn context (e.g. { runtime: "claude_code" })
    # @return [Hash]
    def spawn_env_contribution(context = {})
      {}
    end
  end
end
