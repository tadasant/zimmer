# frozen_string_literal: true

module Zimmer
  # Registry of Zimmer Extensions (see Zimmer::Extension) and the single place the core
  # resolves extension-contributed behavior. Core seams ask the registry generic
  # questions ("does any enabled extension override the CLI adapter for this
  # runtime?") and never name a concrete extension — so an extension can be
  # deleted for the OSS build and the core keeps working, falling back to native.
  #
  # == Registration ==
  #
  # Built-in extensions are registered at boot (and on each dev reload) from
  # BUILTIN_EXTENSION_CLASSES via #register_builtins!, which looks each class up
  # by name with `safe_constantize`. A name that no longer resolves — because its
  # app/extensions/<id>/ directory was removed — is skipped silently. That skip
  # IS the removability mechanism: no core edit is needed to drop an extension.
  #
  # == Thread-safety ==
  #
  # Registration happens once during boot (a to_prepare block); reads happen
  # afterward on request threads. The store is a plain hash guarded by a mutex so
  # a dev-reload re-registration can't race an in-flight read.
  module ExtensionRegistry
    # Built-in extensions, by class name. Resolved via safe_constantize so a
    # removed extension directory is skipped rather than raising. Order is the
    # resolution order for first-wins hooks (cli_adapter_override, print backend).
    BUILTIN_EXTENSION_CLASSES = %w[
      McpToolSearchExtension
    ].freeze

    @mutex = Mutex.new
    @extensions = {}

    module_function

    # Drop all registrations. Called at the top of each to_prepare cycle.
    def reset!
      @mutex.synchronize { @extensions = {} }
    end

    # Register a single extension instance (last write wins per id).
    def register(extension)
      if extension.api_version != Zimmer::Extension::API_VERSION
        Rails.logger.warn(
          "[Zimmer::ExtensionRegistry] #{extension.class} declares api_version " \
          "#{extension.api_version}, registry is #{Zimmer::Extension::API_VERSION}; registering anyway"
        )
      end
      @mutex.synchronize { @extensions[extension.id.to_s] = extension }
      extension
    end

    # Register every built-in extension whose class still resolves. Missing
    # classes (deleted extension directories) are skipped — the OSS-removal path.
    def register_builtins!
      BUILTIN_EXTENSION_CLASSES.each do |class_name|
        klass = class_name.safe_constantize
        next unless klass

        register(klass.new)
      end
    end

    # All registered extensions.
    def all
      @mutex.synchronize { @extensions.values }
    end

    # Look up one extension by id, or nil.
    def find(id)
      @mutex.synchronize { @extensions[id.to_s] }
    end

    # Extensions flagged experimental (drives the settings "Experimental" UI).
    def experimental
      all.select(&:experimental?)
    end

    # Currently-enabled extensions, per the persisted settings row.
    def enabled
      all.select(&:enabled?)
    end

    # ---- Hook resolvers ------------------------------------------------------

    # The CLI adapter class an enabled extension wants to substitute for the
    # given runtime's default adapter, or nil if none does. First enabled
    # extension (in registration order) to answer wins.
    def cli_adapter_override_for(runtime)
      enabled.lazy.filter_map { |ext| ext.cli_adapter_override(runtime) }.first
    end

    # An instantiated print-mode inference backend from the first enabled
    # extension that provides one, or nil to fall back to the native runner.
    # `force: true` considers ALL extensions (ignoring enablement) — used by the
    # diagnostic/test override that forces the extension backend on.
    def print_runner_backend(force: false, claude_binary:, model:, process_manager: nil, logger: Rails.logger)
      candidates = force ? all : enabled
      candidates.lazy.filter_map do |ext|
        ext.print_runner_backend(
          claude_binary: claude_binary, model: model,
          process_manager: process_manager, logger: logger
        )
      end.first
    end

    # Whether any enabled extension provides a print-mode backend (cheap check
    # that avoids constructing one).
    def print_runner_backend?
      enabled.any?(&:provides_print_runner?)
    end

    # The merged environment contribution of all enabled extensions, stringified.
    # Later extensions override earlier ones on key collision.
    def spawn_env_contributions(context = {})
      enabled.each_with_object({}) do |ext, env|
        contribution = ext.spawn_env_contribution(context)
        next if contribution.blank?

        contribution.each { |k, v| env[k.to_s] = v.to_s }
      end
    end
  end
end
