# frozen_string_literal: true

require "test_helper"
require "open3"
require "shellwords"

module Execution
  module Support
    class CommandBuilderTest < ActiveSupport::TestCase
      test "builds basic command with prompt and working directory" do
        builder = CommandBuilder.new(
          prompt: "Test prompt",
          working_dir: "/tmp/test"
        )

        command = builder.build
        assert_includes command, "claude"
        assert_includes command, "--working-directory"
        assert_includes command, "/tmp/test"
        assert_includes command, "--prompt"
        # Shellwords.escape escapes spaces, so check for escaped version
        assert_includes command, "Test\\ prompt"
      end

      test "includes mcp config if provided" do
        builder = CommandBuilder.new(
          prompt: "Test prompt",
          working_dir: "/tmp/test",
          mcp_config_path: "/tmp/test/.mcp.json"
        )

        command = builder.build
        assert_includes command, "--config"
        assert_includes command, "/tmp/test/.mcp.json"
      end

      test "includes model if provided in options" do
        builder = CommandBuilder.new(
          prompt: "Test prompt",
          working_dir: "/tmp/test",
          options: { model: "claude-sonnet-4" }
        )

        command = builder.build
        assert_includes command, "--model"
        assert_includes command, "claude-sonnet-4"
      end

      test "includes api key if provided in options" do
        builder = CommandBuilder.new(
          prompt: "Test prompt",
          working_dir: "/tmp/test",
          options: { api_key: "sk-test-123" }
        )

        command = builder.build
        assert_includes command, "--api-key"
        assert_includes command, "sk-test-123"
      end

      test "properly escapes shell arguments" do
        builder = CommandBuilder.new(
          prompt: "Test prompt with 'quotes' and $special",
          working_dir: "/tmp/test with spaces"
        )

        command = builder.build
        # Shellwords.escape should be applied
        assert_kind_of String, command
        refute_includes command, "'; rm -rf /" # Basic injection check
      end

      test "build_array returns command as array" do
        builder = CommandBuilder.new(
          prompt: "Test prompt",
          working_dir: "/tmp/test"
        )

        array = builder.build_array
        assert_kind_of Array, array
        assert_equal "claude", array.first
        assert_includes array, "--working-directory"
        assert_includes array, "/tmp/test"
        assert_includes array, "--prompt"
        assert_includes array, "Test prompt"
      end

      test "build_env includes timeout if specified" do
        builder = CommandBuilder.new(
          prompt: "Test prompt",
          working_dir: "/tmp/test",
          options: { timeout: 300 }
        )

        env = builder.build_env
        assert_equal "300", env["CLAUDE_CODE_TIMEOUT"]
      end

      test "build_env includes api key if not passed as arg" do
        builder = CommandBuilder.new(
          prompt: "Test prompt",
          working_dir: "/tmp/test",
          options: { api_key: "sk-test-123", api_key_as_arg: false }
        )

        env = builder.build_env
        assert_equal "sk-test-123", env["ANTHROPIC_API_KEY"]
      end

      test "spawn_options includes working directory" do
        builder = CommandBuilder.new(
          prompt: "Test prompt",
          working_dir: "/tmp/test"
        )

        opts = builder.spawn_options
        assert_equal "/tmp/test", opts[:chdir]
      end

      test "spawn_options includes timeout if specified" do
        builder = CommandBuilder.new(
          prompt: "Test prompt",
          working_dir: "/tmp/test",
          options: { timeout: 300 }
        )

        opts = builder.spawn_options
        assert_equal 300, opts[:timeout]
      end

      test "raises error if prompt is empty" do
        assert_raises(CommandBuilder::ValidationError) do
          CommandBuilder.new(
            prompt: "",
            working_dir: "/tmp/test"
          )
        end
      end

      test "raises error if working_dir is empty" do
        assert_raises(CommandBuilder::ValidationError) do
          CommandBuilder.new(
            prompt: "Test prompt",
            working_dir: ""
          )
        end
      end

      test "raises error if working_dir is not absolute" do
        assert_raises(CommandBuilder::ValidationError) do
          CommandBuilder.new(
            prompt: "Test prompt",
            working_dir: "relative/path"
          )
        end
      end

      test "raises error if mcp_config_path is not absolute" do
        assert_raises(CommandBuilder::ValidationError) do
          CommandBuilder.new(
            prompt: "Test prompt",
            working_dir: "/tmp/test",
            mcp_config_path: "relative/.mcp.json"
          )
        end
      end

      test "raises error if timeout is not positive" do
        assert_raises(CommandBuilder::ValidationError) do
          CommandBuilder.new(
            prompt: "Test prompt",
            working_dir: "/tmp/test",
            options: { timeout: 0 }
          )
        end
      end

      test "raises error if timeout is negative" do
        assert_raises(CommandBuilder::ValidationError) do
          CommandBuilder.new(
            prompt: "Test prompt",
            working_dir: "/tmp/test",
            options: { timeout: -30 }
          )
        end
      end

      test "raises error if prompt is only whitespace" do
        assert_raises(CommandBuilder::ValidationError) do
          CommandBuilder.new(prompt: "   \n\t ", working_dir: "/tmp/test")
        end
      end

      test "raises error if prompt is nil" do
        assert_raises(CommandBuilder::ValidationError) do
          CommandBuilder.new(prompt: nil, working_dir: "/tmp/test")
        end
      end

      test "raises error if working_dir is nil" do
        assert_raises(CommandBuilder::ValidationError) do
          CommandBuilder.new(prompt: "Test prompt", working_dir: nil)
        end
      end

      # ====================================================================
      # Shell safety
      #
      # This class is the only thing standing between a user-authored prompt
      # and a shell command, so its escaping is pinned by round-tripping the
      # built string back through a shell parser: if `Shellwords.split` (the
      # same grammar /bin/sh uses for word splitting) recovers exactly the
      # arguments that went in, no metacharacter escaped its quoting.
      # ====================================================================

      HOSTILE_PROMPTS = {
        "command chaining" => "hello; rm -rf /",
        "backticks" => "hello `rm -rf /`",
        "command substitution" => "hello $(rm -rf /)",
        "variable expansion" => "hello $HOME and ${PATH}",
        "pipes and redirects" => "hello | tee /etc/passwd > /dev/null",
        "boolean operators" => "hello && curl evil.example.com || true",
        "single quotes" => "it's a 'quoted' prompt",
        "double quotes" => 'say "hello" loudly',
        "newlines" => "line one\nrm -rf /\nline three",
        "backslashes" => 'C:\\path\\to\\thing and a trailing \\',
        "null-ish unicode" => "emoji 🙂 and ünïcödé",
        "glob characters" => "match * and ? and [a-z]"
      }.freeze

      HOSTILE_PROMPTS.each do |label, hostile|
        test "build round-trips a prompt containing #{label} through a shell parser" do
          builder = CommandBuilder.new(prompt: hostile, working_dir: "/tmp/test")

          tokens = Shellwords.split(builder.build)

          assert_equal [ "claude", "--working-directory", "/tmp/test", "--prompt", hostile ], tokens
        end
      end

      test "build round-trips a working_dir containing spaces and metacharacters" do
        hostile_dir = "/tmp/dir with spaces/$(whoami)"
        builder = CommandBuilder.new(prompt: "safe", working_dir: hostile_dir)

        tokens = Shellwords.split(builder.build)

        assert_equal hostile_dir, tokens[tokens.index("--working-directory") + 1]
      end

      test "build round-trips every escaped field at once" do
        builder = CommandBuilder.new(
          prompt: "p; rm -rf /",
          working_dir: "/tmp/w d",
          mcp_config_path: "/tmp/m d/.mcp.json",
          options: { model: "m`id`", api_key: "sk-$(id)" }
        )

        assert_equal(
          [
            "claude",
            "--working-directory", "/tmp/w d",
            "--config", "/tmp/m d/.mcp.json",
            "--model", "m`id`",
            "--api-key", "sk-$(id)",
            "--prompt", "p; rm -rf /"
          ],
          Shellwords.split(builder.build)
        )
      end

      test "a shell executing the built command does not evaluate an injected substitution" do
        # The strongest available form of the assertion above: hand the built
        # string to a real /bin/sh (with `claude` swapped for `echo`, which is
        # all that stops this from needing the CLI installed) and prove the
        # canary the prompt tries to create never appears.
        canary = File.join(Dir.tmpdir, "command-builder-canary-#{SecureRandom.hex(8)}")
        builder = CommandBuilder.new(
          prompt: "please $(touch #{canary}) and `touch #{canary}`",
          working_dir: "/tmp/test"
        )

        command = builder.build.sub(/\Aclaude\b/, "printf '%s\\n'")
        stdout, _stderr, status = Open3.capture3("/bin/sh", "-c", command)

        assert status.success?, "expected the rewritten command to run"
        assert_not File.exist?(canary), "the shell evaluated an injected command substitution"
        assert_includes stdout, "$(touch #{canary})", "the prompt should reach the CLI verbatim"
      ensure
        FileUtils.rm_f(canary) if canary
      end

      test "build_array passes values through verbatim" do
        # build_array is what LocalFilesystem actually executes, via
        # Open3.capture3(*array) — which execs directly with no shell. Escaping
        # there would be a bug: the CLI would receive literal backslashes.
        hostile = "hello; rm -rf / $(id) `id`"
        builder = CommandBuilder.new(
          prompt: hostile,
          working_dir: "/tmp/test",
          mcp_config_path: "/tmp/.mcp.json",
          options: { model: "m odel", api_key: "sk-1" }
        )

        assert_equal(
          [
            "claude",
            "--working-directory", "/tmp/test",
            "--config", "/tmp/.mcp.json",
            "--model", "m odel",
            "--api-key", "sk-1",
            "--prompt", hostile
          ],
          builder.build_array
        )
      end

      test "build omits optional flags that were not supplied" do
        command = CommandBuilder.new(prompt: "p", working_dir: "/tmp/test").build

        assert_not_includes command, "--config"
        assert_not_includes command, "--model"
        assert_not_includes command, "--api-key"
      end

      test "build_env omits the api key when it is passed as an argument" do
        builder = CommandBuilder.new(
          prompt: "p",
          working_dir: "/tmp/test",
          options: { api_key: "sk-secret", api_key_as_arg: true }
        )

        assert_not builder.build_env.key?("ANTHROPIC_API_KEY")
      end

      test "build_env is empty when no options are supplied" do
        assert_empty CommandBuilder.new(prompt: "p", working_dir: "/tmp/test").build_env
      end

      test "spawn_options omits timeout when not supplied" do
        opts = CommandBuilder.new(prompt: "p", working_dir: "/tmp/test").spawn_options

        assert_equal "/tmp/test", opts[:chdir]
        assert_not opts.key?(:timeout)
      end

      test "accepts a nil mcp_config_path" do
        builder = CommandBuilder.new(prompt: "p", working_dir: "/tmp/test", mcp_config_path: nil)

        assert_not_includes builder.build_array, "--config"
      end
    end
  end
end
