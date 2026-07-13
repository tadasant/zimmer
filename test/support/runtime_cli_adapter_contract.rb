# frozen_string_literal: true

# Shared assertions for the RuntimeCliAdapter interface contract.
#
# Every runtime CLI adapter must satisfy the same surface so
# ProcessLifecycleManager can depend on the interface rather than a concrete
# runtime. The permanent adapters are exercised in
# test/contracts/runtime_cli_adapter_contract_test.rb; extension-provided
# adapters (e.g. PtyClaudeCliAdapter) call the same helper from their own test
# under test/extensions/ so the coverage is deleted along with the extension.
module RuntimeCliAdapterContractAssertions
  # Keyword arguments every adapter's #execute must accept. auto_compact_window is
  # a Claude-only concept, but ProcessLifecycleManager and the retry services pass
  # it uniformly to whichever runtime adapter is selected, so every adapter must
  # accept it (Codex ignores it). Omitting it regressed Codex spawn (#3884).
  EXECUTE_KEYWORDS = %i[prompt session_id working_dir mcp_config_path images append_system_prompt model auto_compact_window].freeze

  # Keyword arguments every adapter's #resume must accept.
  RESUME_KEYWORDS = %i[session_id working_dir prompt mcp_config_path images append_system_prompt model auto_compact_window].freeze

  def assert_runtime_cli_adapter_contract(klass)
    assert klass.include?(RuntimeCliAdapter),
      "#{klass} must include RuntimeCliAdapter so it is recognizable as a runtime adapter"

    adapter = klass.new
    %i[execute resume binary_name command_summary disallowed_tools runtime_env_vars retry_strategy
       process_manager process_manager= file_system file_system= zimmer_session_id zimmer_session_id=].each do |method_name|
      assert_respond_to adapter, method_name
    end

    assert_kind_of String, adapter.binary_name
    assert_predicate adapter.binary_name, :present?

    fresh = adapter.command_summary(session_id: "sess-123", prompt: "do a thing", resume: false)
    assert_kind_of String, fresh
    assert_predicate fresh, :present?
    # The summary must lead with the adapter's actual binary. This guards the
    # bug this method exists to prevent: a Codex session logging "claude ...".
    assert fresh.start_with?(adapter.binary_name),
      "#{klass}#command_summary should start with #{adapter.binary_name.inspect}, got: #{fresh.inspect}"
    # A resume summary surfaces the session id being resumed for every runtime.
    resumed = adapter.command_summary(session_id: "sess-123", prompt: "more", resume: true)
    assert_includes resumed, "sess-123"

    assert_kind_of Array, adapter.disallowed_tools
    assert_kind_of Hash, adapter.runtime_env_vars

    execute_missing = EXECUTE_KEYWORDS - runtime_cli_adapter_keyword_parameters(klass, :execute)
    assert_empty execute_missing, "#{klass}#execute is missing keyword(s): #{execute_missing.inspect}"

    resume_missing = RESUME_KEYWORDS - runtime_cli_adapter_keyword_parameters(klass, :resume)
    assert_empty resume_missing, "#{klass}#resume is missing keyword(s): #{resume_missing.inspect}"

    strategy = adapter.retry_strategy(
      session: nil,
      file_system: nil,
      process_manager: nil,
      rate_limit_tracker: nil
    )
    %i[context_length_error? failed_resume_recovery_needed? api_error_for_retry?].each do |method_name|
      assert_respond_to strategy, method_name
    end
  end

  private

  def runtime_cli_adapter_keyword_parameters(klass, method_name)
    klass.instance_method(method_name).parameters.filter_map do |type, name|
      name if %i[key keyreq].include?(type)
    end
  end
end
