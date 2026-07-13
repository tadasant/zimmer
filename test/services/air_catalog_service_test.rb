# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class AirCatalogServiceTest < ActiveSupport::TestCase
  setup do
    @original_air_path = Rails.application.config.air_json_path
    @tmpdir = Dir.mktmpdir
    @air_json = File.join(@tmpdir, "air.json")
    File.write(@air_json, "{}")
    Rails.application.config.air_json_path = @air_json
    # Use this test file itself as a stand-in for the AIR binary so the
    # File.exist? preflight check passes without requiring a real install.
    @fake_binary = __FILE__
    AirCatalogService.reset!
    # Persisted snapshots are last-known-good fallback state; clear them so each
    # test controls the table explicitly (a real catalog can be persisted by
    # any test that resolves it, or by app boot outside the test transaction).
    CatalogSnapshot.delete_all
  end

  teardown do
    Rails.application.config.air_json_path = @original_air_path
    AirCatalogService.reset!
    FileUtils.rm_rf(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
  end

  # Tests here deliberately stub Open3.capture3 to simulate various air resolve /
  # air update failure modes. Without disabling the lazy-install bootstrap,
  # AirPrepareService.ensure_air_installed!'s own capture3 calls (npm install,
  # --version health check) would also get stubbed and produce confusing
  # "AIR CLI installation failed" errors. This helper wraps a test block with
  # install stubbed to a no-op so Open3 stubs only affect air resolve / update.
  def without_install_bootstrap(&block)
    AirPrepareService.stub(:ensure_air_installed!, nil, &block)
  end

  test "entries_for returns flat {id => entry} hash from air resolve output" do
    with_air_resolve(
      "skills" => {
        "alpha" => { "id" => "alpha", "description" => "alpha skill", "path" => "/abs/alpha/dir" }
      },
      "hooks" => {}
    ) do
      skills = AirCatalogService.entries_for(:skills)
      assert_equal [ "alpha" ], skills.keys
      assert_equal "alpha skill", skills["alpha"]["description"]
      assert_equal "/abs/alpha/dir", skills["alpha"]["path"]

      assert_equal({}, AirCatalogService.entries_for(:hooks))
    end
  end

  test "entries_for returns empty hash when air resolve returns no entries for type" do
    with_air_resolve({}) do
      assert_equal({}, AirCatalogService.entries_for(:skills))
      assert_equal({}, AirCatalogService.entries_for(:mcp))
      assert_equal({}, AirCatalogService.entries_for(:plugins))
    end
  end

  test "ignores non-hash entries defensively" do
    with_air_resolve(
      "skills" => {
        "good" => { "description" => "ok" },
        "bogus" => "not a hash"
      }
    ) do
      skills = AirCatalogService.entries_for(:skills)
      assert_equal [ "good" ], skills.keys
    end
  end

  test "invokes air resolve with --no-scope so AIR returns shortname-keyed output" do
    captured_args = nil
    without_install_bootstrap do
      AirCatalogService.stub(:air_binary, @fake_binary) do
        Open3.stub(:capture3, ->(_env, _bin, *args) {
          captured_args = args
          [ JSON.generate("skills" => {}), "", fake_status(0) ]
        }) do
          AirCatalogService.entries_for(:skills)
        end
      end
    end

    assert_includes captured_args, "--no-scope"
    assert_equal %w[resolve --json --no-scope --git-protocol https], captured_args
  end

  test "passes shortname-keyed entries through unchanged (AIR 0.1.1 --no-scope owns scope stripping)" do
    with_air_resolve(
      "roots" => {
        "general-agent" => {
          "name" => "general-agent",
          "default_skills" => %w[skill-a skill-b],
          "default_mcp_servers" => %w[mcp-x],
          "default_subagent_roots" => %w[sub-root]
        }
      },
      "skills" => {
        "skill-c" => {
          "references" => %w[some-ref]
        }
      },
      "plugins" => {
        "my-plugin" => {
          "skills" => %w[skill-a],
          "mcp_servers" => %w[mcp-x],
          "hooks" => %w[hook-y]
        }
      }
    ) do
      root = AirCatalogService.entries_for(:roots)["general-agent"]
      assert_equal %w[skill-a skill-b], root["default_skills"]
      assert_equal %w[mcp-x], root["default_mcp_servers"]
      assert_equal %w[sub-root], root["default_subagent_roots"]

      skill = AirCatalogService.entries_for(:skills)["skill-c"]
      assert_equal %w[some-ref], skill["references"]

      plugin = AirCatalogService.entries_for(:plugins)["my-plugin"]
      assert_equal %w[skill-a], plugin["skills"]
      assert_equal %w[mcp-x], plugin["mcp_servers"]
      assert_equal %w[hook-y], plugin["hooks"]
    end
  end

  test "raises CatalogError when air.json missing on refresh!" do
    Rails.application.config.air_json_path = File.join(@tmpdir, "does-not-exist.json")
    AirCatalogService.reset!

    assert_raises(AirCatalogService::CatalogError) do
      AirCatalogService.refresh!
    end
  end

  test "raises CatalogError when AIR CLI installation fails" do
    AirPrepareService.stub(:ensure_air_installed!, ->(*) { raise AirPrepareService::AirPrepareError, "install blew up" }) do
      error = assert_raises(AirCatalogService::CatalogError) do
        AirCatalogService.entries_for(:skills)
      end
      assert_match(/AIR CLI installation failed/, error.message)
    end
  end

  test "raises CatalogError when air resolve exits non-zero" do
    without_install_bootstrap do
      AirCatalogService.stub(:air_binary, @fake_binary) do
        Open3.stub(:capture3, ->(*) { [ "", "boom", fake_status(1) ] }) do
          error = assert_raises(AirCatalogService::CatalogError) do
            AirCatalogService.entries_for(:skills)
          end
          assert_match(/air resolve failed/, error.message)
        end
      end
    end
  end

  test "raises CatalogError when air resolve emits invalid JSON" do
    without_install_bootstrap do
      AirCatalogService.stub(:air_binary, @fake_binary) do
        Open3.stub(:capture3, ->(*) { [ "not json", "", fake_status(0) ] }) do
          error = assert_raises(AirCatalogService::CatalogError) do
            AirCatalogService.entries_for(:skills)
          end
          assert_match(/Invalid JSON from air resolve/, error.message)
        end
      end
    end
  end

  test "refresh! calls air update then reloads" do
    update_called = false
    calls = ->(env, bin, *args) do
      if args.first == "update"
        update_called = true
        [ "updated\n", "", fake_status(0) ]
      else
        [ JSON.generate("skills" => { "post" => { "description" => "after update" } }), "", fake_status(0) ]
      end
    end

    without_install_bootstrap do
      AirCatalogService.stub(:air_binary, @fake_binary) do
        Open3.stub(:capture3, calls) do
          AirCatalogService.refresh!
          assert update_called, "air update should have been invoked"
          skills = AirCatalogService.entries_for(:skills)
          assert_equal [ "post" ], skills.keys
        end
      end
    end
  end

  test "refresh! raises when air update exits non-zero" do
    without_install_bootstrap do
      AirCatalogService.stub(:air_binary, @fake_binary) do
        Open3.stub(:capture3, ->(*) { [ "", "update failed", fake_status(2) ] }) do
          error = assert_raises(AirCatalogService::CatalogError) do
            AirCatalogService.refresh!
          end
          assert_match(/air update failed/, error.message)
        end
      end
    end
  end

  test "repo_root_for returns nil when cache dir missing" do
    with_github_cache_dir(File.join(@tmpdir, "missing-cache")) do
      assert_nil AirCatalogService.repo_root_for(url: "https://github.com/foo/bar.git")
    end
  end

  test "repo_root_for returns nil for blank url" do
    assert_nil AirCatalogService.repo_root_for(url: "")
    assert_nil AirCatalogService.repo_root_for(url: nil)
  end

  test "repo_root_for prefers HEAD directory for matching repo" do
    cache_dir = File.join(@tmpdir, "cache")
    head_clone = File.join(cache_dir, "foo", "bar", "HEAD")
    FileUtils.mkdir_p(File.join(head_clone, ".git"))

    with_github_cache_dir(cache_dir) do
      assert_equal head_clone, AirCatalogService.repo_root_for(url: "https://github.com/foo/bar.git")
    end
  end

  test "repo_root_for falls back to any clone with .git when HEAD absent" do
    cache_dir = File.join(@tmpdir, "cache")
    ref_clone = File.join(cache_dir, "foo", "bar", "mybranch")
    FileUtils.mkdir_p(File.join(ref_clone, ".git"))

    with_github_cache_dir(cache_dir) do
      assert_equal ref_clone, AirCatalogService.repo_root_for(url: "https://github.com/foo/bar.git")
    end
  end

  test "repo_root_for tolerates URLs with trailing slashes and missing .git suffix" do
    cache_dir = File.join(@tmpdir, "cache")
    head_clone = File.join(cache_dir, "foo", "bar", "HEAD")
    FileUtils.mkdir_p(File.join(head_clone, ".git"))

    with_github_cache_dir(cache_dir) do
      assert_equal head_clone, AirCatalogService.repo_root_for(url: "https://github.com/foo/bar/")
      assert_equal head_clone, AirCatalogService.repo_root_for(url: "https://github.com/foo/bar")
      assert_equal head_clone, AirCatalogService.repo_root_for(url: "https://github.com/FOO/BAR.git")
    end
  end

  test "air_json_path comes from Rails config" do
    Rails.application.config.air_json_path = "/tmp/custom-air.json"
    assert_equal "/tmp/custom-air.json", AirCatalogService.air_json_path
    assert_equal "/tmp", AirCatalogService.air_json_dir
  end

  test "reload! clears the TTL cache" do
    without_install_bootstrap do
      AirCatalogService.stub(:air_binary, @fake_binary) do
        first = ->(*) { [ JSON.generate("skills" => { "first" => {} }), "", fake_status(0) ] }
        Open3.stub(:capture3, first) do
          assert_equal [ "first" ], AirCatalogService.entries_for(:skills).keys
        end

        second = ->(*) { [ JSON.generate("skills" => { "second" => {} }), "", fake_status(0) ] }
        Open3.stub(:capture3, second) do
          AirCatalogService.reload!
          assert_equal [ "second" ], AirCatalogService.entries_for(:skills).keys
        end
      end
    end
  end

  test "effective_air_json_path returns the base path when no pins exist" do
    assert_equal @air_json, AirCatalogService.effective_air_json_path
  end

  test "effective_air_json_path rewrites pinned catalogs to a generated file" do
    File.write(@air_json, JSON.generate("catalogs" => [ "github://pulsemcp/ai-artifacts" ]))
    CatalogPin.create!(catalog: "github://pulsemcp/ai-artifacts", ref: "abc123")
    AirCatalogService.reset!

    path = AirCatalogService.effective_air_json_path
    refute_equal @air_json, path

    parsed = JSON.parse(File.read(path))
    assert_equal "github://pulsemcp/ai-artifacts@abc123", parsed["catalogs"][0]
  end

  test "effective_air_json_path regenerates when the pin set changes" do
    File.write(@air_json, JSON.generate("catalogs" => [ "github://pulsemcp/ai-artifacts" ]))
    pin = CatalogPin.create!(catalog: "github://pulsemcp/ai-artifacts", ref: "aaa")
    AirCatalogService.reset!

    first = JSON.parse(File.read(AirCatalogService.effective_air_json_path))
    assert_equal "github://pulsemcp/ai-artifacts@aaa", first["catalogs"][0]

    pin.update!(ref: "bbb")
    second = JSON.parse(File.read(AirCatalogService.effective_air_json_path))
    assert_equal "github://pulsemcp/ai-artifacts@bbb", second["catalogs"][0]
  end

  # Regression for #4113: parallel test workers (and, in production, every web /
  # GoodJob process) share one filesystem. If the rewritten pin config were
  # written to a single fixed tmp/air.effective.json, two processes pinning
  # different refs would clobber each other's file and a reader could load a
  # config it didn't write. The generated path MUST stay process-unique.
  test "effective config path is process-unique to avoid cross-process file races" do
    path = AirCatalogService.send(:effective_config_path).to_s

    assert_includes path, "air.effective.#{Process.pid}.json",
      "effective config path must be keyed on Process.pid so parallel workers never share one file"
    refute_equal Rails.root.join("tmp", "air.effective.json").to_s, path,
      "must not use the shared fixed path that caused the #4113 race"
  end

  # Behavior-level guard for the same race: two processes pinning different refs
  # must end up writing to two DIFFERENT files, so neither clobbers the other.
  # Stub Process.pid to stand in for two separate workers and drive the real
  # write path (generate_effective_config), then assert both files coexist with
  # their own content. On the old fixed-path code both writes would land on one
  # file and the first worker's content would be lost.
  test "different processes write distinct effective config files that do not clobber each other" do
    base = File.join(@tmpdir, "base_air.json")
    File.write(base, JSON.generate("catalogs" => [ "github://pulsemcp/ai-artifacts" ]))

    path_a = path_b = nil
    Process.stub(:pid, 4111) do
      path_a = AirCatalogService.send(:generate_effective_config, base, { "github://pulsemcp/ai-artifacts" => "ref-a" })
    end
    Process.stub(:pid, 4222) do
      path_b = AirCatalogService.send(:generate_effective_config, base, { "github://pulsemcp/ai-artifacts" => "ref-b" })
    end

    begin
      refute_equal path_a, path_b, "two processes must not share one effective config file"
      assert File.exist?(path_a), "first worker's file must survive the second worker's write"
      assert File.exist?(path_b)
      assert_equal "github://pulsemcp/ai-artifacts@ref-a", JSON.parse(File.read(path_a))["catalogs"][0],
        "first worker's file must still hold its own ref (not clobbered by the second)"
      assert_equal "github://pulsemcp/ai-artifacts@ref-b", JSON.parse(File.read(path_b))["catalogs"][0]
    ensure
      [ path_a, path_b ].compact.each { |p| File.delete(p) if File.exist?(p) }
    end
  end

  test "pinnable_catalogs returns github prefixes and ignores local paths" do
    skip "Requires a remote (github://) catalog; Zimmer default catalog is local-only."
    File.write(@air_json, JSON.generate("catalogs" => [
      "github://tadasant/zimmer-catalog/agents",
      "github://tadasant/zimmer-catalog/artifacts",
      "github://pulsemcp/ai-artifacts",
      "../local/relative/path"
    ]))
    AirCatalogService.reset!

    assert_equal [
      "github://tadasant/zimmer-catalog",
      "github://tadasant/zimmer-catalog",
      "github://pulsemcp/ai-artifacts"
    ], AirCatalogService.pinnable_catalogs
  end

  test "resolved_sha_for reads the commit SHA from the cache clone" do
    skip "Requires a remote (github://) catalog; Zimmer default catalog is local-only."
    cache_dir = File.join(@tmpdir, "cache")
    clone = File.join(cache_dir, "zimmer", "ai-artifacts", "HEAD")
    FileUtils.mkdir_p(clone)
    system("git", "-C", clone, "init", "-q", exception: true)
    File.write(File.join(clone, "f.txt"), "x")
    system("git", "-C", clone, "add", ".", exception: true)
    system("git", "-C", clone, "-c", "user.email=t@t.co", "-c", "user.name=t", "commit", "-qm", "init", exception: true)

    with_github_cache_dir(cache_dir) do
      sha = AirCatalogService.resolved_sha_for("github://pulsemcp/ai-artifacts", ref: "HEAD")
      assert_match(/\A[0-9a-f]{40}\z/, sha)
    end
  end

  test "resolved_sha_for returns nil when the catalog is not cached" do
    with_github_cache_dir(File.join(@tmpdir, "no-cache")) do
      assert_nil AirCatalogService.resolved_sha_for("github://pulsemcp/ai-artifacts")
    end
  end

  # --- last-known-good resilience -------------------------------------------

  test "persists a last-known-good snapshot after a successful resolve" do
    assert_nil CatalogSnapshot.latest

    with_air_resolve("roots" => { "zimmer-router" => { "name" => "zimmer-router" } }) do
      AirCatalogService.entries_for(:roots)
    end

    snapshot = CatalogSnapshot.latest
    assert snapshot, "a snapshot should be persisted after a successful resolve"
    assert_equal({ "name" => "zimmer-router" }, snapshot.entries["roots"]["zimmer-router"])
    refute AirCatalogService.degraded?
  end

  test "serves the in-memory last-known-good catalog when a later resolve fails" do
    without_install_bootstrap do
      AirCatalogService.stub(:air_binary, @fake_binary) do
        ok = ->(*) { [ JSON.generate("roots" => { "zimmer-router" => { "name" => "zimmer-router" } }), "", fake_status(0) ] }
        Open3.stub(:capture3, ok) do
          assert_equal [ "zimmer-router" ], AirCatalogService.entries_for(:roots).keys
        end
        refute AirCatalogService.degraded?

        boom = ->(*) { [ "", "cross-scope shortname collision", fake_status(1) ] }
        Open3.stub(:capture3, boom) do
          AirCatalogService.reload! # forces a fresh resolve, which now fails

          assert_equal [ "zimmer-router" ], AirCatalogService.entries_for(:roots).keys,
            "zimmer-router must remain resolvable from the in-memory last-known-good catalog"
          assert AirCatalogService.degraded?
        end
      end
    end
  end

  test "serves the persisted last-known-good snapshot when resolve fails on a cold cache" do
    CatalogSnapshot.store!(roots: { "zimmer-router" => { "name" => "zimmer-router" } }, skills: {})
    AirCatalogService.reset! # cold process: nothing cached in memory

    without_install_bootstrap do
      AirCatalogService.stub(:air_binary, @fake_binary) do
        Open3.stub(:capture3, ->(*) { [ "", "cross-scope shortname collision", fake_status(1) ] }) do
          assert_equal [ "zimmer-router" ], AirCatalogService.entries_for(:roots).keys,
            "a freshly restarted process must recover zimmer-router from the persisted snapshot"
          assert AirCatalogService.degraded?
        end
      end
    end
  end

  test "still raises CatalogError when resolve fails and no last-known-good exists" do
    assert_nil CatalogSnapshot.latest

    without_install_bootstrap do
      AirCatalogService.stub(:air_binary, @fake_binary) do
        Open3.stub(:capture3, ->(*) { [ "", "boom", fake_status(1) ] }) do
          assert_raises(AirCatalogService::CatalogError) do
            AirCatalogService.entries_for(:roots)
          end
        end
      end
    end
  end

  test "clears degraded state and persists a fresh snapshot once resolution recovers" do
    CatalogSnapshot.store!(roots: { "stale" => { "name" => "stale" } })
    AirCatalogService.reset!

    without_install_bootstrap do
      AirCatalogService.stub(:air_binary, @fake_binary) do
        Open3.stub(:capture3, ->(*) { [ "", "boom", fake_status(1) ] }) do
          assert_equal [ "stale" ], AirCatalogService.entries_for(:roots).keys
          assert AirCatalogService.degraded?
        end

        fresh = ->(*) { [ JSON.generate("roots" => { "zimmer-router" => { "name" => "zimmer-router" } }), "", fake_status(0) ] }
        Open3.stub(:capture3, fresh) do
          AirCatalogService.reload!

          assert_equal [ "zimmer-router" ], AirCatalogService.entries_for(:roots).keys
          refute AirCatalogService.degraded?
        end
      end
    end

    assert_equal({ "name" => "zimmer-router" }, CatalogSnapshot.latest.entries["roots"]["zimmer-router"])
  end

  # --- structurally-incomplete resolve (exit 0 but references dropped) -------

  # AIR drops unresolvable references when a catalog source is stale/partial,
  # emitting "references unknown ... Dropping the reference" warnings while still
  # exiting 0. The dropped references strip affected roots' defaults (e.g.
  # zimmer-router's default_skills / _mcp_servers / _hooks), so the service must
  # treat such a resolve as failed.
  DROPPED_REF_STDERR = <<~STDERR
    warning: @local/zimmer-router.skills references unknown skill "zimmer-router-route-request". Available qualified IDs: @pulsemcp/ai-artifacts/foo, … (18 total). Dropping the reference.
    warning: @local/zimmer-router.skills references unknown skill "zimmer-router-select-agent-root". Available qualified IDs: @pulsemcp/ai-artifacts/foo, … (18 total). Dropping the reference.
  STDERR

  # AIR also drops references that resolve to an artifact intentionally removed by
  # air.json#exclude. This shares the "Dropping the reference." marker but is an
  # expected, author-intended configuration — NOT a degraded catalog — so it must
  # not be treated as a failed resolve.
  EXCLUDE_DROP_STDERR = <<~STDERR
    warning: @local/some-root.hooks references hook "agent-transcript-capture", which is removed by air.json#exclude (@pulsemcp/ai-artifacts/agent-transcript-capture). Dropping the reference.
  STDERR

  test "treats a resolve that exits 0 but drops references as failed, serving last-known-good" do
    without_install_bootstrap do
      AirCatalogService.stub(:air_binary, @fake_binary) do
        healthy_root = { "name" => "zimmer-router", "default_skills" => %w[zimmer-router-route-request], "default_mcp_servers" => %w[zimmer] }
        ok = ->(*) { [ JSON.generate("roots" => { "zimmer-router" => healthy_root }), "", fake_status(0) ] }
        Open3.stub(:capture3, ok) do
          assert_equal healthy_root, AirCatalogService.entries_for(:roots)["zimmer-router"]
        end
        refute AirCatalogService.degraded?

        # A later resolve exits 0 but drops the references that populate the
        # root's defaults. The roots key is still present but stripped of defaults.
        stripped = ->(*) { [ JSON.generate("roots" => { "zimmer-router" => { "name" => "zimmer-router" } }), DROPPED_REF_STDERR, fake_status(0) ] }
        Open3.stub(:capture3, stripped) do
          AirCatalogService.reload!

          root = AirCatalogService.entries_for(:roots)["zimmer-router"]
          assert_equal %w[zimmer-router-route-request], root["default_skills"],
            "zimmer-router defaults must survive from the last-known-good catalog, not the stripped resolve"
          assert AirCatalogService.degraded?
        end
      end
    end

    # The poisoned tree must NOT overwrite the good snapshot.
    assert_equal %w[zimmer-router-route-request],
      CatalogSnapshot.latest.entries["roots"]["zimmer-router"]["default_skills"],
      "the persisted snapshot must retain the healthy defaults, not the stripped resolve"
  end

  test "raises CatalogError when references are dropped and no last-known-good exists" do
    assert_nil CatalogSnapshot.latest

    without_install_bootstrap do
      AirCatalogService.stub(:air_binary, @fake_binary) do
        stripped = ->(*) { [ JSON.generate("roots" => { "zimmer-router" => { "name" => "zimmer-router" } }), DROPPED_REF_STDERR, fake_status(0) ] }
        Open3.stub(:capture3, stripped) do
          error = assert_raises(AirCatalogService::CatalogError) do
            AirCatalogService.entries_for(:roots)
          end
          assert_match(/dropped .* unresolvable reference/, error.message)
        end
      end
    end
  end

  test "benign stderr without dropped-reference warnings is served normally" do
    without_install_bootstrap do
      AirCatalogService.stub(:air_binary, @fake_binary) do
        # Non-marker stderr (e.g. an informational note) must not be mistaken for
        # an incomplete resolve.
        noisy = ->(*) { [ JSON.generate("roots" => { "zimmer-router" => { "name" => "zimmer-router" } }), "note: using cached provider data\n", fake_status(0) ] }
        Open3.stub(:capture3, noisy) do
          assert_equal [ "zimmer-router" ], AirCatalogService.entries_for(:roots).keys
          refute AirCatalogService.degraded?
        end
      end
    end
  end

  test "references dropped by air.json#exclude are intentional and served normally" do
    without_install_bootstrap do
      AirCatalogService.stub(:air_binary, @fake_binary) do
        # The exclude-driven drop shares the "Dropping the reference." marker but
        # is an author-intended configuration, so it must not degrade the catalog.
        excluded = ->(*) { [ JSON.generate("roots" => { "zimmer-router" => { "name" => "zimmer-router" } }), EXCLUDE_DROP_STDERR, fake_status(0) ] }
        Open3.stub(:capture3, excluded) do
          assert_equal [ "zimmer-router" ], AirCatalogService.entries_for(:roots).keys
          refute AirCatalogService.degraded?
        end
      end
    end
  end

  test "an unknown-reference drop trips even when mixed with an intentional exclude drop" do
    without_install_bootstrap do
      AirCatalogService.stub(:air_binary, @fake_binary) do
        mixed = ->(*) { [ JSON.generate("roots" => { "zimmer-router" => { "name" => "zimmer-router" } }), EXCLUDE_DROP_STDERR + DROPPED_REF_STDERR, fake_status(0) ] }
        Open3.stub(:capture3, mixed) do
          error = assert_raises(AirCatalogService::CatalogError) do
            AirCatalogService.entries_for(:roots)
          end
          assert_match(/dropped .* unresolvable reference/, error.message)
        end
      end
    end
  end

  private

  def with_air_resolve(parsed)
    without_install_bootstrap do
      AirCatalogService.stub(:air_binary, @fake_binary) do
        Open3.stub(:capture3, ->(*) { [ JSON.generate(parsed), "", fake_status(0) ] }) do
          yield
        end
      end
    end
  end

  def fake_status(code)
    Struct.new(:exitstatus, :success?).new(code, code.zero?)
  end

  def with_github_cache_dir(value)
    original = AirCatalogService.const_get(:GITHUB_CACHE_DIR)
    AirCatalogService.send(:remove_const, :GITHUB_CACHE_DIR)
    AirCatalogService.const_set(:GITHUB_CACHE_DIR, value)
    yield
  ensure
    AirCatalogService.send(:remove_const, :GITHUB_CACHE_DIR)
    AirCatalogService.const_set(:GITHUB_CACHE_DIR, original)
  end
end
