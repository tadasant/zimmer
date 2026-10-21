# frozen_string_literal: true

require "digest"

# Which GitHub token authenticates a call to which repository owner.
#
# ## Why more than one token
#
# A fine-grained personal access token (`github_pat_…`) is bound to ONE resource
# owner — a user or an organization — and cannot read or write anything private
# anywhere else. That is the point of using them: the `gh auth login` OAuth token
# (`gho_…`) and a classic PAT (`ghp_…`) reach every organization the account
# belongs to, including ones the operator wants nothing in Zimmer to touch.
#
# One owner per token means one token per owner, so Zimmer holds a small map:
#
#   GH_TOKEN                 the default token, for the default owner
#   GH_TOKEN__<OWNER>        one per further owner — GH_TOKEN__PULSEMCP for `pulsemcp`
#
# all resolved through the `${VAR}` chain by GhTokenProvisioner (canonical store path
# /zimmer/{env}/secrets/static/GH_TOKEN__<OWNER>) and published into the process
# environment. The variable name is the owner upper-cased with `-` folded to `_`;
# GitHub owner names are ASCII letters, digits and single hyphens, so the fold never
# collides.
#
# ## The routing rule
#
# For a repository owned by `owner`:
#
#   1. GH_TOKEN__<OWNER>, when set.
#   2. Otherwise GH_TOKEN — but only when `owner` IS the default owner
#      (ZIMMER_GITHUB_DEFAULT_OWNER), or when no default owner is configured at all.
#   3. Otherwise nothing. The call goes out unauthenticated, which for a private
#      repository fails closed.
#
# Rule 2's "no default configured" arm is what lets a single-token deployment —
# staging, a self-hoster, dev — run on GH_TOKEN alone: it authenticates every owner.
#
# The same rule is implemented twice, here and in `bin/zimmer-git-credential` (git
# spawns its credential helper itself, with no Ruby in reach). The helper's test
# drives the script against the same cases this module's test does, so the two
# cannot drift silently.
#
# ## Routing mode vs. the stored login
#
# A deployment that has never been given a token still authenticates through
# `gh auth login`'s stored credential in ~/.config/gh. GhTokenProvisioner sets
# ZIMMER_GITHUB_CREDENTIAL_ROUTING=1 once it has published at least one token; until then
# the git helper delegates to `gh auth git-credential`, so a deployment with no token
# seeded authenticates through its stored login. Once the flag is up, the helper never
# consults the stored login again. The flag's name deliberately avoids TOKEN, KEY and
# SECRET, which runtimes that filter credential-looking variables (Codex's
# shell_environment_policy) strip from a session's shell.
module GithubTokens
  DEFAULT_VARIABLE = "GH_TOKEN"
  OWNER_VARIABLE_PREFIX = "GH_TOKEN__"
  DEFAULT_OWNER_VARIABLE = "ZIMMER_GITHUB_DEFAULT_OWNER"
  ROUTING_VARIABLE = "ZIMMER_GITHUB_CREDENTIAL_ROUTING"

  # GitHub's own constraint on user and organization names. Anything else is not an
  # owner, and must never be folded into an environment variable name.
  OWNER_FORMAT = /\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\z/

  # https://github.com/owner/repo(.git), ssh://git@github.com/owner/repo, git@github.com:owner/repo
  GITHUB_URL_PATTERN = %r{\A(?:https?://(?:[^@/]+@)?github\.com/|ssh://git@github\.com/|git@github\.com:)([^/]+)/}i

  module_function

  # @return [String, nil] the environment variable holding `owner`'s own token
  def variable_for(owner)
    owner = owner.to_s
    return nil unless owner.match?(OWNER_FORMAT)

    "#{OWNER_VARIABLE_PREFIX}#{owner.upcase.tr('-', '_')}"
  end

  # Whether `name` is an owner-suffixed token variable (GH_TOKEN__PULSEMCP).
  def owner_variable?(name)
    name = name.to_s
    name.start_with?(OWNER_VARIABLE_PREFIX) && name.length > OWNER_VARIABLE_PREFIX.length &&
      name.match?(/\A#{OWNER_VARIABLE_PREFIX}[A-Z0-9_]+\z/o)
  end

  # The owner name a variable stands for, lower-cased — GH_TOKEN__PULSEMCP → "pulsemcp".
  # The fold loses case and the `-`/`_` distinction; GitHub owners are matched
  # case-insensitively and cannot contain `_`, so neither loss is ambiguous.
  def owner_for_variable(name)
    return nil unless owner_variable?(name)

    name.delete_prefix(OWNER_VARIABLE_PREFIX).downcase.tr("_", "-")
  end

  # @return [String, nil] the repository owner of a github.com URL, or nil for
  #   anything that is not one (a local path, another host)
  def owner_from_url(url)
    owner = url.to_s.strip[GITHUB_URL_PATTERN, 1]
    owner if owner&.match?(OWNER_FORMAT)
  end

  # @return [String, nil] the owner of an "owner/repo" slug
  def owner_from_slug(slug)
    owner = slug.to_s.split("/", 2).first
    owner if owner&.match?(OWNER_FORMAT)
  end

  def default_owner(env: ENV)
    env[DEFAULT_OWNER_VARIABLE].presence&.strip
  end

  # Whether GhTokenProvisioner has published a token map. Before it has, the stored
  # `gh auth login` credential is still the deployment's GitHub identity.
  def routing?(env: ENV)
    env[ROUTING_VARIABLE].present?
  end

  # The variable whose token authenticates calls to `owner` — the routing rule above.
  #
  # @param owner [String, nil] nil means "no particular owner" (a search across
  #   repositories, `gh auth status`), which the default token answers
  # @return [String, nil] nil when no token may be used for this owner
  def variable_for_owner(owner, env: ENV)
    own = variable_for(owner)
    return own if own && env[own].present?
    return nil if env[DEFAULT_VARIABLE].blank?

    default = default_owner(env: env)
    return DEFAULT_VARIABLE if owner.nil? || default.nil? || owner.to_s.casecmp?(default)

    nil
  end

  # @return [String, nil] the token itself. Never log it.
  def token_for(owner, env: ENV)
    variable = variable_for_owner(owner, env: env)
    variable && env[variable].presence
  end

  # Extra environment for a `gh` child process acting on `owner`'s repositories:
  # GH_TOKEN overridden with the owner's own token when it has one, and nothing
  # otherwise.
  #
  # "Nothing" means the child inherits the worker's GH_TOKEN — the default token —
  # even for an owner rule 2 would refuse it to. That is deliberate. Unsetting it
  # would not make the call fail closed: `gh` would fall back to the stored
  # `gh auth login` credential, which reaches every organization the account is in.
  # The default fine-grained token, by construction, reaches nothing private outside
  # its own owner, so inheriting it IS the closed answer.
  #
  # @return [Hash{String => String}]
  def env_for(owner, env: ENV)
    own = variable_for(owner)
    return {} unless own && env[own].present?

    { DEFAULT_VARIABLE => env[own] }
  end

  # The GitHub environment for an agent session working on `owner`'s repository.
  #
  # The session's GH_TOKEN becomes its owner's token, every GH_TOKEN__* is removed,
  # and ZIMMER_GITHUB_DEFAULT_OWNER is pinned to the session's owner. That last step
  # is what makes the git helper inside the session route only that owner to its
  # GH_TOKEN: a session working on tadasant/zimmer is handed the tadasant token and
  # nothing else, so its `git push` to a pulsemcp repository fails.
  #
  # GH_CONFIG_DIR points at a directory holding no login, so `gh` in the session can
  # never fall back to the stored `gh auth login` credential — the OAuth token that
  # reaches every organization. That matters most for a session whose owner has no
  # token: it gets no GH_TOKEN at all, and without this its `gh` would read the
  # stored login. Its git helper fails closed on its own, because
  # ZIMMER_GITHUB_CREDENTIAL_ROUTING stays set.
  #
  # This is defense in depth, not isolation. A session runs as the same user as the
  # worker, so a determined process can still read the full map from another
  # process's /proc/<pid>/environ, or the stored login from ~/.config/gh. What it
  # removes is every path by which the session's own `git` and `gh` use a token that
  # is not its owner's.
  #
  # Before routing is on there is no map to narrow, so the session inherits the
  # worker's environment unchanged.
  #
  # @param owner [String, nil] the owner of the session's repository; nil for a
  #   repository that is not on github.com
  # @param gh_config_dir [String] the login-free gh config directory
  # @return [Hash{String => String, nil}] nil values unset the variable in the child
  def session_env(owner, env: ENV, gh_config_dir: empty_gh_config_dir)
    return {} unless routing?(env: env)

    token = token_for(owner, env: env)
    result = env.keys.select { |key| owner_variable?(key) }.index_with(nil)
    result[DEFAULT_VARIABLE] = token
    result[DEFAULT_OWNER_VARIABLE] = owner.presence
    result["GH_CONFIG_DIR"] = gh_config_dir
    result
  end

  # A gh config directory with no login in it, shared by every routed session. `gh`
  # writes its own state files here; it never holds a credential, because every
  # session that uses it authenticates through GH_TOKEN or not at all.
  def empty_gh_config_dir
    Rails.root.join("tmp", "gh-config-routed").to_s.tap { |dir| FileUtils.mkdir_p(dir) }
  end

  # The owner of the repository checked out at `working_dir`, read from its `origin`
  # remote. The spawn paths have the working directory in hand for every runtime and
  # for a warm process booted before any session exists; a Session row they do not.
  #
  # @return [String, nil] nil when the directory is not a clone of a github.com
  #   repository or its remote cannot be read
  def owner_for_working_directory(working_dir)
    return nil if working_dir.blank? || !File.directory?(working_dir.to_s)

    stdout, _stderr, status = BoundedSubprocess.run(
      [ "git", "-C", working_dir.to_s, "config", "--get", "remote.origin.url" ],
      timeout: 5
    )
    return nil unless SubprocessStatus.success?(status)

    owner_from_url(stdout.strip)
  rescue StandardError
    nil
  end

  # A digest of the whole map, for a caller that has to notice a rotation without
  # holding a token: the warm process pool, whose processes boot with a session
  # environment and would otherwise carry a rotated-out token for up to an hour.
  def fingerprint(env: ENV)
    variables = [ DEFAULT_VARIABLE, DEFAULT_OWNER_VARIABLE, ROUTING_VARIABLE ] +
                env.keys.select { |key| owner_variable?(key) }.sort
    Digest::SHA256.hexdigest(variables.map { |key| "#{key}=#{env[key]}" }.join("\n"))
  end

  # Every owner-suffixed variable currently published, as { owner => variable }.
  def owner_variables(env: ENV)
    env.keys.select { |key| owner_variable?(key) && env[key].present? }
       .to_h { |key| [ owner_for_variable(key), key ] }
  end
end
