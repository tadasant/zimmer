# frozen_string_literal: true

# Gives a session's clone a working bundle, in the background, so the agent can start
# reading and editing immediately instead of waiting on ~300 gems.
#
# Two invariants are load-bearing (zimmer#410). Read them before changing anything in this
# file, because the obvious simplification breaks one of them.
#
# 1. **A clone is never pinned to a bundle that is not there.**
#
#    Bundler reads `<clone>/.bundle/config`, and a `BUNDLE_PATH` in that file **overrides
#    the environment** — verified, not assumed: with the file saying `vendor/bundle` and
#    `BUNDLE_PATH=/usr/local/bundle` exported, `bundle config get path` reports the file's
#    value as "the top value will be used". A config written before the gems exist therefore
#    pins the clone at a directory that cannot satisfy it, and every Ruby command in that
#    clone dies with `Bundler::GemNotFound` listing gems that are installed in the image.
#
#    So `BUNDLE_PATH` reaches the subprocesses **through the environment only**, and
#    `.bundle/config` is written **last**, after `bundle check` confirms the path it is
#    about to name really does satisfy the Gemfile. `bundle install` driven that way
#    persists no config of its own — a property `bundle install writes no .bundle/config
#    when BUNDLE_PATH comes from the environment` pins with a real bundler run, because a
#    Bundler release that changed it would silently restore the whole failure. A job killed
#    at any point leaves a partial `vendor/bundle` and *no* config: a clone that is slow,
#    not a clone that is broken.
#
# 2. **An interrupted install resumes.**
#
#    A deploy or a SIGTERM must not end an install for good, so failures retry — quietly
#    and boundedly, see the `rescue_from` below — and a bundle that comes out incomplete
#    raises `IncompleteBundleError` so that it retries too.
#
# The fast path below usually means there is nothing to interrupt at all: a clone of
# Zimmer's own repo at a commit that has not touched the Gemfile resolves straight out of
# the image's `/usr/local/bundle`, which already holds every gem in the lockfile including
# the development/test groups. No download, no `vendor/bundle`, no window.
class BundleInstallJob < ApplicationJob
  include DatabaseRetry

  queue_as :maintenance

  # Raised when `bundle install` returns, but `bundle check` says the bundle it produced
  # does not satisfy the Gemfile. Retried like any other failure: the common cause is an
  # install that was cut short, and the common cure is running it again.
  class IncompleteBundleError < StandardError; end

  # Total executions, including the first. Three is enough to ride out a deploy (the case
  # this exists for — an interrupted job is re-enqueued once and succeeds) without turning
  # a genuinely impossible install into an unbounded loop on the maintenance queue.
  MAX_ATTEMPTS = 3

  # Backoff between attempts. Long enough that a retry lands after the deploy that
  # interrupted it has finished, rather than into the tail of the same shutdown.
  RETRY_WAIT = 30.seconds

  # The keys this job is willing to own in `.bundle/config` — the two it writes, plus the
  # one `bundle config set --local deployment` can write alongside them, which is how the
  # pre-#410 job produced its configs. A file whose keys are a subset of these is one this
  # job wrote, which is what makes it safe to delete when it turns out to name an unusable
  # bundle. A file with any other key belongs to the repository and is left alone.
  MANAGED_CONFIG_KEYS = %w[BUNDLE_PATH BUNDLE_DEPLOYMENT BUNDLE_FROZEN].freeze

  # Retry quietly instead of `retry_on`.
  #
  # `retry_on ..., attempts: N` instruments `:retry_stopped` when the budget runs out, and
  # ActiveJob's LogSubscriber subscribes that event at ERROR — which trips the "any Zimmer
  # ERROR → critical" Grafana rule. That is the same trap `ApplicationJob.discard_interrupt_quietly`
  # documents for `discard_on`. A bare `rescue_from` + `retry_job` re-enqueues without
  # instrumenting anything, so exhaustion lands at WARN where it belongs.
  #
  # Registered AFTER the inherited `discard_interrupt_quietly` handler, and deliberately
  # not re-registering it: `GoodJob::InterruptError < StandardError`, rescue handlers
  # resolve last-registered-wins, so interrupts land here and are retried. That is the
  # point — resuming after a deploy is what invariant 2 is. Deploy interrupts stay off the
  # ERROR channel because this handler never logs above WARN, and because it never lets an
  # exception of its own escape: one raised out of a `rescue_from` block is reported by
  # ActiveJob's LogSubscriber as "Error performing …" at ERROR, which is the one way this
  # design could still trip the alert it exists to avoid.
  rescue_from(StandardError) do |error|
    if executions < MAX_ATTEMPTS
      Rails.logger.info(
        "[BundleInstallJob] attempt #{executions}/#{MAX_ATTEMPTS} failed with " \
        "#{error.class.name}: #{error.message}. Retrying in #{RETRY_WAIT.to_i}s."
      )
      begin
        retry_job(wait: RETRY_WAIT, error: error)
      rescue StandardError => e
        # `retry_job` writes to Postgres. If that write is what failed, GoodJob leaves the
        # row unfinished and picks it up again anyway, so swallowing this costs nothing and
        # keeps the ERROR line off the wire.
        Rails.logger.warn("[BundleInstallJob] could not re-enqueue: #{e.class}: #{e.message}")
      end
    else
      Rails.logger.warn(
        "[BundleInstallJob] giving up after #{executions} attempts: " \
        "#{error.class.name}: #{error.message}"
      )
      # Handled, so it does not page — but an unexpected error in here would otherwise
      # reach nothing at all, the session log line being its only other trace.
      Rails.error.report(error, handled: true, source: "BundleInstallJob")
      record_give_up(error)
    end
  end

  # Restores what the broad handler above would otherwise shadow. ActiveSupport resolves
  # rescue handlers last-registered-wins, so without this line a subclass `rescue_from
  # StandardError` silently replaces `ApplicationJob`'s `retry_on
  # ActiveRecord::StatementTimeout` — and `DatabaseRetry` excludes `QueryAborted` from its
  # own retry list precisely *because* that inherited handler is there. A database timeout
  # is not a bundle problem and does not want this job's flat 30s ladder.
  retry_on ActiveRecord::StatementTimeout, wait: :exponentially_longer, attempts: 5

  # @param session_id [Integer] The session ID (for logging context)
  # @param working_directory [String] The directory containing the Gemfile
  def perform(session_id, working_directory)
    @session = Session.find_by(id: session_id)
    return unless @session

    # Skip if session is no longer active (archived, failed)
    # The clone directory may be deleted or in the process of being cleaned up
    return if @session.archived? || @session.failed?

    @working_directory = working_directory
    return unless File.exist?(gemfile_path)

    # A config left behind by an earlier attempt (or by this job before #410) can name a
    # bundle that is not there, and it would win over every BUNDLE_PATH set below. Clear
    # that first, so the rest of the job is deciding rather than arguing with a stale file.
    discard_unusable_bundle_config

    return if adopt_image_bundle

    install_into_vendor_bundle
  end

  private

  attr_reader :session, :working_directory

  def gemfile_path = File.join(working_directory, "Gemfile")

  def lockfile_path = File.join(working_directory, "Gemfile.lock")

  def bundle_config_path = File.join(working_directory, ".bundle", "config")

  # --- The fast path: resolve out of the image's bundle -----------------------------
  #
  # A clone of the app's own repo whose Gemfile and Gemfile.lock are byte-identical to the
  # ones the image was built from needs no gems of its own: `/usr/local/bundle` already has
  # them, dev and test groups included (the image sets `BUNDLE_WITHOUT=development`, and a
  # gem in `group :development, :test` is only excluded when *all* its groups are).
  #
  # This is the option zimmer#410 called the highest-risk of the three, because pointing a
  # clone's config at a bundle that does not in fact satisfy it reproduces the exact
  # symptom being fixed. So it is never taken on the strength of the lockfile comparison
  # alone: `bundle check` has to pass against that bundle first, and only then is the
  # config written. Every reason to bail returns false and falls through to a normal
  # install.
  #
  # @return [Boolean] true if the clone was pointed at the image bundle
  def adopt_image_bundle
    bundle_path = image_bundle_path
    return false if bundle_path.blank?
    return false unless lockfile_matches_image?

    # Reaching here means the clone is byte-identical to the image and the shared bundle
    # still ought to satisfy it. If it does not — a Gemfile group the image was built
    # without, a ruby version bump — every clone silently reverts to a two-minute install
    # and nothing else would say so. Log it: a fast path that has gone quietly dead is
    # otherwise indistinguishable from one that was never written.
    unless bundle_satisfied?(bundler_env(bundle_path))
      Rails.logger.info(
        "[BundleInstallJob] #{bundle_path} no longer satisfies an identical Gemfile; " \
        "falling back to a per-clone vendor/bundle"
      )
      return false
    end

    write_bundle_config(bundle_path)
    log_to_session(
      "Bundle ready: this clone's Gemfile.lock matches the image, so it resolves gems " \
      "from #{bundle_path} instead of installing its own copy",
      level: "info"
    )
    true
  end

  # Where the running app's own gems live, as a value that can be *assigned to*
  # `BUNDLE_PATH` — or nil if that cannot be established safely.
  #
  # Read off Bundler rather than restated from the Dockerfile, so it stays right if the
  # image moves. It has to be `settings[:path]`, the configured base, and **not**
  # `Bundler.bundle_path`: the latter is the resolved directory with the ruby scope already
  # appended (`/usr/local/bundle/ruby/3.4.0`), and Bundler appends that scope again to
  # whatever `BUNDLE_PATH` names — so feeding it back in would point a clone at
  # `…/ruby/3.4.0/ruby/3.4.0`. `bundle check` would catch it and the fast path would go
  # quietly dead, which is the failure worth naming here because nothing else would.
  #
  # nil when the deployment has not configured a shared bundle at all (a laptop, most CI
  # runners): there is nothing to share, so every clone installs its own.
  #
  # Three further refusals, each of which would otherwise hand a clone a config it cannot use:
  #
  #   - a relative path (`BUNDLE_PATH=vendor/bundle`) would resolve against the *clone*,
  #     naming a directory that has nothing in it;
  #   - a path inside the clone is not a shared bundle, it is the slow path by another name;
  #   - a path that is not a directory is not a bundle at all.
  def image_bundle_path
    configured = Bundler.settings[:path]
    return nil if configured.blank?

    return nil unless Pathname.new(configured).absolute?

    path = File.expand_path(configured)
    return nil unless File.directory?(path)
    # Resolved, not merely expanded: a clone reachable through a symlink would otherwise
    # slip a clone-local directory past this and get an absolute path written into its
    # config, which is what the relative pin in the slow path exists to avoid.
    return nil if resolve(path).start_with?(resolve(working_directory) + File::SEPARATOR)

    path
  rescue StandardError => e
    # Bundler is always loaded inside the app, but a fast path that cannot be established
    # is not an error — it is a normal install.
    Rails.logger.info("[BundleInstallJob] no image bundle to share: #{e.class}: #{e.message}")
    nil
  end

  # Symlinks resolved, falling back to plain expansion for a path that cannot be resolved
  # (a component that does not exist, a permission the session lacks).
  def resolve(path)
    File.realpath(path)
  rescue SystemCallError
    File.expand_path(path)
  end

  # Both files, byte for byte. The lockfile alone is not enough: `bundle check` evaluates
  # the *Gemfile*, so a clone that resolved the same gems through a different Gemfile
  # (different groups, a different platform block) can still ask for something the image
  # bundle was not built to answer.
  def lockfile_matches_image?
    files_identical?(gemfile_path, Rails.root.join("Gemfile").to_s) &&
      files_identical?(lockfile_path, Rails.root.join("Gemfile.lock").to_s)
  end

  def files_identical?(one, other)
    return false unless File.file?(one) && File.file?(other)

    File.binread(one) == File.binread(other)
  rescue SystemCallError
    false
  end

  # --- The slow path: a bundle of the clone's own ------------------------------------

  def install_into_vendor_bundle
    vendor_path = File.join(File.expand_path(working_directory), "vendor", "bundle")
    env = bundler_env(vendor_path)

    _stdout, stderr, status = Open3.capture3(
      env,
      "bundle", "install",
      "--jobs", "4",
      "--retry", "3",
      chdir: working_directory
    )

    # The exit code is not the question — whether the clone can now resolve its gems is.
    # An install that reports success but leaves the bundle short (a killed child, a
    # partially written gem) must not get a config written for it, and an install that
    # reports failure after the gems all landed should not be retried for nothing.
    unless bundle_satisfied?(env)
      # The install's own status is context, not the verdict — it is routinely 0 here,
      # which is the whole reason `bundle check` is asked as well.
      raise IncompleteBundleError,
        "bundle check says the bundle is incomplete after install (install reported " \
        "#{SubprocessStatus.describe_failure(status, stderr.lines.first(3).join.truncate(200))})"
    end

    # Relative, so the config keeps working if the clone is ever relocated or forked to a
    # new path — `.bundle/config` travels with the copy, and an absolute path in it would
    # name the *source* clone's tree.
    write_bundle_config("vendor/bundle")
    log_to_session("Background bundle install completed successfully", level: "info")
  end

  # --- Bundler plumbing ---------------------------------------------------------------

  # The environment every bundler subprocess here runs under.
  #
  # The container exports `BUNDLE_PATH=/usr/local/bundle` and friends for the *app*, and a
  # clone's bundler must not inherit them, so the whole BUNDLE* family is cleared and only
  # what this job decides is put back. `BUNDLE_APP_CONFIG` aims bundler's config at the
  # clone's own `.bundle`, never `~/.bundle` or the image's.
  #
  # `GEM_HOME` / `GEM_PATH` go too, for the same reason `CliSpawnEnv` strips them from an
  # agent's environment: they are the *other* way the app's gems leak into a clone, and
  # leaving them set would have this job resolve against a bundle the agent's own commands
  # never see. Matching that environment is what lets the probe in
  # `discard_unusable_bundle_config` stand in for "what the agent's `bin/rails` would hit".
  #
  # @param bundle_path [String, nil] where this invocation should resolve (and install)
  #   gems; nil leaves BUNDLE_PATH unset, so the clone's own `.bundle/config` decides
  def bundler_env(bundle_path)
    clean_env = ENV.to_h
    clean_env.each_key do |k|
      clean_env[k] = nil if k.start_with?("BUNDLE") || %w[RUBYOPT GEM_HOME GEM_PATH].include?(k)
    end
    clean_env["BUNDLE_APP_CONFIG"] = File.join(working_directory, ".bundle")
    clean_env["BUNDLE_PATH"] = bundle_path
    # The image sets BUNDLE_DEPLOYMENT=1, which would make a clone refuse to install
    # anything its lockfile does not already pin. Clones are working trees, not deploys.
    clean_env["BUNDLE_DEPLOYMENT"] = "false"
    clean_env
  end

  # Does the bundle named by +env+ satisfy this clone's Gemfile?
  def bundle_satisfied?(env)
    _stdout, _stderr, status = Open3.capture3(env, "bundle", "check", chdir: working_directory)
    SubprocessStatus.success?(status)
  end

  # Publish the pin. Called only after `bundle_satisfied?` has said yes for this path.
  #
  # Written directly rather than through `bundle config set --local`, because that shells
  # out twice more and — the reason that matters — it writes the file as a side effect of
  # succeeding at something else — which is how a config comes to name a bundle that does
  # not exist.
  def write_bundle_config(bundle_path)
    FileUtils.mkdir_p(File.dirname(bundle_config_path))
    # A repository can track `.bundle/config` as a symlink, and `File.write` follows one, so
    # a clone could otherwise aim this write at any file the session can reach.
    File.unlink(bundle_config_path) if File.symlink?(bundle_config_path)
    # Serialized rather than interpolated: a clone path containing a quote or a backslash
    # would produce YAML bundler reads as something else entirely.
    File.write(
      bundle_config_path,
      { "BUNDLE_PATH" => bundle_path.to_s, "BUNDLE_DEPLOYMENT" => "false" }.to_yaml
    )
  end

  # Delete a `.bundle/config` that names a bundle the clone cannot actually use.
  #
  # Scoped two ways so this can never eat something it did not write: the file has to
  # contain nothing but this job's own keys, and it has to actually fail `bundle check`.
  # A config that works is left exactly where it is — including a repository's own.
  def discard_unusable_bundle_config
    return unless File.file?(bundle_config_path)
    return unless managed_bundle_config?
    # No BUNDLE_PATH in the env, so the file itself decides where bundler looks — which is
    # the state an agent's own `bin/rails` would hit.
    return if bundle_satisfied?(bundler_env(nil))

    File.delete(bundle_config_path)
    Rails.logger.info(
      "[BundleInstallJob] removed #{bundle_config_path}: it pinned the clone to a bundle " \
      "that does not satisfy its Gemfile"
    )
  rescue SystemCallError => e
    # Worth continuing for: the install below may still succeed and rewrite the file.
    Rails.logger.warn("[BundleInstallJob] could not clear #{bundle_config_path}: #{e.message}")
  end

  def managed_bundle_config?
    parsed = YAML.safe_load_file(bundle_config_path)
    parsed.is_a?(Hash) && parsed.keys.all? { |key| MANAGED_CONFIG_KEYS.include?(key) }
  rescue StandardError
    # Unparseable is not ours.
    false
  end

  # --- Reporting ----------------------------------------------------------------------

  def log_to_session(content, level:)
    with_db_retry { session.logs.create!(content: content, level: level) }
  end

  # The last attempt has failed. Say so where the agent can see it — the session log is the
  # only surface this job has — and say what to do about it, because the clone is now in
  # the honest "gems are not installed" state rather than the old pinned-and-broken one.
  def record_give_up(error)
    session = Session.find_by(id: arguments.first)
    return unless session

    with_db_retry do
      session.logs.create!(
        content: "Background bundle install failed after #{MAX_ATTEMPTS} attempts " \
                 "(#{error.class.name}: #{error.message.truncate(200)}). Gems are not " \
                 "installed. To finish it by hand, run `bundle config set --local path " \
                 "vendor/bundle && bundle install` in the clone — a bare `bundle install` " \
                 "has nowhere writable to put them.",
        level: "warning"
      )
    end
  rescue StandardError => e
    Rails.logger.warn("[BundleInstallJob] could not record give-up: #{e.class}: #{e.message}")
  end
end
