# frozen_string_literal: true

# Moving Zimmer's secrets from the pre-rename namespace to the canonical one.
#
# ## Why this is a rake task and not a deploy
#
# AGENTS.md's rule is that an ops action ships with the deploy, and the default
# answer to "someone runs `rake …` on prod" is a post-deploy task. This one is
# the exception, for a reason that is the whole point of the design it serves:
# writing to the store needs a credential Zimmer deliberately does not have. The
# resolver's key is baked into the image and reaches every session's environment
# resolution; it holds three read roles and no write role, and that absence is
# checked at runtime (Capabilities#least_privilege?). Shipping this as a job
# would mean deploying a `parametermanager.admin` + `secretmanager.admin` key
# into the image to run once — widening the blast radius of the one baked
# credential permanently, to save a human one command.
#
# So it runs from wherever the writer credential already is: an operator's shell,
# or a CI job holding the key as a secret. It touches no Zimmer database and no
# running process — only Google — so it does not need to run on the production
# box, and should not.
#
# ## Running it
#
#   ZIMMER_PARAMS_PROJECT_ID=zimmer-secrets-prod \
#   ZIMMER_PARAMS_RESOLVER_SERVICE_ACCOUNT_KEY_JSON="$(cat resolver.json)" \
#   ZIMMER_PARAMS_WRITER_SERVICE_ACCOUNT_KEY_JSON="$(cat writer.json)" \
#   PARAMS_ENV=production \
#     bin/rails parameter_store:migrate_namespace
#
# That is the DRY RUN: it reads both namespaces, prints the plan, writes nothing.
# `parameter_store:migrate_namespace!` is the same thing for real, and refuses to
# start unless `CONFIRM` matches the environment being migrated.
#
# PARAMS_ENV names the namespace's environment, which is NOT this process's
# RAILS_ENV: migrating production's namespace from a laptop is the normal case.
namespace :parameter_store do
  desc "Plan the move from the pre-rename secret namespace to the canonical one (writes nothing)"
  task migrate_namespace: :environment do
    ParameterStoreMigrationTask.new(dry_run: true).run
  end

  desc "Execute the move from the pre-rename secret namespace to the canonical one (CONFIRM=<env> required)"
  task migrate_namespace!: :environment do
    ParameterStoreMigrationTask.new(dry_run: false).run
  end
end

# Wiring, preflight and printing for the two tasks above. The migration itself is
# ParameterStore::NamespaceMigration, which is where the logic and its tests are.
class ParameterStoreMigrationTask
  def initialize(dry_run:, out: $stdout, env: ENV)
    @dry_run = dry_run
    @out = out
    @env = env
  end

  def run
    params_env = @env["PARAMS_ENV"].presence || Rails.env
    resolver = resolver_client
    writer = @dry_run ? nil : write_client
    confirm!(params_env)

    report = ParameterStore::NamespaceMigration.new(
      resolver: resolver, writer: writer, env: params_env,
      dry_run: @dry_run, prune: @env["PRUNE"] != "false"
    ).call

    print_report(report)
    abort "migration reported #{report.failures.size} failure(s)" unless report.ok?
  end

  private

  def resolver_client
    configuration = ParameterStore::Resolver.from_env(@env)
    abort "no Parameter Store resolver credential: #{configuration.reason}" unless configuration.configured?

    configuration.client
  end

  # The writer's permissions are probed BEFORE anything is written, so a
  # credential that can create but not delete fails here rather than halfway
  # through, having copied every secret and removed none.
  def write_client
    configuration = ParameterStore::Writer.from_env(@env)
    abort "no Parameter Store writer credential: #{configuration.reason}" unless configuration.configured?

    capabilities = ParameterStore::Capabilities.probe(configuration.client)
    abort "could not confirm the writer's permissions: #{capabilities.reason}" unless capabilities.probed?
    unless capabilities.can_upsert?
      abort "the writer credential cannot create secrets; it is missing " \
            "#{capabilities.missing_for_upsert.join(', ')}"
    end
    if @env["PRUNE"] != "false" && !capabilities.can_delete?
      abort "the writer credential cannot delete secrets; it is missing " \
            "#{capabilities.missing_for_delete.join(', ')}. Re-run with PRUNE=false to copy only."
    end

    unless configuration.dedicated_writer?
      say "! writing as the RESOLVER credential, which is not supposed to hold write permission."
    end

    configuration.client
  end

  def confirm!(params_env)
    return if @dry_run
    return if @env["CONFIRM"] == params_env

    abort "this rewrites secrets in the #{params_env} namespace. Re-run with CONFIRM=#{params_env}."
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
    end

    say ""
    say "  #{report.counts.map { |action, count| "#{action}: #{count}" }.join(', ')}" if report.items.any?
    if report.complete?
      say "  #{report.from_namespace} is empty. The resolver's pre-rename read path can be dropped."
    else
      say "  still at #{report.from_namespace}: #{report.legacy_remaining.join(', ').presence || 'none'}"
    end
  end

  def say(line) = @out.puts(line)
end
