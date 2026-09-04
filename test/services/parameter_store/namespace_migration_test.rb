# frozen_string_literal: true

require "test_helper"
require "support/fake_parameter_store"

module ParameterStore
  # The scope segment of Zimmer's secret namespace was renamed, and because
  # `Namespace.parameter_id` folds a whole path into one flat id, the rename
  # cannot happen in place. These tests drive the real resolver and the real
  # write client against one in-memory store, so what they exercise is the
  # sequence — read, write, verify through the chain, delete — and not a mock of
  # it.
  class NamespaceMigrationTest < ActiveSupport::TestCase
    setup do
      @fake = FakeParameterStore.new
      @env = "production"
    end

    def legacy_path(variable) = Namespace.legacy_parameter_path(variable, @env)
    def canonical_path(variable) = Namespace.parameter_path(variable, @env)

    def seed_legacy(variable, value)
      @fake.seed_secret(variable, value, path: legacy_path(variable))
    end

    def seed_canonical(variable, value)
      @fake.seed_secret(variable, value, path: canonical_path(variable))
    end

    def migration(dry_run: true, prune: true)
      NamespaceMigration.new(resolver: @fake.client, writer: @fake.write_client,
        env: @env, dry_run: dry_run, prune: prune)
    end

    # Read back the way production does: the ordinary chain, over the namespaces
    # the environment being migrated actually uses.
    def chain = @fake.chain(namespaces: Namespace.read_namespaces(@env))

    # The same, fenced to ONE namespace, so "it resolves" cannot be answered by
    # the copy in the other one.
    def resolves_at?(namespace, variable)
      @fake.chain(namespaces: [ namespace ]).has?(variable)
    end

    # Whether the store still holds the pair behind a path at all. Asked of the
    # store rather than through a read, for the one case where a read cannot
    # answer: a parameter whose IAM binding is broken 400s on :render and takes
    # the whole namespace listing down with it.
    def stored?(path)
      id = Namespace.parameter_id(path)
      @fake.parameters.key?(id) && @fake.secrets.key?(id)
    end

    # --- the plan --------------------------------------------------------------

    test "a dry run writes nothing and deletes nothing" do
      seed_legacy("STRAD_API_KEY", "sk-live")
      before = @fake.requests.size

      report = migration.call

      assert report.dry_run
      assert_equal [ :migrated ], report.items.map(&:action)
      mutations = @fake.requests[before..].reject { |method, _| method == "GET" }
      assert_empty mutations, "a dry run must issue no write, no delete, and no IAM change"
      assert resolves_at?(Namespace.legacy_static_namespace(@env), "STRAD_API_KEY")
      assert_not resolves_at?(Namespace.static_namespace(@env), "STRAD_API_KEY")
    end

    test "a dry run does not report a store it has not touched as complete" do
      seed_legacy("STRAD_API_KEY", "sk-live")

      report = migration.call

      assert_not report.complete?, "nothing was deleted, so the old path still holds it"
      assert_equal [ "STRAD_API_KEY" ], report.legacy_remaining
    end

    test "the plan names both paths and the two different ids the fold produces" do
      seed_legacy("STRAD_API_KEY", "sk-live")

      item = migration.call.items.sole

      assert_equal "/zimmer/production/mcp/static/STRAD_API_KEY", item.from_path
      assert_equal "/zimmer/production/secrets/static/STRAD_API_KEY", item.to_path
      assert_not_equal item.from_id, item.to_id
    end

    # --- the move --------------------------------------------------------------

    test "migrates a secret to the canonical path and removes the old pair" do
      seed_legacy("STRAD_API_KEY", "sk-live")

      report = migration(dry_run: false).call

      assert report.ok?
      assert report.complete?
      assert_equal [ :migrated ], report.items.map(&:action)
      assert resolves_at?(Namespace.static_namespace(@env), "STRAD_API_KEY")
      assert_not resolves_at?(Namespace.legacy_static_namespace(@env), "STRAD_API_KEY")
    end

    test "the migrated value is the one that resolves, through the ordinary chain" do
      seed_legacy("STRAD_API_KEY", "sk-live")

      migration(dry_run: false).call

      assert_equal "sk-live", chain.get("STRAD_API_KEY")
      assert_equal Namespace.static_namespace(@env),
        @fake.provider(namespaces: Namespace.read_namespaces(@env)).namespace_for("STRAD_API_KEY")
    end

    test "the value never lands in a Parameter Manager payload on the way across" do
      seed_legacy("STRAD_API_KEY", "sk-live")

      migration(dry_run: false).call

      @fake.parameter_payloads.each do |payload|
        assert_no_match(/sk-live/, payload,
          "the copy must go through Secret Manager, never through the envelope")
      end
    end

    test "the report never carries a secret value" do
      seed_legacy("STRAD_API_KEY", "sk-live-and-very-distinctive")

      report = migration(dry_run: false).call

      assert_no_match(/sk-live-and-very-distinctive/, report.inspect)
      report.items.each { |item| assert_no_match(/sk-live-and-very-distinctive/, item.detail) }
    end

    # --- re-running ------------------------------------------------------------

    test "a second run over a finished migration does nothing and says so" do
      seed_legacy("STRAD_API_KEY", "sk-live")
      migration(dry_run: false).call
      before = @fake.requests.size

      report = migration(dry_run: false).call

      assert report.complete?
      assert_equal [ :already_migrated ], report.items.map(&:action)
      mutations = @fake.requests[before..].reject { |method, _| method == "GET" }
      assert_empty mutations, "there was nothing left to move"
    end

    test "a run interrupted after the copy finishes the delete on the next pass" do
      # Exactly the state a crash between upsert and delete leaves: both paths
      # hold the same value.
      seed_legacy("STRAD_API_KEY", "sk-live")
      seed_canonical("STRAD_API_KEY", "sk-live")

      report = migration(dry_run: false).call

      assert report.complete?
      assert_equal [ :migrated ], report.items.map(&:action)
      assert_not resolves_at?(Namespace.legacy_static_namespace(@env), "STRAD_API_KEY")
      assert_equal "sk-live", chain.get("STRAD_API_KEY")
    end

    test "a variable already only at the canonical path is left completely alone" do
      seed_canonical("STRAD_API_KEY", "sk-live")
      before = @fake.requests.size

      report = migration(dry_run: false).call

      assert report.complete?
      assert_equal [ :already_migrated ], report.items.map(&:action)
      assert_empty @fake.requests[before..].reject { |method, _| method == "GET" }
    end

    # --- the refusals ----------------------------------------------------------

    test "two different values at the two paths is a conflict, not a decision to make" do
      # The canonical value wins the chain, so it is the live one. Copying the old
      # copy over it would be a silent rollback of whatever rotation set it.
      seed_legacy("STRAD_API_KEY", "old-rotated-out")
      seed_canonical("STRAD_API_KEY", "new-live-value")

      report = migration(dry_run: false).call

      assert_not report.ok?
      assert_equal [ :conflict ], report.items.map(&:action)
      assert_equal "new-live-value", chain.get("STRAD_API_KEY")
      assert resolves_at?(Namespace.legacy_static_namespace(@env), "STRAD_API_KEY")
    end

    test "a new path that does not resolve is not a licence to delete the old one" do
      # The forgotten secretAccessor binding: everything reports success and every
      # render 400s. If the delete ran on the strength of the write's exit status,
      # this is where the secret would be lost.
      seed_legacy("STRAD_API_KEY", "sk-live")
      canonical_id = Namespace.parameter_id(canonical_path("STRAD_API_KEY"))
      writer = @fake.write_client
      writer.define_singleton_method(:grant_accessor) { |*| nil }

      report = NamespaceMigration.new(resolver: @fake.client, writer: writer,
        env: @env, dry_run: false).call

      assert_not report.ok?
      assert_equal [ :failed ], report.items.map(&:action)
      assert_match canonical_id, report.items.sole.detail
      assert stored?(legacy_path("STRAD_API_KEY")),
        "the only readable copy must survive a failed verify"
    end

    test "pruning off copies the value and leaves the old path standing" do
      seed_legacy("STRAD_API_KEY", "sk-live")

      report = migration(dry_run: false, prune: false).call

      assert report.ok?
      assert_not report.complete?
      assert_equal [ :copied ], report.items.map(&:action)
      assert resolves_at?(Namespace.static_namespace(@env), "STRAD_API_KEY")
      assert resolves_at?(Namespace.legacy_static_namespace(@env), "STRAD_API_KEY")
    end

    test "a live migration without a write client is refused at construction" do
      error = assert_raises(ArgumentError) do
        NamespaceMigration.new(resolver: @fake.client, env: @env, dry_run: false)
      end

      assert_match "write client", error.message
    end

    test "a store that cannot be listed raises rather than reporting an empty namespace" do
      @fake.fail_with!(503)

      assert_raises(StoreError) { migration.call }
    end

    # --- many variables --------------------------------------------------------

    test "moves every variable in the namespace, reporting each one" do
      seed_legacy("STRAD_API_KEY", "one")
      seed_legacy("GH_TOKEN", "two")
      seed_legacy("OPENROUTER_API_KEY", "three")

      report = migration(dry_run: false).call

      assert report.complete?
      assert_equal %w[GH_TOKEN OPENROUTER_API_KEY STRAD_API_KEY], report.items.map(&:variable)
      assert_equal({ migrated: 3 }, report.counts)
      assert_equal "two", chain.get("GH_TOKEN")
    end

    test "one variable's conflict does not stop the others from moving" do
      seed_legacy("GH_TOKEN", "two")
      seed_legacy("STRAD_API_KEY", "old")
      seed_canonical("STRAD_API_KEY", "new")

      report = migration(dry_run: false).call

      assert_not report.ok?
      assert_equal [ "STRAD_API_KEY" ], report.failures.map(&:variable)
      assert_equal [ "STRAD_API_KEY" ], report.legacy_remaining
      assert_not resolves_at?(Namespace.legacy_static_namespace(@env), "GH_TOKEN")
    end

    test "the environment migrated is the one asked for, not the process's own" do
      @fake.seed_secret("STRAD_API_KEY", "sk-live",
        path: Namespace.legacy_parameter_path("STRAD_API_KEY", "staging"))

      report = NamespaceMigration.new(resolver: @fake.client, writer: @fake.write_client,
        env: "staging", dry_run: false).call

      assert report.complete?
      assert_equal "/zimmer/staging/secrets/static/STRAD_API_KEY", report.items.sole.to_path
      assert resolves_at?(Namespace.static_namespace("staging"), "STRAD_API_KEY")
    end

    test "an empty store is a finished migration, reported as such" do
      report = migration.call

      assert_empty report.items
      assert report.complete?
      assert report.ok?
    end
  end
end
