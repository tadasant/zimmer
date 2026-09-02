# frozen_string_literal: true

module GateDecisions
  module LedgerSource
    # Ledger files fetched straight from `tadasant/tadasant-internal` over `gh`.
    #
    # WHY NOT A CHECKOUT. The ledgers live in a different repository from the one
    # this app deploys out of, so there is no copy of them in the image and no
    # shell on the production box to make one — "ops actions ship with the deploy"
    # (AGENTS.md) means the backfill has to be able to reach its own source
    # unattended. `gh` is already authenticated in every Zimmer container
    # (GhTokenProvisioner publishes GH_TOKEN at boot, and GithubTriggerPollerJob
    # shells out to it from a job), so this borrows that credential rather than
    # introducing one.
    #
    # The raw media type is what makes this work at all: the Contents API's
    # default base64-JSON form is capped at 1 MB, and the largest ledger is 3.4 MB.
    class Github
      REPO = "tadasant/tadasant-internal"
      DIRECTORY = "artifacts/references"

      # Generous: the largest file is a few MB over an authenticated API call, and
      # the caller is a background task with a slice budget, not a request.
      LIST_TIMEOUT = 30
      FETCH_TIMEOUT = 120

      def initialize(repo: REPO, directory: DIRECTORY)
        @repo = repo
        @directory = directory
      end

      def describe = "github:#{@repo}/#{@directory}"

      def files
        listing = JSON.parse(gh("repos/#{@repo}/contents/#{@directory}", timeout: LIST_TIMEOUT))
        raise Unavailable, "#{@directory} did not list as a directory" unless listing.is_a?(Array)

        listing.filter_map { |item| LedgerFile.parse(item["name"].to_s) }.sort_by(&:name)
      rescue JSON::ParserError => e
        raise Unavailable, "could not parse the directory listing: #{e.message}"
      end

      def entries(file)
        parsed = JSON.parse(gh("repos/#{@repo}/contents/#{@directory}/#{file.name}",
                               timeout: FETCH_TIMEOUT, raw: true))
        parsed.is_a?(Array) ? parsed.select { |entry| entry.is_a?(Hash) } : []
      rescue JSON::ParserError => e
        raise Unavailable, "#{file.name} did not come back as valid JSON: #{e.message}"
      end

      private

      def gh(path, timeout:, raw: false)
        GhTokenProvisioner.ensure!

        command = [ "gh", "api", path ]
        command += [ "-H", "Accept: application/vnd.github.raw" ] if raw

        stdout, stderr, status = BoundedSubprocess.run(command, timeout: timeout)
        unless SubprocessStatus.success?(status)
          raise Unavailable, "gh api #{path} failed (#{SubprocessStatus.describe_failure(status, stderr)})"
        end

        stdout
      rescue BoundedSubprocess::TimeoutError => e
        raise Unavailable, e.message
      rescue Errno::ENOENT
        raise Unavailable, "the gh CLI is not installed in this container, so the ledger JSON " \
                           "cannot be fetched. Point #{DIR_ENV_VAR} at a checkout instead."
      end
    end
  end
end
