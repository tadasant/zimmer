# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class WarmSkillsCacheJobTest < ActiveSupport::TestCase
  setup do
    # Tests need a working cache (test env uses :null_store by default)
    @original_cache_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache_store
  end

  test "job is enqueued in pollers queue" do
    assert_equal "pollers", WarmSkillsCacheJob.new.queue_name
  end

  test "job has concurrency control" do
    assert WarmSkillsCacheJob.good_job_concurrency_config.present?
  end

  test "skips when no clone is available for the agent root URL" do
    AirCatalogService.stub(:repo_root_for, ->(*) { nil }) do
      AgentRootsConfig.stub(:all, []) do
        WarmSkillsCacheJob.perform_now
      end
    end

    assert_equal [], ClaudeSkillsCacheService.get_for_agent_root("https://github.com/test/skip.git", nil)
  end

  test "caches repo-native skills for agent roots whose URL has a clone" do
    Dir.mktmpdir do |tmpdir|
      commands_dir = File.join(tmpdir, ".claude", "commands")
      FileUtils.mkdir_p(commands_dir)
      File.write(File.join(commands_dir, "my-command.md"), <<~MD)
        ---
        name: my-command
        description: A test command
        user-invocable: true
        ---
        # My Command
      MD

      repo_url = "https://github.com/test/repo.git"
      agent_root = AgentRootsConfig::AgentRoot.new("test-root", {
        "url" => repo_url,
        "subdirectory" => nil,
        "default_skills" => []
      })

      AirCatalogService.stub(:repo_root_for, ->(url:) { url == repo_url ? tmpdir : nil }) do
        AgentRootsConfig.stub(:all, [ agent_root ]) do
          WarmSkillsCacheJob.perform_now

          cached = ClaudeSkillsCacheService.get_for_agent_root(repo_url, nil)
          assert cached.any?, "Expected cached skills to be non-empty"
          command = cached.find { |s| s[:name] == "my-command" }
          assert command, "Expected to find my-command in cached skills"
          assert_equal "command", command[:type]
          assert_equal "A test command", command[:description]
        end
      end
    end
  end

  test "caches catalog default skills for agent roots" do
    Dir.mktmpdir do |tmpdir|
      skills_dir = File.join(tmpdir, "general", "test-skill")
      FileUtils.mkdir_p(skills_dir)
      File.write(File.join(skills_dir, "SKILL.md"), <<~MD)
        ---
        name: test-skill
        description: A test catalog skill
        user-invocable: true
        ---
        # Test Skill
      MD

      repo_url = "https://github.com/example/other-repo.git"
      agent_root = AgentRootsConfig::AgentRoot.new("test-root", {
        "url" => repo_url,
        "subdirectory" => nil,
        "default_skills" => [ "test-skill" ]
      })

      skill_config = SkillsConfig::Skill.new("test-skill", {
        "description" => "A test catalog skill",
        "path" => skills_dir
      })

      AirCatalogService.stub(:repo_root_for, ->(*) { nil }) do
        SkillsConfig.stub(:find, ->(name) { name == "test-skill" ? skill_config : nil }) do
          AgentRootsConfig.stub(:all, [ agent_root ]) do
            WarmSkillsCacheJob.perform_now

            cached = ClaudeSkillsCacheService.get_for_agent_root(repo_url, nil)
            assert cached.any?, "Expected cached skills to be non-empty"
            skill = cached.find { |s| s[:name] == "test-skill" }
            assert skill, "Expected to find test-skill in cached skills"
            assert_equal "skill", skill[:type]
            assert_equal true, skill[:user_invocable]
          end
        end
      end
    end
  end

  test "combines repo-native and catalog skills with repo-native priority" do
    Dir.mktmpdir do |tmpdir|
      skills_dir = File.join(tmpdir, ".claude", "skills", "overlapping-skill")
      FileUtils.mkdir_p(skills_dir)
      File.write(File.join(skills_dir, "SKILL.md"), <<~MD)
        ---
        name: overlapping-skill
        description: Repo-native version
        user-invocable: true
        ---
        # Overlapping Skill (repo)
      MD

      Dir.mktmpdir do |catalog_dir|
        catalog_skill_dir = File.join(catalog_dir, "general", "overlapping-skill")
        FileUtils.mkdir_p(catalog_skill_dir)
        File.write(File.join(catalog_skill_dir, "SKILL.md"), <<~MD)
          ---
          name: overlapping-skill
          description: Catalog version
          user-invocable: false
          ---
          # Overlapping Skill (catalog)
        MD

        repo_url = "https://github.com/test/repo.git"
        agent_root = AgentRootsConfig::AgentRoot.new("test-root", {
          "url" => repo_url,
          "subdirectory" => nil,
          "default_skills" => [ "overlapping-skill" ]
        })

        skill_config = SkillsConfig::Skill.new("overlapping-skill", {
          "description" => "Catalog version",
          "path" => catalog_skill_dir
        })

        AirCatalogService.stub(:repo_root_for, ->(url:) { url == repo_url ? tmpdir : nil }) do
          SkillsConfig.stub(:find, ->(name) { name == "overlapping-skill" ? skill_config : nil }) do
            AgentRootsConfig.stub(:all, [ agent_root ]) do
              WarmSkillsCacheJob.perform_now

              cached = ClaudeSkillsCacheService.get_for_agent_root(repo_url, nil)
              overlapping = cached.select { |s| s[:name] == "overlapping-skill" }
              assert_equal 1, overlapping.size, "Expected exactly one overlapping-skill (deduplicated)"
              assert_equal "Repo-native version", overlapping.first[:description], "Repo-native should take priority"
            end
          end
        end
      end
    end
  end

  test "skips custom agent roots" do
    agent_root = AgentRootsConfig::AgentRoot.new("custom", {
      "url" => "https://github.com/example/repo.git",
      "custom" => true,
      "default_skills" => []
    })

    AgentRootsConfig.stub(:all, [ agent_root ]) do
      WarmSkillsCacheJob.perform_now

      cached = ClaudeSkillsCacheService.get_for_agent_root("https://github.com/example/repo.git", nil)
      assert_equal [], cached
    end
  end

  test "skips agent roots with blank URL" do
    agent_root = AgentRootsConfig::AgentRoot.new("blank-url", {
      "url" => "",
      "default_skills" => []
    })

    AgentRootsConfig.stub(:all, [ agent_root ]) do
      WarmSkillsCacheJob.perform_now

      cached = ClaudeSkillsCacheService.get_for_agent_root("", nil)
      assert_equal [], cached
    end
  end

  test "handles subdirectory agent roots" do
    Dir.mktmpdir do |tmpdir|
      subdir = File.join(tmpdir, "my-subdir")
      commands_dir = File.join(subdir, ".claude", "commands")
      FileUtils.mkdir_p(commands_dir)
      File.write(File.join(commands_dir, "sub-command.md"), <<~MD)
        ---
        name: sub-command
        description: Subdirectory command
        ---
        # Sub Command
      MD

      repo_url = "https://github.com/test/repo.git"
      agent_root = AgentRootsConfig::AgentRoot.new("subdir-root", {
        "url" => repo_url,
        "subdirectory" => "my-subdir",
        "default_skills" => []
      })

      AirCatalogService.stub(:repo_root_for, ->(url:) { url == repo_url ? tmpdir : nil }) do
        AgentRootsConfig.stub(:all, [ agent_root ]) do
          WarmSkillsCacheJob.perform_now

          cached = ClaudeSkillsCacheService.get_for_agent_root(repo_url, "my-subdir")
          assert cached.any?, "Expected cached skills for subdirectory agent root"
          assert cached.any? { |s| s[:name] == "sub-command" }
        end
      end
    end
  end

  test "continues processing after individual agent root failure" do
    Dir.mktmpdir do |tmpdir|
      skills_dir = File.join(tmpdir, "general", "good-skill")
      FileUtils.mkdir_p(skills_dir)
      File.write(File.join(skills_dir, "SKILL.md"), <<~MD)
        ---
        name: good-skill
        description: A working skill
        user-invocable: true
        ---
        # Good Skill
      MD

      bad_root = AgentRootsConfig::AgentRoot.new("bad-root", {
        "url" => "https://github.com/example/bad-repo.git",
        "subdirectory" => nil,
        "default_skills" => [ "good-skill" ]
      })

      good_root = AgentRootsConfig::AgentRoot.new("good-root", {
        "url" => "https://github.com/example/good-repo.git",
        "subdirectory" => nil,
        "default_skills" => [ "good-skill" ]
      })

      skill_config = SkillsConfig::Skill.new("good-skill", {
        "description" => "A working skill",
        "path" => skills_dir
      })

      call_count = 0
      original_cache_method = ClaudeSkillsCacheService.method(:cache_for_agent_root)

      AirCatalogService.stub(:repo_root_for, ->(*) { nil }) do
        SkillsConfig.stub(:find, ->(name) { name == "good-skill" ? skill_config : nil }) do
          ClaudeSkillsCacheService.stub(:cache_for_agent_root, ->(*args) {
            call_count += 1
            raise "Simulated failure" if call_count == 1
            original_cache_method.call(*args)
          }) do
            AgentRootsConfig.stub(:all, [ bad_root, good_root ]) do
              WarmSkillsCacheJob.perform_now
            end
          end
        end
      end

      cached = ClaudeSkillsCacheService.get_for_agent_root("https://github.com/example/good-repo.git", nil)
      assert cached.any?, "Expected good root to have cached skills despite bad root failure"
      assert cached.any? { |s| s[:name] == "good-skill" }
    end
  end

  test "skips repo-native discovery for URLs without a cached clone" do
    agent_root = AgentRootsConfig::AgentRoot.new("external-root", {
      "url" => "https://github.com/example/external-repo.git",
      "subdirectory" => nil,
      "default_skills" => []
    })

    AirCatalogService.stub(:repo_root_for, ->(*) { nil }) do
      AgentRootsConfig.stub(:all, [ agent_root ]) do
        WarmSkillsCacheJob.perform_now

        cached = ClaudeSkillsCacheService.get_for_agent_root("https://github.com/example/external-repo.git", nil)
        assert_equal [], cached
      end
    end
  end
end
