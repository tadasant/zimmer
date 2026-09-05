# frozen_string_literal: true

module WorkBacklog
  # Where the importer reads `WORK_BACKLOG.json` from.
  #
  # The file lives in `tadasant/tadasant-internal`, a DIFFERENT repository from
  # the one this app deploys out of, and there is deliberately no shell on the
  # production box to check it out from. So the default source fetches the one
  # file over `gh`, which every Zimmer container already has a credential for —
  # the same shape as GateDecisions::LedgerSource — and the file source exists
  # for tests and for anyone running the import against a clone they have.
  #
  # Resolution order:
  #
  #   1. an explicit `path:` — what the tests pass
  #   2. ENV["WORK_BACKLOG_SOURCE_PATH"] — an operator pointing at a checkout
  #   3. GitHub, via `gh api`
  module Source
    PATH_ENV_VAR = "WORK_BACKLOG_SOURCE_PATH"

    class Unavailable < StandardError; end

    def self.resolve(path: nil)
      path = path.presence || ENV[PATH_ENV_VAR].presence
      return LocalFile.new(path) if path

      Github.new
    end

    # Shared: the parsed array, with anything that is not an object dropped.
    module Parsing
      private

      def parse(raw, label)
        parsed = JSON.parse(raw)
        raise Unavailable, "#{label} is not a JSON array" unless parsed.is_a?(Array)

        parsed.select { |item| item.is_a?(Hash) }
      rescue JSON::ParserError => e
        raise Unavailable, "#{label} is not valid JSON: #{e.message}"
      end
    end

    # The JSON read off the local filesystem.
    class LocalFile
      include Parsing

      attr_reader :path

      def initialize(path)
        @path = path.to_s
      end

      def describe = "file #{path}"

      # @return [Array<Hash>] the items, in file order
      def items
        raise Unavailable, "#{path} is not a file" unless ::File.file?(path)

        parse(::File.read(path), path)
      end
    end

    # The JSON fetched straight from `tadasant/tadasant-internal` over `gh`.
    class Github
      include Parsing

      REPO = "tadasant/tadasant-internal"
      FILE_PATH = "artifacts/agent-roots/fleet-maintenance/WORK_BACKLOG.json"

      # Under PostDeployTaskJob::SLICE_BUDGET (90s): the file is ~100 KB, so this
      # is generous.
      FETCH_TIMEOUT = 60

      def initialize(repo: REPO, file_path: FILE_PATH)
        @repo = repo
        @file_path = file_path
      end

      def describe = "github:#{@repo}/#{@file_path}"

      def items
        parse(gh("repos/#{@repo}/contents/#{@file_path}"), describe)
      end

      private

      # The raw media type, so the response is the file and not a base64 envelope.
      def gh(path)
        GhTokenProvisioner.ensure!

        command = [ "gh", "api", path, "-H", "Accept: application/vnd.github.raw" ]
        result = GithubCli.run(command, timeout: FETCH_TIMEOUT)
        # A non-zero exit, an exit code lost to a reap, and a call that hung until its
        # deadline are all the same answer here: we did not get the file. See GithubCli.
        unless result.success?
          raise Unavailable, "gh api #{path} failed (#{result.failure_description})"
        end

        result.stdout
      rescue Errno::ENOENT
        raise Unavailable, "the gh CLI is not installed in this container, so WORK_BACKLOG.json " \
                           "cannot be fetched. Point #{PATH_ENV_VAR} at a checkout instead."
      end
    end
  end
end
