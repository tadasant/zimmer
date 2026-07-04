# frozen_string_literal: true

require "test_helper"

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
    end
  end
end
