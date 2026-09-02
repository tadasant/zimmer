# frozen_string_literal: true

require "test_helper"
require "erb"
require "yaml"
require "kamal"

# Delivering the git identity is a chain — a deploy-time environment variable, the
# `env.clear` mapping in config/deploy.yml, the container's environment,
# GitIdentityProvisioner — and every link of it that is a file in this repo is
# asserted here.
#
# The link that needs a test most is the one nothing else would catch: the *unset*
# case. Kamal validates `env.clear` as a hash of strings, so a bare `<%= ENV[...] %>`
# renders to nothing, YAML reads it as `nil`, and every kamal command — `deploy`
# included — dies at config parse with "should be a string". That fires on precisely
# the deployment this is supposed to degrade gracefully for: staging today, production
# until the companion repo supplies a value, and every self-hoster forever. It would
# not fail a single existing test, because nothing else in the suite loads the Kamal
# config (the other deploy-file test hand-parses the YAML, which happily accepts nil).
class GitIdentityEnvDeliveryTest < ActiveSupport::TestCase
  DEPLOY = Rails.root.join("config/deploy.yml")

  NAME_VAR = GitIdentityProvisioner::NAME_ENV_VAR
  EMAIL_VAR = GitIdentityProvisioner::EMAIL_ENV_VAR

  # Everything the destination files interpolate unconditionally, so the config gets
  # far enough to validate the keys this test is actually about.
  DESTINATION_ENV = {
    "PRODUCTION_HOST" => "10.0.0.1",
    "PRODUCTION_DB_HOST" => "db.example.com",
    "STAGING_HOST" => "10.0.0.2"
  }.freeze

  test "both variables are declared in the shared env.clear" do
    clear = env_clear
    assert_includes clear.keys, NAME_VAR,
      "#{DEPLOY} must declare #{NAME_VAR}, or the container never receives it and " \
      "every committing session goes back to exiting 128."
    assert_includes clear.keys, EMAIL_VAR, "#{DEPLOY} must declare #{EMAIL_VAR}."
  end

  test "an unconfigured deployment still loads the Kamal config" do
    %w[production staging].each do |destination|
      with_env(NAME_VAR => nil, EMAIL_VAR => nil) do
        assert_nothing_raised do
          load_kamal_config(destination)
        end
      end
    end
  end

  test "an unconfigured deployment delivers empty strings, which the provisioner treats as unset" do
    with_env(NAME_VAR => nil, EMAIL_VAR => nil) do
      assert_equal "", env_clear[NAME_VAR]
      assert_equal "", env_clear[EMAIL_VAR]
    end

    # And the reader's own contract on that value: blank is "not configured", never a
    # blank identity written into the config.
    assert_nil GitIdentityProvisioner.ensure!(home: Dir.mktmpdir("git-identity-env-test"), logger: Logger.new(File::NULL))
  end

  test "a configured deployment delivers the values verbatim, spaces and all" do
    with_env(NAME_VAR => "Ada Lovelace", EMAIL_VAR => "ada@example.com") do
      assert_equal "Ada Lovelace", env_clear[NAME_VAR]
      assert_equal "ada@example.com", env_clear[EMAIL_VAR]
    end
  end

  # A name may legitimately carry a quote, and a naively-quoted YAML scalar would end
  # early on it — a Psych::SyntaxError that takes down every kamal command.
  test "a name containing a double quote does not break the config" do
    with_env(NAME_VAR => 'Tad "Q" Antanavicius', EMAIL_VAR => "t@example.com") do
      assert_nothing_raised { load_kamal_config("production") }
      assert_equal 'Tad "Q" Antanavicius', env_clear[NAME_VAR]
    end
  end

  private

  def env_clear
    YAML.load(ERB.new(DEPLOY.read).result, aliases: true).fetch("env").fetch("clear")
  end

  def load_kamal_config(destination)
    with_env(DESTINATION_ENV) do
      Kamal::Configuration.create_from(config_file: DEPLOY, destination: destination)
    end
  end

  # Sets each key to its value for the block, treating nil as "unset", and restores
  # whatever was there before.
  def with_env(vars)
    original = vars.keys.index_with { |key| ENV[key] }
    vars.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
