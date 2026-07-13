# frozen_string_literal: true

require "test_helper"

# cloud-init.yaml.tftpl is a Terraform `templatefile` template, and templatefile parses the
# WHOLE file as one template -- a `#` comment is not a comment to it. So a `${`/`%{` sequence
# anywhere, comments included, opens an expression, and a malformed one is a syntax error that
# surfaces nowhere but a `terraform apply` -- i.e. in a deploy, after review, on the box that
# was supposed to come up.
#
# These assertions are the cheap version of that feedback. They are not a Terraform parser;
# they catch the two ways this file actually breaks: an opener that never closes, and a
# variable the template reads but main.tf does not pass.
class CloudInitTemplateTest < ActiveSupport::TestCase
  TEMPLATE = Rails.root.join("infra/terraform/cloud-init.yaml.tftpl")
  MAIN_TF = Rails.root.join("infra/terraform/main.tf")

  # An opener of either kind: interpolation (`${`) or directive (`%{`).
  OPENER = /[$%]\{/
  # ...and one that closes on the same line, which every one in this file does.
  WELL_FORMED = /[$%]\{[^}\n]*\}/

  # Terraform builtins and directive keywords used inside the expressions here; everything
  # else an expression names must be a variable main.tf passes in.
  NON_VARIABLES = %w[if else endif for in endfor indent join].freeze

  setup do
    @template = File.read(TEMPLATE)
  end

  test "every interpolation opener closes on its own line" do
    malformed = @template.lines.each_with_index.filter_map do |line, i|
      next if line.scan(OPENER).size == line.scan(WELL_FORMED).size

      "  line #{i + 1}: #{line.strip}"
    end

    assert_empty malformed, <<~MSG
      Unterminated Terraform interpolation in #{TEMPLATE.basename}. templatefile parses this
      file whole -- COMMENTS INCLUDED -- so a `${` or `%{` in prose still opens an expression
      and fails `terraform apply` with a syntax error. Write "dollar-brace", not the literal
      sequence.

      #{malformed.join("\n")}
    MSG
  end

  test "every variable the template reads is one main.tf passes to templatefile" do
    passed = File.read(MAIN_TF)[/templatefile\(.*?\n(.*?)\n\s*\}\)/m, 1].to_s
      .scan(/^\s*(\w+)\s*=/).flatten.to_set

    assert_includes passed, "tailnet_hostname",
      "failed to parse main.tf's templatefile() block -- this test is reading the wrong thing"

    read = @template.scan(WELL_FORMED).flat_map do |token|
      token.gsub(/"[^"]*"/, "")      # drop string literals: join("\n", ...)
        .scan(/[a-z_][a-z0-9_]*/i)   # then every bare identifier
    end.uniq - NON_VARIABLES

    assert_empty read - passed.to_a, <<~MSG
      #{TEMPLATE.basename} interpolates variables that main.tf does not pass to templatefile().
      Terraform fails the apply on an unknown variable, so this never reaches the droplet.
    MSG
  end

  # The bug this guards: DigitalOcean force-expires root's password on a droplet created with
  # no DO-registered key (ssh_key_fingerprints is deliberately empty), and pam_unix then rejects
  # every real-OpenSSH session on :2222 AFTER publickey auth succeeds. Tailscale SSH does not run
  # pam_unix, so Kamal and CI stay green and nothing else catches a regression here.
  test "runcmd clears the forced root-password expiry before sshd starts serving" do
    runcmd = @template.split(/^runcmd:/m, 2).last

    usermod = runcmd.index("usermod -p '*' root")
    chage = runcmd.index(/^\s*-\s*chage -d .* -M -1 root/)
    restart = runcmd.index("systemctl restart ssh.socket ssh.service")

    assert usermod, "runcmd must drop DigitalOcean's root password (usermod -p '*' root)"
    assert chage, "runcmd must clear the forced-change flag and disable aging (chage -d <today> -M -1 root)"
    assert restart, "runcmd must restart ssh.socket + ssh.service"

    # Ordering is not a PAM requirement (it re-reads /etc/shadow per authentication); it keeps
    # :2222 from answering during a window where it would take a key and drop the session.
    assert usermod < restart, "neutralize the root password before the restart that serves :2222"
    assert chage < restart, "clear the expiry before the restart that serves :2222"
  end
end
