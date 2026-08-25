# frozen_string_literal: true

require "minitest/mock"

# Shared conformance tests for the SessionAttachmentStorage surface.
#
# FileStorageService and ImageStorageService were once near-verbatim twins, and
# their two test suites were twins too — which is how a hardening applied to one
# copy stayed silently absent from the other. The lifecycle now lives once in
# SessionAttachmentStorage, and the tests for it live once here: both subclass
# suites include this module, so every assertion below runs against both.
#
# An including test case supplies four things:
#
#   storage_class                         # the class under test
#   storage_env_var                       # literal name of its storage_root override var
#   expected_storage_subdir               # literal name of its directory under ~/.zimmer
#   store_sample(service, filename: nil)  # stores one attachment, returns its metadata
#
# The path assertions deliberately compare against *literal* expected strings
# rather than re-deriving them from the class. A wrong storage_root does not
# raise — it silently orphans every attachment already on the durable volume and
# makes new uploads invisible to the worker container — so the test has to know
# the answer independently of the code that produces it.
module SessionAttachmentStorageConformance
  extend ActiveSupport::Concern

  included do
    teardown { teardown_conformance_storage }

    test "conformance: descends from SessionAttachmentStorage" do
      assert_operator storage_class, :<, SessionAttachmentStorage
    end

    test "conformance: declares its env var and subdir" do
      assert_equal storage_env_var, storage_class.storage_env_var
      assert_equal expected_storage_subdir, storage_class.storage_subdir
      assert_equal expected_storage_subdir, storage_class::STORAGE_SUBDIR
    end

    # --- Resolved paths -------------------------------------------------------

    test "conformance: with no override, paths resolve to <HOME>/.zimmer/<subdir>" do
      with_conformance_env(storage_env_var => nil, "AGENT_CLONES_DIR" => nil) do
        Dir.mktmpdir("attachment-home") do |home|
          with_conformance_env("HOME" => home) do
            assert_equal "#{home}/.zimmer/#{expected_storage_subdir}",
              storage_class.storage_root
            assert_equal "#{home}/.zimmer/#{expected_storage_subdir}/test-worker-#{Process.pid}",
              storage_class.base_dir
            assert_equal "#{home}/.zimmer/#{expected_storage_subdir}/test-worker-#{Process.pid}/42",
              storage_class.new(session_id: 42).session_dir
          end
        end
      end
    end

    test "conformance: with an absolute env override, paths resolve under it verbatim" do
      with_conformance_env(storage_env_var => "/mnt/durable/attachments") do
        assert_equal "/mnt/durable/attachments", storage_class.storage_root
        assert_equal "/mnt/durable/attachments/test-worker-#{Process.pid}", storage_class.base_dir
        assert_equal "/mnt/durable/attachments/test-worker-#{Process.pid}/42",
          storage_class.new(session_id: 42).session_dir
      end
    end

    test "conformance: storage_root expands a relative env override" do
      with_conformance_env(storage_env_var => "relative/attachments") do
        assert_equal File.expand_path("relative/attachments"), storage_class.storage_root
      end
    end

    test "conformance: storage_root sits beside the clones base on the durable volume" do
      with_conformance_env(storage_env_var => nil, "AGENT_CLONES_DIR" => nil) do
        root = storage_class.storage_root

        refute root.start_with?("/tmp"),
          "attachments must not live on per-container /tmp; got #{root}"
        assert_equal File.dirname(ClonesDirectory.base), File.dirname(root)
        assert_equal expected_storage_subdir, File.basename(root)
      end
    end

    test "conformance: storage_root is resolved at call time, never memoized" do
      with_conformance_env(storage_env_var => "/mnt/first") do
        assert_equal "/mnt/first", storage_class.storage_root
      end
      with_conformance_env(storage_env_var => "/mnt/second") do
        assert_equal "/mnt/second", storage_class.storage_root
      end
    end

    test "conformance: base_dir is not pid-namespaced outside the test environment" do
      with_conformance_env(storage_env_var => "/mnt/durable/attachments") do
        Rails.env.stub(:test?, false) do
          assert_equal "/mnt/durable/attachments", storage_class.base_dir
        end
      end
    end

    # --- session_id validation ------------------------------------------------

    test "conformance: rejects invalid session_id types" do
      assert_raises(ArgumentError) { storage_class.new(session_id: "123") }
      assert_raises(ArgumentError) { storage_class.new(session_id: nil) }
      assert_raises(ArgumentError) { storage_class.new(session_id: -1) }
      assert_raises(ArgumentError) { storage_class.new(session_id: 0) }
      assert_raises(ArgumentError) { storage_class.new(session_id: "../123") }
      assert_raises(ArgumentError) { storage_class.new(session_id: "temp_../../etc") }
    end

    test "conformance: accepts temp_<uuid> session_id for pre-session uploads" do
      uuid = SecureRandom.uuid
      service = storage_class.new(session_id: "temp_#{uuid}")

      assert_equal "temp_#{uuid}", service.session_id
      assert_equal File.join(storage_class.base_dir, "temp_#{uuid}"), service.session_dir
    end

    test "conformance: session_dir is namespaced by session_id" do
      other = storage_class.new(session_id: conformance_session_id + 1)

      assert_equal File.join(storage_class.base_dir, conformance_session_id.to_s),
        conformance_service.session_dir
      refute_equal conformance_service.session_dir, other.session_dir
    end

    # --- exists? path-traversal guard ----------------------------------------

    test "conformance: exists? confirms a stored attachment" do
      result = store_sample(conformance_service)

      assert conformance_service.exists?(result[:path])
    end

    test "conformance: exists? rejects blank and out-of-session paths" do
      refute conformance_service.exists?(nil)
      refute conformance_service.exists?("")
      refute conformance_service.exists?("/etc/passwd")
      refute conformance_service.exists?(File.join(storage_class.base_dir, "other-session", "thing"))
    end

    test "conformance: exists? rejects dot-dot traversal out of the session directory" do
      store_sample(conformance_service)
      dir = conformance_service.session_dir

      refute conformance_service.exists?("#{dir}/../../../etc/passwd")
      refute conformance_service.exists?("#{dir}/../../other/file")
      refute conformance_service.exists?("#{dir}/subdir/../../../etc/passwd")
      refute conformance_service.exists?(
        File.join(storage_class.base_dir, conformance_session_id.to_s, "..", "other", "thing")
      )
    end

    test "conformance: exists? rejects a sibling directory sharing the session_id prefix" do
      result = store_sample(conformance_service)
      sibling = "#{conformance_service.session_dir}-evil/#{File.basename(result[:path])}"

      refute conformance_service.exists?(sibling)
    end

    # --- list / store / cleanup ----------------------------------------------

    test "conformance: list is empty before anything is stored" do
      assert_equal [], conformance_service.list
    end

    test "conformance: list returns every stored attachment" do
      store_sample(conformance_service, filename: "one")
      store_sample(conformance_service, filename: "two")

      paths = conformance_service.list

      assert_equal 2, paths.length
      paths.each { |path| assert File.exist?(path) }
    end

    test "conformance: store writes into the session directory with unique paths" do
      first = store_sample(conformance_service)
      second = store_sample(conformance_service)

      refute_equal first[:path], second[:path]
      assert_equal conformance_service.session_dir, File.dirname(first[:path])
      assert_equal conformance_service.session_dir, File.dirname(second[:path])
    end

    test "conformance: cleanup! removes the session directory" do
      result = store_sample(conformance_service)
      assert File.exist?(result[:path])

      conformance_service.cleanup!

      refute File.exist?(result[:path])
      refute File.directory?(conformance_service.session_dir)
    end

    test "conformance: cleanup! on a session that stored nothing is a no-op" do
      assert_nothing_raised { conformance_service.cleanup! }
    end

    test "conformance: cleanup_for reaps a session's directory" do
      result = store_sample(conformance_service)
      assert File.exist?(result[:path])

      storage_class.cleanup_for(conformance_session_id)

      refute File.directory?(conformance_service.session_dir)
    end

    test "conformance: cleanup_for swallows an invalid session id" do
      assert_nothing_raised { storage_class.cleanup_for(nil) }
      assert_nothing_raised { storage_class.cleanup_for("../etc") }
    end

    # --- copy_from_temp -------------------------------------------------------

    test "conformance: copy_from_temp moves attachments to the real session and reaps the temp" do
      temp_service = storage_class.new(session_id: "temp_#{SecureRandom.uuid}")
      store_sample(temp_service, filename: "one")
      store_sample(temp_service, filename: "two")

      real_service = conformance_other_service

      copied = storage_class.copy_from_temp(
        temp_session_id: temp_service.session_id,
        new_session_id: conformance_session_id + 1
      )

      assert_equal 2, copied.length
      copied.each do |entry|
        assert File.exist?(entry[:path])
        assert_equal real_service.session_dir, File.dirname(entry[:path])
      end
      assert_equal 2, real_service.list.length
      refute File.directory?(temp_service.session_dir)
    ensure
      temp_service&.cleanup!
    end

    test "conformance: copy_from_temp on an empty temp session returns nothing" do
      copied = storage_class.copy_from_temp(
        temp_session_id: "temp_#{SecureRandom.uuid}",
        new_session_id: conformance_session_id + 1
      )

      assert_equal [], copied
    end

    test "conformance: copy_from_temp skips an entry it cannot re-store and copies the rest" do
      temp_service = storage_class.new(session_id: "temp_#{SecureRandom.uuid}")
      store_sample(temp_service, filename: "one")
      store_sample(temp_service, filename: "two")

      # An empty entry can be neither sniffed (image) nor re-stored (file), so
      # the loop must drop it and carry on rather than abandoning the batch.
      File.binwrite(temp_service.list.min, "")

      copied = storage_class.copy_from_temp(
        temp_session_id: temp_service.session_id,
        new_session_id: conformance_session_id + 1
      )

      assert_equal 1, copied.length
      assert File.exist?(copied.first[:path])
      refute File.directory?(temp_service.session_dir)
    ensure
      temp_service&.cleanup!
    end
  end

  # A service for the test case's own session id, memoized per test.
  def conformance_service
    @conformance_service ||= storage_class.new(session_id: conformance_session_id)
  end

  # A second service, for tests that need a destination session.
  def conformance_other_service
    @conformance_other_service ||= storage_class.new(session_id: conformance_session_id + 1)
  end

  # Random and wide so parallel workers do not collide on ids. Each test may
  # also use +1 for a second session, so the range leaves room for that.
  def conformance_session_id
    @conformance_session_id ||= rand(100_000_000..999_999_998)
  end

  def teardown_conformance_storage
    @conformance_service&.cleanup!
    @conformance_other_service&.cleanup!
  end

  # Set (or, with a nil value, unset) environment variables for the block and
  # restore whatever was there before — including "was not set at all".
  def with_conformance_env(vars)
    previous = vars.keys.to_h { |key| [ key, ENV[key] ] }
    vars.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
    yield
  ensure
    previous.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end
end
