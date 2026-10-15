# frozen_string_literal: true

require "shellwords"

module WarmProcessPool
  # One idle Claude Code process the pool holds, and the channel to it.
  #
  # The process reads stream-json from a pipe whose write end this object holds
  # (`stdin`), and writes stream-json to a file (`stdout_path`). Nothing is said
  # to it until a claim: control requests are answered without a model call, and
  # the first `user` message is the session's own prompt. Closing `stdin` after
  # that message is what makes it finish the turn and exit, as a cold `-p` start
  # does.
  #
  # Not thread-safe on its own. The pool hands an entry to exactly one caller at
  # a time — a claim, or the refill's health probe — by taking it out of the
  # registry first, so two writers never interleave on one pipe.
  class Entry
    # Something about the session or the process means this entry cannot serve
    # it. The claim falls back to a cold spawn and records `reason`.
    class Mismatch < StandardError
      attr_reader :reason

      def initialize(reason, message = reason)
        @reason = reason
        super(message)
      end
    end

    # A control request was refused, or went unanswered.
    class ControlError < StandardError; end

    CONTROL_POLL_SECONDS = 0.02

    attr_reader :id, :pid, :identity, :dir, :clone_path, :working_directory, :subdirectory,
                :claude_session_id, :model, :config_signature, :environment_key, :account,
                :boot_servers, :env_digest, :claude_dir_digest, :catalog_digest, :head, :created_at,
                :stdout_path, :stderr_log_path, :timings
    attr_accessor :state

    def initialize(id:, pid:, stdin:, dir:, clone_path:, working_directory:, subdirectory:, claude_session_id:,
                   model:, config_signature:, environment_key:, account:, boot_servers:, env_digest:,
                   claude_dir_digest:, catalog_digest:, head:, stdout_path:, stderr_log_path:, created_at: Time.current)
      @id = id
      @pid = pid
      @stdin = stdin
      @dir = dir
      @clone_path = clone_path
      @working_directory = working_directory
      @subdirectory = subdirectory
      @claude_session_id = claude_session_id
      @model = model
      @config_signature = config_signature
      @environment_key = environment_key
      @account = account
      @boot_servers = boot_servers
      @env_digest = env_digest
      @claude_dir_digest = claude_dir_digest
      @catalog_digest = catalog_digest
      @head = head
      @stdout_path = stdout_path
      @stderr_log_path = stderr_log_path
      @created_at = created_at
      @identity = AgentProcessLiveness.identity_for(pid)
      @stdout_offset = 0
      @request_seq = 0
      @timings = {}
      @state = :booting
    end

    def age_seconds(now = Time.current)
      (now - created_at).to_i
    end

    # Whether the process is still running. A dead child is reaped here, and one
    # the zombie reaper got to first is just as dead. Once reaped, its pid is
    # free for the kernel to hand out again, so nothing here signals it after.
    def alive?
      return false if @reaped

      if Process.waitpid(pid, Process::WNOHANG)
        mark_reaped
        return false
      end

      AgentProcessLiveness.classify(identity) == :alive
    rescue Errno::ECHILD
      mark_reaped
      false
    end

    # The `mcp_status` control request: one entry per server, each `pending`,
    # `connected` or `failed`. Answered locally, without a model call.
    #
    # @return [Array<Hash>]
    def mcp_status(timeout:)
      Array(request!("mcp_status", {}, timeout: timeout)&.dig("mcpServers"))
    end

    # Wait for every MCP server the process booted with to leave `pending`.
    #
    # @raise [ControlError] a server failed, or one is still pending at the deadline
    def await_boot!(timeout:)
      deadline = monotonic + timeout
      loop do
        statuses = mcp_status(timeout: [ deadline - monotonic, 1 ].max)
        failed = statuses.select { |server| server["status"] == "failed" }
        raise ControlError, "MCP server #{failed.map { |s| s['name'] }.join(', ')} failed to connect" if failed.any?
        return statuses if statuses.none? { |server| server["status"] == "pending" }
        raise ControlError, "MCP servers still connecting after #{timeout}s" if monotonic > deadline

        Kernel.sleep(0.25)
      end
    end

    # Hand the session's first turn to the process.
    #
    # Everything that can still refuse runs before the prompt is written, so a
    # refusal leaves a process that has said nothing and a session that can start
    # cold. Once the prompt is written the turn is the session's, and the process
    # exits by itself when it ends.
    #
    # @param mcp_servers [Hash] the session's whole server map, as its .mcp.json has it
    # @param env [Hash] variables the session's own spawn would have set and this
    #   process could not have at boot, for every Bash command it runs
    # @raise [Mismatch, ControlError] before the prompt was written
    def deliver!(append_system_prompt:, mcp_servers:, model:, message_json:, env:, timeout:)
      @timings = {}
      # Appended, so anything a boot-time hook exported stays, with the
      # session's values after it taking precedence.
      File.open(env_file_path, "a") do |file|
        file.write(env.map { |key, value| "export #{key}=#{Shellwords.escape(value.to_s)}\n" }.join)
      end

      request!("initialize", { "appendSystemPrompt" => append_system_prompt.to_s }, timeout: timeout)

      result = request!("mcp_set_servers", { "servers" => mcp_servers }, timeout: timeout) || {}
      errors = (result["errors"] || {}).compact_blank
      raise Mismatch.new("mcp_set_servers_failed", "MCP servers could not be set: #{errors.keys.join(', ')}") if errors.any?

      request!("set_model", { "model" => model }, timeout: timeout) if model.present? && model != self.model

      write_prompt_and_close(message_json.end_with?("\n") ? message_json : "#{message_json}\n")
      @state = :delivered
    end

    # Stop the process and keep nothing it was given: closing stdin is enough
    # for an idle `-p` process, and the signal covers one that is not idle. A
    # process already reaped, or no longer the one that was started, is left
    # alone: its pid may belong to someone else by now.
    def terminate!
      close_stdin
      return unless alive?

      Process.kill("TERM", -pid)
      Process.detach(pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def env_file_path
      File.join(dir, "session.env")
    end

    def delivered?
      @state == :delivered
    end

    def to_report(now = Time.current)
      { id: id, pid: pid, state: state.to_s, created_at: created_at, age_seconds: age_seconds(now), model: model,
        working_directory: working_directory, account: account&.email, head: head&.first(12) }
    end

    private

    # Write one control request and wait for its response on stdout.
    #
    # @return [Hash, nil] the response body
    def request!(subtype, payload, timeout:)
      @request_seq += 1
      started = monotonic
      request_id = "warm-#{@request_seq}-#{SecureRandom.hex(3)}"
      line = { "type" => "control_request", "request_id" => request_id, "request" => { "subtype" => subtype }.merge(payload) }
      @stdin.write("#{line.to_json}\n")
      @stdin.flush

      deadline = monotonic + timeout
      loop do
        read_stdout_lines.each do |message|
          next unless message["type"] == "control_response"

          response = message["response"] || {}
          next unless response["request_id"] == request_id
          raise ControlError, "#{subtype} refused: #{response['error']}" unless response["subtype"] == "success"

          @timings[subtype] = ((monotonic - started) * 1000).round
          return response["response"]
        end
        raise ControlError, "#{subtype} unanswered after #{timeout}s" if monotonic > deadline
        raise ControlError, "process exited before answering #{subtype}" unless alive?

        Kernel.sleep(CONTROL_POLL_SECONDS)
      end
    rescue Errno::EPIPE, IOError => e
      raise ControlError, "#{subtype} could not be written: #{e.class}"
    end

    # Complete lines appended to stdout since the last read, parsed. A partial
    # last line waits for the next read.
    def read_stdout_lines
      chunk = File.open(stdout_path, "rb") do |file|
        file.seek(@stdout_offset)
        file.read
      end
      return [] if chunk.blank?

      complete = chunk.rpartition("\n")
      return [] if complete[1].empty?

      @stdout_offset += complete[0].bytesize + 1
      complete[0].split("\n").filter_map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
    end

    # Off the caller's thread, as ClaudeCliAdapter's cold stdin path does: a
    # payload past the pipe buffer (an image) would otherwise block the job until
    # the CLI drains it. Closing stdin after it is what ends the turn.
    def write_prompt_and_close(payload)
      stdin = @stdin
      Thread.new do
        stdin.write(payload)
      rescue Errno::EPIPE, IOError
        nil
      ensure
        stdin.close unless stdin.closed?
      end
    end

    def mark_reaped
      @reaped = true
      ChildWaiterRegistry.instance.release(pid)
    rescue StandardError
      nil
    end

    def close_stdin
      @stdin.close unless @stdin.closed?
    rescue IOError
      nil
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
