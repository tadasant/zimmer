# Operator SSH Key Initializer
#
# Materializes the operator SSH private key (ZIMMER_OPERATOR_SSH_KEY) at
# ~/.ssh/zimmer_operator_ed25519 when the container boots, so an SSH identity exists
# before the first session spawns — and so `docker exec … ssh -i …` works for a human
# debugging the box the same way it works for an agent.
#
# CliSpawnEnv#apply_operator_ssh_key re-runs the same (idempotent) provisioning at
# every spawn, which is what actually guarantees the key for a session. This boot
# pass is the belt to that suspenders: it makes the key's presence a property of the
# container rather than of whether a session has run yet.
#
# A no-op wherever the secret isn't configured (dev, test, CI, a fork that never set
# it), and never fatal: OperatorSshKeyProvisioner.ensure! swallows and logs.
Rails.application.config.after_initialize do
  next if Rails.env.test?

  OperatorSshKeyProvisioner.ensure!
end
