# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class ModelCatalogCliCheckTest < ActiveSupport::TestCase
  CODEX_MODELS = { "models" => [ { "slug" => "gpt-5.6-terra" }, { "slug" => "gpt-5.5" } ] }.to_json

  PI_LIST = <<~TABLE
    provider    model                            context  max-out  thinking  images
    openrouter  openai/gpt-5.4                   400K     128K     yes       yes
    openrouter  google/gemini-3.5-flash          1M       64K      yes       yes
  TABLE

  def stub_run(argv, stdout: "", stderr: "", exitstatus: 0)
    BoundedSubprocess.stubs(:run).with(argv, has_entries(timeout: ModelCatalogCliCheck::TIMEOUT))
      .returns([ stdout, stderr, fake_process_status(exitstatus: exitstatus) ])
  end

  def stub_version(cli, stdout)
    BoundedSubprocess.stubs(:run).with([ cli, "--version" ], has_entries(timeout: ModelCatalogCliCheck::VERSION_TIMEOUT))
      .returns([ stdout, "", fake_process_status ])
  end

  test "codex: an id in `codex debug models` is listed" do
    stub_version("codex", "codex-cli 0.146.0\n")
    stub_run([ "codex", "debug", "models", "--bundled" ], stdout: CODEX_MODELS)

    result = ModelCatalogCliCheck.check("codex", "gpt-5.5")

    assert_equal true, result.listed
    assert_equal "0.146.0", result.cli_version
    assert_equal "Listed by codex 0.146.0.", result.note
  end

  test "codex: an id missing from the list is unlisted, and the note says the provider decides" do
    stub_version("codex", "codex-cli 0.146.0\n")
    stub_run([ "codex", "debug", "models", "--bundled" ], stdout: CODEX_MODELS)

    result = ModelCatalogCliCheck.check("codex", "gpt-9")

    assert_equal false, result.listed
    assert_match(/Not in codex 0.146.0's model list/, result.note)
    assert_match(/first turn/, result.note)
  end

  test "codex: unparseable output is unchecked, not unlisted" do
    stub_version("codex", "codex-cli 0.146.0\n")
    stub_run([ "codex", "debug", "models", "--bundled" ], stdout: "not json")

    result = ModelCatalogCliCheck.check("codex", "gpt-5.5")

    assert_nil result.listed
    assert_match(/Could not check against codex/, result.note)
  end

  test "pi: lists provider-qualified ids, with a placeholder key for the provider and no network" do
    stub_version("pi", "0.84.4\n")
    BoundedSubprocess.expects(:run).with(
      [ "pi", "--offline", "--list-models" ],
      has_entries(env: has_entries("OPENROUTER_API_KEY" => "zimmer-model-catalog-check", "PI_OFFLINE" => "1"))
    ).returns([ PI_LIST, "", fake_process_status ])

    result = ModelCatalogCliCheck.check("pi", "openrouter/openai/gpt-5.4")

    assert_equal true, result.listed
    assert_equal "0.84.4", result.cli_version
  end

  test "pi: a thinking suffix is not part of the listed id" do
    stub_version("pi", "0.84.4\n")
    stub_run([ "pi", "--offline", "--list-models" ], stdout: PI_LIST)

    assert_equal true, ModelCatalogCliCheck.check("pi", "openrouter/openai/gpt-5.4:high").listed
  end

  test "pi: an id missing from its provider's rows is unlisted" do
    stub_version("pi", "0.84.4\n")
    stub_run([ "pi", "--offline", "--list-models" ], stdout: PI_LIST)

    result = ModelCatalogCliCheck.check("pi", "openrouter/openai/gpt-9")

    assert_equal false, result.listed
    assert_match(/custom model id/, result.note)
  end

  test "pi: a provider with no rows is unchecked, since Pi only lists providers whose key resolves" do
    stub_version("pi", "0.84.4\n")
    BoundedSubprocess.expects(:run).with(
      [ "pi", "--offline", "--list-models" ], has_entries(env: has_entries("GEMINI_API_KEY" => "zimmer-model-catalog-check"))
    ).returns([ PI_LIST, "", fake_process_status ])

    result = ModelCatalogCliCheck.check("pi", "google/gemini-9")

    assert_nil result.listed
    assert_match(/lists no models for the google provider/, result.note)
  end

  test "pi: providers whose key is not <PROVIDER>_API_KEY get the right placeholder variable" do
    { "huggingface" => "HF_TOKEN", "amazon-bedrock" => "AWS_BEARER_TOKEN_BEDROCK", "openai" => "OPENAI_API_KEY" }.each do |provider, variable|
      BoundedSubprocess.unstub(:run)
      stub_version("pi", "0.84.4\n")
      BoundedSubprocess.expects(:run).with(
        [ "pi", "--offline", "--list-models" ], has_entries(env: has_entries(variable => "zimmer-model-catalog-check"))
      ).returns([ "", "", fake_process_status ])

      assert_nil ModelCatalogCliCheck.check("pi", "#{provider}/some-model").listed
    end
  end

  test "pi: output that is not valid UTF-8 is still parsed" do
    stub_version("pi", "0.84.4\n")
    stub_run([ "pi", "--offline", "--list-models" ], stdout: "#{PI_LIST}openrouter  bad\xFFmodel  1M\n".b)

    assert_equal true, ModelCatalogCliCheck.check("pi", "openrouter/openai/gpt-5.4").listed
  end

  test "a missing or failing CLI is unchecked, never an exception" do
    BoundedSubprocess.stubs(:run).raises(Errno::ENOENT, "pi")
    result = ModelCatalogCliCheck.check("pi", "openrouter/openai/gpt-5.4")
    assert_nil result.listed
    assert_nil result.cli_version
    assert_match(/could not be run/, result.note)

    BoundedSubprocess.unstub(:run)
    BoundedSubprocess.stubs(:run).raises(BoundedSubprocess::TimeoutError, "late")
    assert_match(/timed out/, ModelCatalogCliCheck.check("codex", "gpt-5.5").note)

    BoundedSubprocess.unstub(:run)
    BoundedSubprocess.stubs(:run).returns([ "", "boom", fake_process_status(exitstatus: 2) ])
    assert_match(/exited 2: boom/, ModelCatalogCliCheck.check("codex", "gpt-5.5").note)
  end

  test "claude_code has no list, so the id is unchecked without running anything" do
    BoundedSubprocess.expects(:run).never

    result = ModelCatalogCliCheck.check("claude_code", "opus[1m]")

    assert_nil result.listed
    assert_match(/no model list/, result.note)
  end
end
