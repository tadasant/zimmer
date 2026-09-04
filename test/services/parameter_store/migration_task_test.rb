# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "support/fake_parameter_store"

module ParameterStore
  # The rake tasks' wiring: which credentials it builds, what it refuses before
  # touching anything, and what it prints. Tested here rather than left to the
  # .rake file, because the refusals are the part that keeps a half-capable
  # credential from copying every secret and deleting none.
  class MigrationTaskTest < ActiveSupport::TestCase
    setup do
      @fake = FakeParameterStore.new
      @fake.held_permissions = Capabilities::PROBED_PERMISSIONS
      @out = StringIO.new
    end

    def stub_clients(writer: @fake.write_client, identity: :writer)
      Resolver.stubs(:from_env).returns(Resolver::Configuration.new(client: @fake.client, reason: nil))
      Writer.stubs(:from_env).returns(
        Writer::Configuration.new(client: writer, reason: nil, identity: identity))
    end

    def task(dry_run: true, env: {})
      MigrationTask.new(dry_run: dry_run, out: @out, env: { "PARAMS_ENV" => "production" }.merge(env))
    end

    def seed_legacy(variable, value)
      @fake.seed_secret(variable, value, path: Namespace.legacy_parameter_path(variable, "production"))
    end

    # --- refusals --------------------------------------------------------------

    test "refuses a live run that does not name the environment it is rewriting" do
      stub_clients
      error = assert_raises(MigrationTask::Refused) { task(dry_run: false).run }

      assert_match "CONFIRM=production", error.message
    end

    test "the confirmation has to match the environment, not merely be present" do
      stub_clients
      error = assert_raises(MigrationTask::Refused) do
        task(dry_run: false, env: { "CONFIRM" => "staging" }).run
      end

      assert_match "production", error.message
    end

    test "a dry run needs no confirmation" do
      stub_clients

      assert task(dry_run: true).run.dry_run
    end

    test "refuses when there is no resolver credential, because nothing can be read" do
      Resolver.stubs(:from_env).returns(Resolver::Configuration.new(client: nil, reason: "not set"))

      error = assert_raises(MigrationTask::Refused) { task.run }
      assert_match "resolver credential", error.message
    end

    test "refuses before writing when the writer cannot delete" do
      # The failure this exists to prevent: a credential that can create but not
      # delete copies every secret and removes none, leaving both namespaces full
      # and no error until the very last call.
      @fake.held_permissions = Capabilities::UPSERT_PERMISSIONS
      stub_clients
      seed_legacy("STRAD_API_KEY", "sk-live")

      error = assert_raises(MigrationTask::Refused) do
        task(dry_run: false, env: { "CONFIRM" => "production" }).run
      end

      assert_match "cannot delete", error.message
      assert_match "PRUNE=false", error.message
      assert_equal({ "STRAD_API_KEY" => "sk-live" },
        @fake.client.resolve(Namespace.legacy_static_namespace("production")))
      assert_empty @fake.client.resolve(Namespace.static_namespace("production"))
    end

    test "a copy-only run is allowed on a credential that cannot delete" do
      @fake.held_permissions = Capabilities::UPSERT_PERMISSIONS
      stub_clients
      seed_legacy("STRAD_API_KEY", "sk-live")

      report = task(dry_run: false, env: { "CONFIRM" => "production", "PRUNE" => "false" }).run

      assert report.ok?
      assert_equal [ :copied ], report.items.map(&:action)
    end

    test "refuses when the writer's permissions could not be probed at all" do
      @fake.fail_with!(403)
      stub_clients

      error = assert_raises(MigrationTask::Refused) do
        task(dry_run: false, env: { "CONFIRM" => "production" }).run
      end

      assert_match "could not confirm the writer's permissions", error.message
    end

    test "says out loud when the write would go out as the read-only resolver" do
      stub_clients(identity: :resolver)

      task(dry_run: false, env: { "CONFIRM" => "production" }).run

      assert_match "writing as the RESOLVER credential", @out.string
    end

    # --- the printout ----------------------------------------------------------

    test "the plan names both namespaces and every variable's disposition" do
      stub_clients
      seed_legacy("GH_TOKEN", "gho-token")
      @fake.seed_secret("OPENROUTER_API_KEY", "sk-or", env: "production")

      task.run

      assert_match "PLAN (nothing written)", @out.string
      assert_match "from /zimmer/production/mcp/static/", @out.string
      assert_match "to /zimmer/production/secrets/static/", @out.string
      assert_match "[migrated] GH_TOKEN", @out.string
      assert_match "[already_migrated] OPENROUTER_API_KEY", @out.string
      assert_match "still at /zimmer/production/mcp/static/: GH_TOKEN", @out.string
    end

    test "no printed line carries a secret value" do
      stub_clients
      seed_legacy("GH_TOKEN", "gho-a-very-distinctive-token")

      task(dry_run: false, env: { "CONFIRM" => "production" }).run

      assert_no_match(/gho-a-very-distinctive-token/, @out.string)
    end

    test "a finished migration prints the sentence that unblocks the follow-up PR" do
      stub_clients
      @fake.seed_secret("GH_TOKEN", "gho-token", env: "production")

      task.run

      assert_match "is empty. The resolver's pre-rename read path can be dropped", @out.string
    end

    test "an empty store says so rather than printing an empty table" do
      stub_clients

      task.run

      assert_match "neither namespace holds anything", @out.string
    end

    test "PARAMS_ENV picks the namespace's environment, not the process's" do
      stub_clients
      @fake.seed_secret("GH_TOKEN", "gho", path: Namespace.legacy_parameter_path("GH_TOKEN", "staging"))

      report = task(dry_run: false,
        env: { "PARAMS_ENV" => "staging", "CONFIRM" => "staging" }).run

      assert_equal "staging", report.env
      assert report.complete?
      assert_match "to /zimmer/staging/secrets/static/", @out.string
    end
  end
end
