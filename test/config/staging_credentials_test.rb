# frozen_string_literal: true

require "test_helper"
require "erb"

# The staging encrypted-credentials path is a four-file chain -- the .enc file, the
# Kamal secrets mapping, the Kamal env.secret list, and the deploy workflow -- and it
# fails SILENTLY when a link breaks: ActiveSupport reads the key as
# `ENV["RAILS_MASTER_KEY"].presence`, so a missing one is indistinguishable from an
# unset one. Staging boots healthy and simply serves no mcp_secrets, which shows up
# much later as "why is Slack quiet on staging". These tests assert the chain.
class StagingCredentialsTest < ActiveSupport::TestCase
  KAMAL_SECRETS = Rails.root.join(".kamal/secrets.staging")
  DEPLOY_CONFIG = Rails.root.join("config/deploy.staging.yml")
  DEPLOY_WORKFLOW = Rails.root.join(".github/workflows/deploy-staging.yml")

  test "staging.yml.enc is committed, and its key is not" do
    tracked = `git -C #{Rails.root} ls-files config/credentials`.split("\n")

    assert_includes tracked, "config/credentials/staging.yml.enc",
      "config/credentials/staging.yml.enc must be committed -- staging has no bind-mounted " \
      "credentials directory (production does), so the .enc has to ship inside the image."
    assert_not_includes tracked, "config/credentials/staging.key",
      "config/credentials/staging.key must NEVER be committed; it decrypts staging.yml.enc."
  end

  test "Kamal maps RAILS_MASTER_KEY from the STAGING_RAILS_MASTER_KEY deploy secret" do
    assert_match(/^RAILS_MASTER_KEY=\$STAGING_RAILS_MASTER_KEY$/, KAMAL_SECRETS.read,
      "#{KAMAL_SECRETS} must map RAILS_MASTER_KEY, or the container never gets a key and " \
      "staging.yml.enc stays encrypted.")
  end

  test "RAILS_MASTER_KEY is exposed to the container as a Kamal secret" do
    assert_includes staging_env_secrets, "RAILS_MASTER_KEY",
      "#{DEPLOY_CONFIG} must list RAILS_MASTER_KEY under env.secret. Mapping it in " \
      ".kamal/secrets.staging alone does nothing -- Kamal only injects what env.secret names."
  end

  test "every secret the staging deploy injects has a mapping in .kamal/secrets.staging" do
    mapped = KAMAL_SECRETS.read.scan(/^([A-Z0-9_]+)=/).flatten

    (staging_env_secrets - mapped).tap do |missing|
      assert_empty missing,
        "#{DEPLOY_CONFIG} lists #{missing.join(', ')} under env.secret with no mapping in " \
        "#{KAMAL_SECRETS}; Kamal fails the deploy when it cannot resolve a named secret."
    end
  end

  test "the deploy workflow passes STAGING_RAILS_MASTER_KEY into the Kamal step" do
    workflow = DEPLOY_WORKFLOW.read

    assert_match(/STAGING_RAILS_MASTER_KEY:\s*\$\{\{\s*secrets\.STAGING_RAILS_MASTER_KEY\s*\}\}/, workflow,
      "deploy-staging.yml must put STAGING_RAILS_MASTER_KEY in the Kamal step's env, or " \
      ".kamal/secrets.staging interpolates it to empty.")
  end

  test "a missing STAGING_RAILS_MASTER_KEY warns but does not fail the deploy" do
    workflow = DEPLOY_WORKFLOW.read
    guard = workflow[/if \[ -z "\$\{STAGING_RAILS_MASTER_KEY:-\}" \]; then.*?\bfi\b/m]

    assert guard, "deploy-staging.yml must guard an empty STAGING_RAILS_MASTER_KEY."
    assert_match(/::warning::/, guard)
    assert_no_match(/exit 1/, guard,
      "A missing staging key must NOT fail the deploy: blank behaves exactly like unset, so the " \
      "app boots fine (just without mcp_secrets). Exiting here would break staging for every " \
      "fork and self-hoster that has not set the secret.")
  end

  private

  # deploy.staging.yml is ERB (hosts come from ENV at deploy time). Rendering with the
  # vars unset yields nils, which is fine -- we only read the env.secret list.
  def staging_env_secrets
    config = YAML.safe_load(ERB.new(DEPLOY_CONFIG.read).result, aliases: true)
    config.dig("env", "secret") || []
  end
end
