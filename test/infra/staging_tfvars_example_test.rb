# frozen_string_literal: true

require "test_helper"

# `deploy-staging.yml` runs `cp staging.tfvars.example staging.tfvars` VERBATIM, and
# `*.tfvars` is gitignored. So the example file IS the tfvars every deploy applies -- and
# this repository is public. A key committed into it is therefore a key authorized for
# root on the droplet of whoever runs "Deploy staging", which for a fork means a
# stranger's key on their own box, with only a "replace this" comment standing between
# them and it.
#
# The list arrives as TF_VAR_admin_ssh_pubkeys from the ADMIN_SSH_PUBKEYS Actions
# variable instead, so an unset variable falls through to var.admin_ssh_pubkeys's default
# of []. These assertions hold that shape: they fail the build if key material comes back
# into a committed infra file, if the example file starts assigning admin_ssh_pubkeys
# again (a -var-file value BEATS TF_VAR_*, so the assignment would not add to the CI list
# -- it would silently replace it), or if the workflow stops passing the variable through.
class StagingTfvarsExampleTest < ActiveSupport::TestCase
  EXAMPLE = Rails.root.join("infra/terraform/staging.tfvars.example")
  WORKFLOW = Rails.root.join(".github/workflows/deploy-staging.yml")
  MAIN_TF = Rails.root.join("infra/terraform/main.tf")

  # A real SSH public key: a key type, then a base64 body. The `AAAA...` placeholder in
  # the example file and the `AAAA...FEp3` elisions in the docs do not match -- the body
  # has to be long enough to be usable.
  KEY_TYPES = %w[ssh-ed25519 ssh-rsa ssh-dss ecdsa-sha2-nistp256 ecdsa-sha2-nistp384 ecdsa-sha2-nistp521].freeze
  PUBKEY = /\b(?:#{KEY_TYPES.join("|")})\s+AAAA[A-Za-z0-9+\/=]{20,}/

  # Where an infra key would plausibly land if someone put one back.
  SCANNED = %w[
    infra/**/*
    .github/**/*
    .kamal/*
    docs/src/content/docs/**/*
  ].freeze

  test "no committed infra or docs file carries usable SSH public key material" do
    offenders = SCANNED.flat_map { |pattern| Dir.glob(Rails.root.join(pattern)) }
      .uniq
      .reject { |path| File.directory?(path) || path.include?("node_modules") }
      .filter_map do |path|
        body = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
        next unless (match = body[PUBKEY])

        "  #{Pathname.new(path).relative_path_from(Rails.root)}: #{match[0, 40]}…"
      end

    assert_empty offenders, <<~MSG
      A usable SSH public key is committed. Public keys are not secrets, but these files
      are applied to whoever's infrastructure runs them -- staging.tfvars.example is
      copied verbatim by deploy-staging.yml, so a key in it authorizes that key for root
      on every fork's droplet.

      Operator keys belong in the ADMIN_SSH_PUBKEYS Actions variable, never in the repo.
      Elide the body (ssh-ed25519 AAAA...FEp3 name) if you are documenting one.

      #{offenders.join("\n")}
    MSG
  end

  test "staging.tfvars.example assigns no admin_ssh_pubkeys" do
    active = File.read(EXAMPLE).lines.grep(/^\s*admin_ssh_pubkeys\s*=/)

    assert_empty active, <<~MSG
      staging.tfvars.example assigns admin_ssh_pubkeys. It must not: a `-var-file` value
      takes precedence over TF_VAR_*, so this assignment does not extend the keys
      deploy-staging.yml passes from the ADMIN_SSH_PUBKEYS variable -- it REPLACES them,
      for every fork as well as for this repo. Keep the line commented out.

      #{active.map { |l| "  #{l.strip}" }.join("\n")}
    MSG
  end

  test "deploy-staging.yml passes the ADMIN_SSH_PUBKEYS variable through to Terraform" do
    workflow = File.read(WORKFLOW)

    assert_match(/ADMIN_SSH_PUBKEYS:\s*\$\{\{\s*vars\.ADMIN_SSH_PUBKEYS\s*\}\}/, workflow,
      "deploy-staging.yml no longer reads the ADMIN_SSH_PUBKEYS Actions variable, so the " \
      "staging droplet can only ever authorize the Kamal deploy key.")
    assert_match(/export TF_VAR_admin_ssh_pubkeys="\$ADMIN_SSH_PUBKEYS"/, workflow,
      "deploy-staging.yml reads ADMIN_SSH_PUBKEYS but never exports it as " \
      "TF_VAR_admin_ssh_pubkeys, so Terraform never sees it.")
  end

  test "var.admin_ssh_pubkeys defaults to the empty list" do
    block = File.read(MAIN_TF)[/variable "admin_ssh_pubkeys" \{.*?\n\}/m]

    assert block, "main.tf no longer declares variable \"admin_ssh_pubkeys\""
    assert_match(/^\s*default\s*=\s*\[\]\s*$/, block, <<~MSG)
      var.admin_ssh_pubkeys must default to [] -- that default is the whole reason an
      unset ADMIN_SSH_PUBKEYS is safe rather than silent. A module default with a key in
      it would authorize that key on every fork that never overrides it.
    MSG
  end
end
