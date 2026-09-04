# frozen_string_literal: true

require "test_helper"
require "support/fake_parameter_store"

module ParameterStore
  # The write verbs, exercised against the same in-memory store the resolver
  # reads from — so every test here ends by asking the production resolver
  # whether the thing it just wrote actually resolves.
  class WriteClientTest < ActiveSupport::TestCase
    setup do
      @fake = FakeParameterStore.new
      @writer = @fake.write_client
      @reader = @fake.client
      @namespace = Namespace.static_namespace
    end

    test "a created secret resolves through the resolver" do
      @writer.upsert("OPENROUTER_API_KEY", "sk-or-v1-created")

      assert_equal "sk-or-v1-created", @reader.resolve(@namespace).fetch("OPENROUTER_API_KEY")
    end

    test "the value never touches a Parameter Manager payload" do
      @writer.upsert("OPENROUTER_API_KEY", "sk-or-v1-canary")

      assert_equal "sk-or-v1-canary", @reader.resolve(@namespace).fetch("OPENROUTER_API_KEY")
      @fake.parameter_payloads.each do |payload|
        assert_no_match(/sk-or-v1-canary/, payload,
          "the parameter must hold a __REF__ pointer, never the secret itself")
      end
    end

    test "the envelope carries the canonical path, which is what guards the lossy id fold" do
      @writer.upsert("OPENROUTER_API_KEY", "sk-or-v1-x")

      envelope = JSON.parse(@fake.parameter_payloads.sole)
      assert_equal Namespace.parameter_path("OPENROUTER_API_KEY"), envelope["path"]
      assert envelope["secret"]
    end

    test "it grants the parameter's own principal access to the secret" do
      id = Namespace.parameter_id(Namespace.parameter_path("OPENROUTER_API_KEY"))
      @writer.upsert("OPENROUTER_API_KEY", "sk-or-v1-bound")

      assert_includes @fake.secret_policies[id], FakeParameterStore.principal_for(id),
        "without this binding :render 400s and the variable silently resolves to nothing"
    end

    test "without that binding the value would not resolve at all" do
      @writer.upsert("OPENROUTER_API_KEY", "sk-or-v1-bound")
      @fake.revoke_parameter_binding!("OPENROUTER_API_KEY")

      # This is the production failure the binding prevents: everything exists,
      # nothing reads.
      assert_raises(StoreError) { @reader.resolve(@namespace) }
    end

    test "rotating writes a Secret Manager version and no second parameter version" do
      @writer.upsert("OPENROUTER_API_KEY", "sk-or-v1-first")
      before = @fake.parameter_payloads.size

      @writer.upsert("OPENROUTER_API_KEY", "sk-or-v1-second")

      assert_equal before, @fake.parameter_payloads.size,
        "the envelope points at versions/latest, so a rotation adds no parameter version"
      assert_equal "sk-or-v1-second", @reader.resolve(@namespace).fetch("OPENROUTER_API_KEY")
    end

    test "an existing binding is merged, not replaced" do
      id = Namespace.parameter_id(Namespace.parameter_path("OPENROUTER_API_KEY"))
      @writer.upsert("OPENROUTER_API_KEY", "sk-or-v1-first")

      # Drop the parameter's own principal and leave a foreign one, so the second
      # upsert has to take the branch that ADDS a member. Leaving the principal in
      # place makes grant_accessor return early and the merge is never exercised —
      # the test then passes on a client that replaced the policy outright.
      @fake.secret_policies[id] = [ "user:someone@example.com" ]

      @writer.upsert("OPENROUTER_API_KEY", "sk-or-v1-second")

      assert_includes @fake.secret_policies[id], "user:someone@example.com",
        "a policy this code did not write must survive the merge"
      assert_includes @fake.secret_policies[id], FakeParameterStore.principal_for(id)
    end

    test "delete removes both resources, so the variable stops resolving" do
      @writer.upsert("OPENROUTER_API_KEY", "sk-or-v1-doomed")
      assert_equal "sk-or-v1-doomed", @reader.resolve(@namespace).fetch("OPENROUTER_API_KEY")

      @writer.delete("OPENROUTER_API_KEY")

      assert_empty @reader.resolve(@namespace)
      assert_empty @fake.parameters
      assert_empty @fake.secrets
    end

    # `Namespace.parameter_id` is a lossy fold, so a resolving id is not proof the
    # resource is ours. A delete that skipped this check could destroy a parameter
    # another system owns in the same project.
    test "delete refuses a parameter Zimmer does not manage" do
      id = Namespace.parameter_id(Namespace.parameter_path("OPENROUTER_API_KEY"))
      @fake.seed_unmanaged(id, { "path" => "/somebody/elses/thing", "secret" => false, "value" => "x" })

      assert_raises(StoreError) { @writer.delete("OPENROUTER_API_KEY") }
      assert @fake.parameters.key?(id), "the foreign parameter must still be there"
    end

    test "delete refuses a secret Zimmer does not manage" do
      id = Namespace.parameter_id(Namespace.parameter_path("OPENROUTER_API_KEY"))
      @fake.secrets[id] = [ "somebody-elses-value" ]

      assert_raises(StoreError) { @writer.delete("OPENROUTER_API_KEY") }
      assert @fake.secrets.key?(id), "the foreign secret must still be there"
    end

    test "delete of something that was never there is not an error" do
      assert_nothing_raised { @writer.delete("NEVER_SET") }
    end

    # The fake transport speaks any verb it is handed; the real one maps each to a
    # Net::HTTP class and raises on anything else. So a write path that issues a
    # verb the real transport cannot build is green here and 500s in production —
    # the fake is happy to DELETE whether or not HttpTransport is. Asserting
    # against the real transport's own table is what ties the two together.
    test "every verb the write path issues is one the real transport can speak" do
      @writer.upsert("OPENROUTER_API_KEY", "sk-or-v1-verbs")
      @writer.delete("OPENROUTER_API_KEY")

      verbs = @fake.requests.map(&:first).uniq
      assert_includes verbs, "DELETE", "precondition: the delete path was exercised"
      assert_empty verbs - HttpTransport::METHODS.keys,
        "the write path issues a verb ParameterStore::HttpTransport cannot build"
    end

    test "the real transport refuses an unknown verb by name rather than by KeyError" do
      error = assert_raises(ArgumentError) do
        HttpTransport.new.request("PATCH", "https://example.test/x", {}, nil)
      end

      assert_match(/PATCH/, error.message)
    end

    test "a store failure is raised, never swallowed" do
      @fake.fail_with!(403)

      assert_raises(StoreError) { @writer.upsert("OPENROUTER_API_KEY", "sk-or-v1-x") }
    end

    test "a failure message names the resource and never the value" do
      @fake.fail_with!(403)

      error = assert_raises(StoreError) { @writer.upsert("OPENROUTER_API_KEY", "sk-or-v1-supersecret") }

      assert_match(/secrets/, error.message)
      assert_no_match(/sk-or-v1-supersecret/, error.message)
    end
  end
end
