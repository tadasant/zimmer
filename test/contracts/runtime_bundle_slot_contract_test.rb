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

  # Non-nil was never the whole contract, and this is the test that says so.
  #
  # NullMcpStatusDetector passed every assertion above and still broke the Pi
  # runtime in production the first time a Pi session polled: it included
  # McpStatusPersisting without DatabaseRetry, so `update_session_mcp_status` —
  # which TranscriptPollerService#poll_mcp_logs calls on EVERY poll, immediately
  # after `poll` — had no `with_db_retry` to call and raised NoMethodError. The
  # slot was filled, construction succeeded, and the runtime was still broken.
  #
  # It stayed invisible because poll_mcp_logs rescues everything and logs: a
  # detector that raises there costs the runtime its MCP status silently. So this
  # calls the two methods directly, where a raise is a test failure rather than a
  # log line, and asserts the persistence step's actual product — not that some
  # `include` is present, which the next detector would forget just as easily.
  RuntimeRegistry.registered_runtimes.each do |runtime|
    test "#{runtime}'s MCP status detector can poll AND persist, not just construct" do
      session = sessions(:active_session)
      session.update!(agent_runtime: runtime)
      assert session.all_mcp_servers.any?, "fixture must have trackable servers for this to test anything"

      detector = RuntimeRegistry.for(runtime).mcp_status_detector_class.new(
        session, file_system: MockFileSystemAdapter.new, min_timestamp: nil
      )

      # No assert_nothing_raised around `poll`: a raise here fails the test on its
      # own, and wrapping it would over-claim — CodexMcpStatusDetector#poll has a
      # blanket rescue, so the assertion could never fail for that runtime anyway.
      # The persist call is the one that broke, and it has no rescue of its own.
      result = detector.poll(transcript_content: nil)
      assert_nothing_raised do
        detector.update_session_mcp_status(result[:server_statuses])
      end

      # What the persistence step is FOR: every trackable server is present in
      # mcp_servers_status, at worst as `pending`. A server missing here reads as
      # "not configured" to the REST API and the get_session MCP tool, which is
      # exactly what a detector that raises leaves behind.
      persisted = session.reload.custom_metadata["mcp_servers_status"] || {}
      session.all_mcp_servers.each do |server_name|
        entry = persisted[server_name]

        assert entry.is_a?(Hash) && entry["status"].present?,
          "#{runtime}'s detector (#{detector.class}) left #{server_name.inspect} without a status " \
          "in mcp_servers_status (got #{entry.inspect}). Every trackable server must be seeded, " \
          "at minimum as pending."
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
