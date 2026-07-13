# frozen_string_literal: true

# OperatorSshKeyProvisioner — materializes the operator SSH private key onto disk
# so agent sessions can authenticate over SSH.
#
# WHY THIS EXISTS
#
# An agent session runs as a child process of the worker container and inherits its
# $HOME (/home/rails). The image ships no SSH identity, and the durable volumes
# (~/.claude, ~/.zimmer, ~/.config/gh, ~/.local) do not cover ~/.ssh — so a session
# had NO private key at all. Every `ssh-*` MCP server (ssh-agent-mcp-server is an
# ssh2 *publickey* client) failed its startup health check with "All configured
# authentication methods failed", not because the host rejected the key but because
# there was no key to offer.
#
# HOW THE KEY TRAVELS
#
# The private key is a secret, so it never touches git. It arrives as
# ZIMMER_OPERATOR_SSH_KEY, either through Kamal's `env.secret` (which is how both
# staging and production ship it — see .kamal/secrets.*) or through Zimmer's
# encrypted `mcp_secrets`, whichever an operator prefers. It is BASE64-ENCODED on
# the wire: Kamal hands env vars to Docker through an env-file, and a Docker
# env-file cannot carry a newline, so a raw PEM would arrive truncated at its first
# line break. A raw PEM is still accepted (for a local/dev operator who exports the
# variable by hand) — the encoding is sniffed, not assumed.
#
# WHY A FILE, AND NOT JUST AN ENV VAR
#
# ssh2 (and OpenSSH, and git) want a key *path*, not key material:
# ssh-agent-mcp-server reads SSH_AUTH_SOCK first and SSH_PRIVATE_KEY_PATH second,
# and nothing else. So the material is written to ~/.ssh/id_ed25519 (0600, in a
# 0700 ~/.ssh) — the conventional location, which also makes the plain `ssh` and
# `git` CLIs inside a session work — and CliSpawnEnv#apply_operator_ssh_key exports
# SSH_PRIVATE_KEY_PATH at that file for the MCP servers.
#
# BLAST RADIUS
#
# This key is root on every Zimmer droplet that authorizes it (admin_ssh_pubkeys ->
# cloud-init -> /root/.ssh/authorized_keys, reachable only over the tailnet on
# :2222). A session running on production therefore holds a key that is root on its
# own host. That is a deliberate, accepted trade: the key is a distinct identity
# (comment `zimmer-production-operator`), so it can be revoked on its own by
# dropping one line from admin_ssh_pubkeys, without touching the Kamal deploy key.
class OperatorSshKeyProvisioner
  # Name of the env var / mcp_secret carrying the key material.
  ENV_VAR = "ZIMMER_OPERATOR_SSH_KEY"

  # Where the key lands. `id_ed25519` is what OpenSSH and git look for by default.
  KEY_FILENAME = "id_ed25519"

  # A private key of any flavor ssh2 accepts (OpenSSH, RSA, EC, …). Matched as a pattern
  # rather than compared against a spelled-out header, so that no line in this repo —
  # source, test, or fixture — reads as a private-key header itself. That is what secret
  # scanners flag, and what a reviewer greps the history for to prove no key was committed.
  PEM_HEADER = /\A-----BEGIN [A-Z0-9 ]+PRIVATE KEY-----/

  class << self
    # Write the operator key to ~/.ssh/id_ed25519 if key material is configured.
    #
    # Idempotent and safe to call on every boot and every session spawn: it rewrites
    # the file only when the content differs, and always reasserts 0700/0600.
    #
    # Best-effort by design — a missing or malformed key must never break a boot or
    # a spawn. It degrades to "sessions cannot SSH", exactly the state before this
    # class existed, and says so in the log.
    #
    # @param home [String] the home directory to provision into (defaults to $HOME)
    # @param logger [Logger] where to report
    # @return [String, nil] absolute path to the key, or nil when none was provisioned
    def ensure!(home: Dir.home, logger: Rails.logger)
      material = key_material
      return nil if material.blank?

      pem = decode(material)
      if pem.nil?
        logger.warn "#{ENV_VAR} is set but is neither an OpenSSH private key nor valid base64 of one — sessions will have no SSH identity"
        return nil
      end

      write_key(pem, home: home, logger: logger)
    rescue => e
      logger.warn "Failed to provision the operator SSH key: #{e.class} - #{e.message}"
      nil
    end

    # Path the key is (or would be) written to, without provisioning it.
    # @param home [String] the home directory
    # @return [String] absolute path to ~/.ssh/id_ed25519
    def key_path(home: Dir.home)
      File.join(home, ".ssh", KEY_FILENAME)
    end

    private

    # ENV wins over credentials: the deployed environments ship the key through
    # Kamal's env.secret, and an operator overriding it locally should not have to
    # re-encrypt credentials to do so.
    def key_material
      ENV[ENV_VAR].presence || SecretsLoader.get(ENV_VAR).presence
    rescue => e
      Rails.logger.warn "Could not read #{ENV_VAR} from credentials: #{e.class} - #{e.message}"
      ENV[ENV_VAR].presence
    end

    # Accept both a raw PEM and base64 of one, and normalize to a PEM with the
    # trailing newline OpenSSH's parser requires.
    #
    # @return [String, nil] the PEM, or nil if the material is neither
    def decode(material)
      stripped = material.strip
      return ensure_trailing_newline(stripped) if stripped.match?(PEM_HEADER)

      decoded = Base64.strict_decode64(stripped.gsub(/\s+/, ""))
      return nil unless decoded.match?(PEM_HEADER)

      ensure_trailing_newline(decoded)
    rescue ArgumentError
      nil
    end

    def ensure_trailing_newline(pem)
      pem.end_with?("\n") ? pem : "#{pem}\n"
    end

    # Write atomically (tmp file + rename) so a concurrent reader — an MCP server
    # starting up in another session — never sees a half-written key.
    def write_key(pem, home:, logger:)
      ssh_dir = File.join(home, ".ssh")
      path = File.join(ssh_dir, KEY_FILENAME)

      FileUtils.mkdir_p(ssh_dir)
      File.chmod(0o700, ssh_dir)

      if File.exist?(path) && File.read(path) == pem
        File.chmod(0o600, path)
        return path
      end

      tmp = "#{path}.tmp"
      File.write(tmp, pem)
      File.chmod(0o600, tmp)
      File.rename(tmp, path)

      logger.info "Provisioned the operator SSH key at #{path} (0600)"
      path
    end
  end
end
