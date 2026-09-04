# frozen_string_literal: true

module ParameterStore
  # The command-line face of {NamespaceMigration}: build the two clients from the
  # environment, refuse to start if the writer cannot finish, run the migration,
  # and print what happened.
  #
  # It lives here rather than in the rake file so it is autoloaded and testable.
  # The rake file is the thin part — see lib/tasks/parameter_store.rake, which
  # also explains why this one ops action ships as a task rather than as a
  # post-deploy job.
  #
  # Nothing here prints a value. Names, paths, ids and verdicts only.
  class MigrationTask
    # Raised for every reason the run must not proceed. The rake task turns it
    # into an `abort`; a test can assert on the sentence.
    class Refused < StandardError; end

    # @param dry_run [Boolean]
    # @param out [IO]
    # @param env [Hash] the environment to read (injectable for tests)
    def initialize(dry_run:, out: $stdout, env: ENV)
      @dry_run = dry_run
      @out = out
      @env = env
    end

    # @return [NamespaceMigration::Report]
    # @raise [Refused]
    def run
      params_env = @env["PARAMS_ENV"].presence || Rails.env
      confirm!(params_env)

      report = NamespaceMigration.new(
        resolver: resolver_client, writer: @dry_run ? nil : write_client,
        env: params_env, dry_run: @dry_run, prune: prune?
      ).call

      print_report(report)
      report
    end

    private

    def prune? = @env["PRUNE"] != "false"

    def resolver_client
      configuration = Resolver.from_env(@env)
      unless configuration.configured?
        raise Refused, "no Parameter Store resolver credential: #{configuration.reason}"
      end

      configuration.client
    end

    # The writer's permissions are probed BEFORE anything is written, so a
    # credential that can create but not delete fails here rather than halfway
    # through, having copied every secret and removed none.
    def write_client
      configuration = Writer.from_env(@env)
      unless configuration.configured?
        raise Refused, "no Parameter Store writer credential: #{configuration.reason}"
      end

      check_capabilities!(Capabilities.probe(configuration.client))
      unless configuration.dedicated_writer?
        say "! writing as the RESOLVER credential, which is not supposed to hold write permission."
      end

      configuration.client
    end

    def check_capabilities!(capabilities)
      unless capabilities.probed?
        raise Refused, "could not confirm the writer's permissions: #{capabilities.reason}"
      end
      unless capabilities.can_upsert?
        raise Refused, "the writer credential cannot create secrets; it is missing " \
                       "#{capabilities.missing_for_upsert.join(', ')}"
      end
      return unless prune? && !capabilities.can_delete?

      raise Refused, "the writer credential cannot delete secrets; it is missing " \
                     "#{capabilities.missing_for_delete.join(', ')}. " \
                     "Re-run with PRUNE=false to copy only."
    end

    # A live run rewrites real secrets, and the environment it rewrites them in is
    # read from ENV rather than from Rails.env — so naming it back is the guard
    # against migrating production while meaning to migrate staging.
    def confirm!(params_env)
      return if @dry_run
      return if @env["CONFIRM"] == params_env

      raise Refused, "this rewrites secrets in the #{params_env} namespace. " \
                     "Re-run with CONFIRM=#{params_env}."
    end

    def print_report(report)
      say "#{report.dry_run ? 'PLAN (nothing written)' : 'MIGRATION'} — project #{report.project_id}, " \
          "environment #{report.env}"
      say "  from #{report.from_namespace}"
      say "    to #{report.to_namespace}"
      say ""

      if report.items.empty?
        say "  neither namespace holds anything. Nothing to do."
      else
        report.items.each { |item| say "  [#{item.action}] #{item.variable} — #{item.detail}" }
        say ""
        say "  #{report.counts.map { |action, count| "#{action}: #{count}" }.join(', ')}"
      end

      if report.complete?
        say "  #{report.from_namespace} is empty. The resolver's pre-rename read path can be dropped."
      else
        say "  still at #{report.from_namespace}: #{report.legacy_remaining.join(', ').presence || 'none'}"
      end
    end

    def say(line) = @out.puts(line)
  end
end
