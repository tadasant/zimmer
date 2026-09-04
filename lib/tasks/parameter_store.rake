# frozen_string_literal: true

# Moving Zimmer's secrets from the pre-rename namespace to the canonical one.
#
# ## Why this is a rake task and not a deploy
#
# AGENTS.md's rule is that an ops action ships with the deploy, and the default
# answer to "someone runs `rake …` on prod" is a post-deploy task. This one is
# the exception, for the reason that is the whole point of the design it serves:
# writing to the store needs a credential Zimmer deliberately does not have. The
# resolver's key is baked into the image and reaches every session's environment
# resolution; it holds three read roles and no write role, and that absence is
# checked at runtime (Capabilities#least_privilege?). Shipping this as a job
# would mean deploying the writer's key into the image to run once —
# permanently widening the blast radius of the one baked credential to save a
# human a single command.
#
# So it runs from wherever the writer credential already is: an operator's shell,
# or a CI job holding the key as a secret. It touches no Zimmer database and no
# running process — only Google — so it does not need a shell on the production
# box, and should not have one.
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
# `migrate_namespace!` is the same thing for real, and refuses to start unless
# CONFIRM matches the environment being migrated.
#
# PARAMS_ENV names the NAMESPACE's environment, which is not this process's
# RAILS_ENV: migrating production's namespace from somewhere that is not
# production is the normal case. PRUNE=false stops after the copy.
#
# The logic is ParameterStore::NamespaceMigration; the wiring, preflight and
# printing are ParameterStore::MigrationTask. Both are tested.
namespace :parameter_store do
  desc "Plan the move from the pre-rename secret namespace to the canonical one (writes nothing)"
  task migrate_namespace: :environment do
    run_namespace_migration(dry_run: true)
  end

  desc "Execute the move from the pre-rename secret namespace to the canonical one (CONFIRM=<env> required)"
  task migrate_namespace!: :environment do
    run_namespace_migration(dry_run: false)
  end
end

def run_namespace_migration(dry_run:)
  report = ParameterStore::MigrationTask.new(dry_run: dry_run).run
  abort "migration reported #{report.failures.size} failure(s)" unless report.ok?
rescue ParameterStore::MigrationTask::Refused => e
  abort e.message
end
