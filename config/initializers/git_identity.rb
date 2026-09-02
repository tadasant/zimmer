# Git Identity Initializer
#
# Writes `[user]` (ZIMMER_GIT_USER_NAME / ZIMMER_GIT_USER_EMAIL) into the container's
# global git config when it boots, so an identity exists before the first session
# spawns — and the first `git commit` of a committing session succeeds instead of
# exiting 128 with "Author identity unknown" (#575).
#
# Boot is the only moment it needs to run, unlike the operator SSH key and the `gh`
# token, which reassert themselves on the spawn path too. Those two carry a *secret*
# that can rotate under a long-lived worker; this carries a deploy-time constant, and
# a changed value arrives the way every other `env.clear` value does — on the next
# deploy, which restarts the container and runs this again.
#
# A no-op wherever the variables aren't configured (dev, test, CI, a self-hoster who
# has their own `~/.gitconfig`), and never fatal: GitIdentityProvisioner.ensure!
# swallows and logs.
Rails.application.config.after_initialize do
  next if Rails.env.test?

  GitIdentityProvisioner.ensure!
end
