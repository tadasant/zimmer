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
# The private key is a secret, so it never touches git. It arrives in the process
# environment as ZIMMER_OPERATOR_SSH_KEY, through Kamal's `env.secret` (see
# .kamal/secrets.*), BASE64-ENCODED: Kamal hands env vars to Docker through an
# env-file, and a Docker env-file cannot carry a newline, so a raw PEM would arrive
# truncated at its first line break. A raw PEM is still accepted — for a developer
# who exports the variable by hand — so the encoding is sniffed, not assumed.
#
# Deliberately ENV-only, and NOT read from Zimmer's `mcp_secrets`:
# AgentSessionJob#inject_secrets_to_env_file writes every mcp_secret in plaintext
# into the session clone's `.env`, inside the git working tree the agent operates on.
# Key material has no business there. CliSpawnEnv also unsets this variable for the
# agent process for the same reason: a session needs the key's PATH, never its bytes.
#
# WHY A FILE, AND NOT JUST AN ENV VAR
#
# ssh2 (and OpenSSH, and git) want a key *path*, not key material:
# ssh-agent-mcp-server reads SSH_AUTH_SOCK first and SSH_PRIVATE_KEY_PATH second,
# and nothing else. So the material is written to ~/.ssh/zimmer_operator_ed25519
# (0600, in a 0700 ~/.ssh) and CliSpawnEnv#apply_operator_ssh_key exports
# SSH_PRIVATE_KEY_PATH at that file.
#
# The filename is Zimmer's own, NOT the conventional `id_ed25519`: nothing here needs
# the conventional name (every consumer is handed an explicit path), while writing it
# would silently overwrite the personal key of any developer or self-hoster who sets
# ZIMMER_OPERATOR_SSH_KEY and then runs `bin/rails console`. An agent that wants the
# plain CLI uses `ssh -i "$SSH_PRIVATE_KEY_PATH"`.
#
# BLAST RADIUS, AND THE ONE HOST DELIBERATELY LEFT OUT OF IT
#
# This key is root on every Zimmer droplet that authorizes it (a key list ->
# /root/.ssh/authorized_keys, reachable only over the tailnet on :2222). Which hosts
# authorize it is the ONLY bound on what a session can reach — this class does not,
# and cannot, scope it: it writes one key that every session in the container shares.
#
# PRODUCTION DOES NOT AUTHORIZE IT, and that is the point. A session runs ON
# production, so a key that is root there is root on the session's own host: an agent
# could stop the containers or wipe the catalog out from under the service executing
# it, with itself inside the blast radius and nothing left running to recover from.
# Root on production is reserved for humans (break-glass) and for an orchestrator that
# reaches in from a SEPARATE host — off-box, so it survives what it breaks. Staging,
# the obs box, and the CI runner do authorize the key; that is the fleet these sessions
# operate, and staging is disposable.
#
# Nothing here grants that access, and nothing here assumes it: provisioning the key
# is purely local (write a file into the container, export its path). Authorization
# lives on each host's authorized_keys, and production's list is declared in the
# private companion repo, not in this one.
#
# The distinct identity (comment `zimmer-production-operator`) is what makes any of it
# revocable: one line out of a key list, with no effect on the Kamal deploy key.
# See docs/operate/ssh-access.md#who-is-authorized-where.
class OperatorSshKeyProvisioner
  # Name of the env var carrying the key material.
  ENV_VAR = "ZIMMER_OPERATOR_SSH_KEY"

  # Zimmer's own filename, never the conventional id_ed25519 (see above).
  KEY_FILENAME = "zimmer_operator_ed25519"

  # A complete private key of any flavor ssh2 accepts (OpenSSH, RSA, EC, …). Header
  # AND footer, so a PEM truncated at its first newline — precisely what the base64
  # hop exists to prevent, and what a hand-set raw-PEM env var through Docker would
  # produce — is rejected with a clear warning instead of written out as a key file
  # that ssh2 later fails to parse for reasons nobody can trace.
  #
  # Matched as a pattern rather than compared against a spelled-out header, so that no
  # line in this repo — source, test, or fixture — reads as a private-key header
  # itself. That is what secret scanners flag, and what a reviewer greps the history
  # for to prove no key was committed.
  PEM = /\A-----BEGIN [A-Z0-9 ]+PRIVATE KEY-----.*-----END [A-Z0-9 ]+PRIVATE KEY-----\s*\z/m

  # Serializes the write. Sessions spawn concurrently on GoodJob's `agents` threads,
  # and they all provision the same path.
  MUTEX = Mutex.new

  class << self
    # Write the operator key to ~/.ssh/zimmer_operator_ed25519 if key material is
    # configured.
    #
    # Idempotent and safe to call on every boot and every session spawn: it rewrites
    # the file only when the content differs, and always reasserts 0700/0600.
    #
    # Best-effort by design — a missing or malformed key must never break a boot or a
    # spawn. It degrades to "sessions cannot SSH", exactly the state before this class
    # existed, and says so in the log.
    #
    # @param home [String] the home directory to provision into (defaults to $HOME)
    # @param logger [Logger] where to report
    # @return [String, nil] absolute path to the key, or nil when none was provisioned
    def ensure!(home: Dir.home, logger: Rails.logger)
      material = ENV[ENV_VAR].presence
      return nil if material.blank?

      pem = decode(material)
      if pem.nil?
        logger.warn "#{ENV_VAR} is set but is not a complete private key (nor base64 of one) — sessions will have no SSH identity"
        return nil
      end

      MUTEX.synchronize { write_key(pem, home: home, logger: logger) }
    rescue => e
      logger.warn "Failed to provision the operator SSH key: #{e.class} - #{e.message}"
      nil
    end

    # Path the key is (or would be) written to, without provisioning it.
    # @param home [String] the home directory
    # @return [String] absolute path to the key file
    def key_path(home: Dir.home)
      File.join(home, ".ssh", KEY_FILENAME)
    end

    private

    # Accept both a raw PEM and base64 of one, and normalize to a PEM with the
    # trailing newline OpenSSH's parser requires.
    #
    # @return [String, nil] the PEM, or nil if the material is neither
    def decode(material)
      stripped = material.strip
      return ensure_trailing_newline(stripped) if stripped.match?(PEM)

      decoded = Base64.strict_decode64(stripped.gsub(/\s+/, "")).strip
      return nil unless decoded.match?(PEM)

      ensure_trailing_newline(decoded)
    rescue ArgumentError
      nil
    end

    def ensure_trailing_newline(pem)
      pem.end_with?("\n") ? pem : "#{pem}\n"
    end

    # Write atomically (unique tmp file + rename) so a concurrent reader — an MCP
    # server starting up in another session — never sees a half-written key, and two
    # concurrent writers never share a tmp path. The tmp file is created 0600 up
    # front rather than chmod'd afterwards: `File.write` would create it 0644 under
    # the default umask, leaving the private key world-readable for that window.
    def write_key(pem, home:, logger:)
      ssh_dir = File.join(home, ".ssh")
      path = File.join(ssh_dir, KEY_FILENAME)

      FileUtils.mkdir_p(ssh_dir)
      File.chmod(0o700, ssh_dir)

      if File.exist?(path) && File.read(path) == pem
        File.chmod(0o600, path)
        return path
      end

      tmp = "#{path}.#{Process.pid}.#{SecureRandom.hex(4)}"
      begin
        File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(pem) }
        File.rename(tmp, path)
      rescue
        FileUtils.rm_f(tmp)
        raise
      end

      logger.info "Provisioned the operator SSH key at #{path} (0600)"
      path
    end
  end
end
