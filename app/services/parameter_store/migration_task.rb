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

      # The writer is probed on BOTH paths. A dry run cannot write — it passes no
      # write client to the migration — but the documented invocation hands it a
      # writer key precisely so the plan answers "and could this credential
      # actually do it". Probing only on the live run would defer that answer to
      # the destructive command, which is the one place nobody wants a surprise.
      writer = write_client(refuse: !@dry_run)

      report = NamespaceMigration.new(
        resolver: resolver_client, writer: @dry_run ? nil : writer,
        env: params_env, dry_run: @dry_run, prune: prune?
      ).call

      print_report(report)
      report
    end

    private

    TRUTHY = %w[1 t true y yes on].freeze
    FALSEY = %w[0 f false n no off].freeze

    # PRUNE defaults to true, and true is the destructive direction — so an
    # unrecognised value must not quietly mean "delete". `PRUNE=0` reaching for
    # the documented safe half-step and getting a full delete pass is exactly the
    # failure this refuses instead of guessing at.
    def prune?
      raw = @env["PRUNE"]
      return true if raw.nil? || raw.strip.empty?

      value = raw.strip.downcase
      return true if TRUTHY.include?(value)
      return false if FALSEY.include?(value)

      raise Refused, "PRUNE=#{raw} is not a yes or a no. Use PRUNE=false to copy without deleting, " \
                     "or leave it unset to migrate fully."
    end

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
    # @param refuse [Boolean] true on a live run, where a credential that cannot
    #   finish the job is a stop. On a dry run the same findings are printed and
    #   the plan continues — the point of a plan is to report, including on the
    #   credential.
    def write_client(refuse:)
      configuration = Writer.from_env(@env)
      unless configuration.configured?
        raise Refused, "no Parameter Store writer credential: #{configuration.reason}" if refuse

        say "! no writer credential, so the plan below could not be checked against one: " \
            "#{configuration.reason}"
        return nil
      end

      check_capabilities!(Capabilities.probe(configuration.client), refuse: refuse)
      unless configuration.dedicated_writer?
        say "! writing as the RESOLVER credential, which is not supposed to hold write permission."
      end

      configuration.client
    end

    def check_capabilities!(capabilities, refuse:)
      unless capabilities.probed?
        return object!("could not confirm the writer's permissions: #{capabilities.reason}", refuse)
      end
      unless capabilities.can_upsert?
        return object!("the writer credential cannot create secrets; it is missing " \
                       "#{capabilities.missing_for_upsert.join(', ')}", refuse)
      end
      return unless prune? && !capabilities.can_delete?

      object!("the writer credential cannot delete secrets; it is missing " \
              "#{capabilities.missing_for_delete.join(', ')}. " \
              "Re-run with PRUNE=false to copy only.", refuse)
    end

    # Stop the run, or — on a dry run — report the same sentence and carry on.
    def object!(message, refuse)
      raise Refused, message if refuse

      say "! #{message}"
      nil
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
