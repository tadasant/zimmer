# frozen_string_literal: true

require "test_helper"

# A `nil` bundle slot is only safe if nothing dereferences it.
#
# This test exists because that assumption broke. `PI_BUNDLE` originally left
# `mcp_status_detector_class` nil on the reasonable-sounding grounds that Pi
# exposes no per-server MCP signal — but `TranscriptPollerService#initialize`
# calls `.new` on that slot unconditionally, so every poll of every Pi session
# would have raised `NoMethodError` before any MCP-specific guard could run. The
# per-class unit tests all passed; nothing exercised the runtime through a
# runtime-agnostic caller.
#
# So this asserts the property directly, for every registered runtime, forever:
# a slot that some caller instantiates must be non-nil in every bundle. A runtime
# with nothing real to put there supplies a null object (NullMcpStatusDetector),
# which is the honest way to say "no signal" without handing callers a nil.
class RuntimeBundleSlotContractTest < ActiveSupport::TestCase
  # Slots that at least one caller dereferences without a nil check, and the
  # caller that does it — named so a failure points at the code to fix rather
  # than just at the registry.
  #
  # Slots deliberately left nil are NOT listed: `auth_provider_class` and
  # `config_preparer_class` are nil for every runtime and nothing reads them
  # (auth resolves through RuntimeAuthProvider.for instead), and
  # `mcp_credential_writer_class` is nil for Pi with its one caller guarded by
  # McpOauthCredentialInjector#credential_store?.
  UNCONDITIONALLY_DEREFERENCED_SLOTS = {
    cli_adapter_class: "RuntimeRegistry.cli_adapter_class_for / ProcessLifecycleManager",
    retry_strategy_class: "the runtime's own #retry_strategy factory",
    transcript_source_class: "TranscriptPollerService, AgentSessionJob",
    transcript_normalizer_class: "TranscriptPollerService",
    mcp_status_detector_class: "TranscriptPollerService#initialize",
    config_post_processor_class: "AirPrepareService#post_processor",
    artifact_bridge_class: "AirPrepareService#artifact_bridge"
  }.freeze

  RuntimeRegistry.registered_runtimes.each do |runtime|
    UNCONDITIONALLY_DEREFERENCED_SLOTS.each do |slot, caller_description|
      test "#{runtime} bundle fills #{slot}, which #{caller_description} dereferences" do
        bundle = RuntimeRegistry.for(runtime)

        assert_not_nil bundle.public_send(slot),
          "RuntimeRegistry::BUNDLES[#{runtime.inspect}].#{slot} is nil, but #{caller_description} " \
          "calls a method on it without a nil check — every session on this runtime would raise " \
          "NoMethodError. Supply a real class, or a null object if the runtime genuinely has " \
          "nothing to report (see NullMcpStatusDetector)."
      end
    end
  end

  # The specific caller that broke, exercised end-to-end for each runtime rather
  # than asserted about. Construction is where it failed, so construction is what
  # this covers.
  RuntimeRegistry.registered_runtimes.each do |runtime|
    test "TranscriptPollerService can be constructed for a #{runtime} session" do
      session = sessions(:active_session)
      session.update!(agent_runtime: runtime)

      assert_nothing_raised do
        TranscriptPollerService.new(session, file_system: MockFileSystemAdapter.new)
      end
    end
  end

  # Every runtime must resolve through the three registries that bypass the
  # bundle. RuntimeAuthProvider.for RAISES for an unregistered runtime and is
  # called with a session's raw agent_runtime from several runtime-agnostic call
  # sites, so a missing registration is a crash rather than a degraded feature.
  RuntimeRegistry.registered_runtimes.each do |runtime|
    test "#{runtime} resolves an auth provider, a prompt contribution and a model catalog" do
      assert_nothing_raised { RuntimeAuthProvider.for(runtime) }
      assert_kind_of RuntimeAuthProvider, RuntimeAuthProvider.for(runtime)

      assert_kind_of RuntimePromptContribution, RuntimePromptContribution.for(runtime)

      models = ModelCatalog.models_for(runtime)
      assert models.any?, "#{runtime} has no models in ModelCatalog"
      assert_not_nil ModelCatalog.default_for(runtime), "#{runtime} has no default model"
    end
  end

  # An empty account pool must answer "no", not raise — several sweeps chain
  # `.available` onto whatever #accounts returns.
  RuntimeRegistry.registered_runtimes.each do |runtime|
    test "#{runtime}'s auth provider exposes a chainable accounts relation" do
      accounts = RuntimeAuthProvider.for(runtime).accounts

      assert_nothing_raised { accounts.available.exists? }
    end
  end
end
