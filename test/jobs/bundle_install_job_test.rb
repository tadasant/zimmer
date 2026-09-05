# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class BundleInstallJobTest < ActiveJob::TestCase
  # Stands in for the two bundler subcommands this job runs, answering per subcommand and
  # recording what it was asked.
  #
  # A hand-rolled double rather than a Mocha stub because the assertions that matter are
  # about *order* — which subcommand ran, with which BUNDLE_PATH, and whether the config
  # file existed at that moment. Mocha's `returns` is a sequence, so encoding "the check
  # after the install succeeds, the one before it fails" in it would say less than this and
  # break whenever the number of calls changes.
  class BundlerDouble
    Call = Struct.new(:env, :argv, :chdir, :config_existed, keyword_init: true)

    attr_reader :calls

    # @param install [true, false, Proc] `bundle install` succeeds, fails, or raises
    # @param checks [Array<Boolean>] `bundle check` results in order; the last one repeats
    # @param config_path [String] watched so each call records whether the pin was published
    def initialize(install:, checks:, config_path:)
      @install = install
      @checks = checks.dup
      @config_path = config_path
      @calls = []
    end

    def capture3(env, *argv, **options)
      @calls << Call.new(
        env: env,
        argv: argv,
        chdir: options[:chdir],
        config_existed: File.exist?(@config_path)
      )

      case argv[1]
      when "install" then run_install
      when "check" then [ "", "", status(next_check) ]
      else [ "", "", status(true) ]
      end
    end

    def subcommands = calls.map { |call| call.argv[1] }

    def call_for(subcommand) = calls.find { |call| call.argv[1] == subcommand }

    private

    def run_install
      return @install.call if @install.respond_to?(:call)

      [ "", "", status(@install) ]
    end

    def next_check = @checks.size > 1 ? @checks.shift : @checks.first

    # Enough of a Process::Status for SubprocessStatus to read.
    def status(success)
      Class.new do
        def initialize(success) = @success = success
        def success? = @success
        def exitstatus = @success ? 0 : 5
        def termsig = nil
      end.new(success)
    end
  end

  setup do
    @session = sessions(:running)
    @working_directory = Dir.mktmpdir
    # Create a Gemfile so the job runs
    File.write(File.join(@working_directory, "Gemfile"), "source 'https://rubygems.org'\n")

    # No shared bundle unless a test asks for one, so every assertion that is not about the
    # fast path goes down the ordinary install.
    Bundler.stubs(:settings).returns({ path: nil })

    @original_capture3 = Open3.method(:capture3)
  end

  teardown do
    Open3.define_singleton_method(:capture3, @original_capture3) if @original_capture3
    FileUtils.rm_rf(@working_directory) if @working_directory && Dir.exist?(@working_directory)
    FileUtils.rm_rf(@image_bundle) if @image_bundle && Dir.exist?(@image_bundle)
  end

  # --- what the job already had to do ------------------------------------------------

  test "job completes successfully when bundle install succeeds" do
    stub_bundler

    assert_difference -> { @session.logs.count }, 1 do
      BundleInstallJob.perform_now(@session.id, @working_directory)
    end

    log = @session.logs.last
    assert_equal "info", log.level
    assert_match(/completed successfully/, log.content)
  end

  test "job does nothing if Gemfile does not exist" do
    File.delete(File.join(@working_directory, "Gemfile"))
    stub_bundler

    assert_no_difference -> { @session.logs.count } do
      BundleInstallJob.perform_now(@session.id, @working_directory)
    end
    assert_empty @bundler.calls
  end

  test "job does nothing if session does not exist" do
    stub_bundler

    assert_nothing_raised do
      BundleInstallJob.perform_now(999999, @working_directory)
    end
  end

  test "job does nothing if session is archived" do
    @session.update!(status: :archived)
    stub_bundler

    assert_no_difference -> { @session.logs.count } do
      BundleInstallJob.perform_now(@session.id, @working_directory)
    end
  end

  test "job does nothing if session is failed" do
    @session.update!(status: :failed)
    stub_bundler

    assert_no_difference -> { @session.logs.count } do
      BundleInstallJob.perform_now(@session.id, @working_directory)
    end
  end

  # --- half one of #410: a clone is never pinned to a bundle that is not there --------
  #
  # `.bundle/config` overrides the image's BUNDLE_PATH, so a config naming a half-populated
  # vendor/bundle is strictly worse than no config at all: every Ruby command in the clone
  # then dies with Bundler::GemNotFound, listing gems that are installed in the image.

  test "an install killed partway leaves no .bundle/config behind" do
    # The interruption simulated where it actually happens — inside `bundle install`.
    # GoodJob raises this when it re-runs a job whose previous execution was cut short.
    stub_bundler(install: -> { raise GoodJob::InterruptError, "Interrupted after starting perform" })

    BundleInstallJob.perform_now(@session.id, @working_directory)

    assert_not File.exist?(bundle_config_path),
      "an interrupted install must not pin the clone to a bundle it never finished writing"
  end

  test "an install that finishes short of complete leaves no .bundle/config behind" do
    # `bundle install` exits 0, but the bundle it produced does not satisfy the Gemfile:
    # a genuinely half-populated vendor/bundle, which is the state the production clone in
    # #410 was left holding (378 MB and 18 gems short).
    stub_bundler(install: true, checks: [ false ])

    last_attempt.perform_now

    assert_not File.exist?(bundle_config_path),
      "a bundle that fails `bundle check` must not get a config written for it"
  end

  test "the pin is published only after bundle check confirms the bundle" do
    stub_bundler

    BundleInstallJob.perform_now(@session.id, @working_directory)

    assert_equal %w[install check], @bundler.subcommands
    assert_not @bundler.call_for("check").config_existed,
      "the config must not exist yet when the verifying check runs"
    assert_equal "---\nBUNDLE_PATH: \"vendor/bundle\"\nBUNDLE_DEPLOYMENT: \"false\"\n",
      File.read(bundle_config_path)
  end

  test "bundle install is driven by BUNDLE_PATH in the environment, not by a written config" do
    stub_bundler

    BundleInstallJob.perform_now(@session.id, @working_directory)

    install = @bundler.call_for("install")
    assert_not install.config_existed, "nothing may be pinned before the install runs"
    assert_equal File.join(@working_directory, "vendor", "bundle"), install.env["BUNDLE_PATH"]
    assert_equal File.join(@working_directory, ".bundle"), install.env["BUNDLE_APP_CONFIG"]
    assert_equal "false", install.env["BUNDLE_DEPLOYMENT"]
    assert_equal @working_directory, install.chdir
  end

  test "a stale pin naming an unusable bundle is cleared before the install runs" do
    # Exactly what the pre-#410 job left behind on an interrupt.
    write_config("---\nBUNDLE_PATH: \"vendor/bundle\"\nBUNDLE_DEPLOYMENT: \"false\"\n")
    # The probe of the stale config fails; the post-install check succeeds.
    stub_bundler(install: true, checks: [ false, true ])

    BundleInstallJob.perform_now(@session.id, @working_directory)

    assert_equal %w[check install check], @bundler.subcommands
    assert_nil @bundler.calls.first.env["BUNDLE_PATH"],
      "the probe must let the config file decide, the way an agent's own bin/rails does"
    assert_not @bundler.call_for("install").config_existed,
      "the stale pin must be gone before the install — it would otherwise override BUNDLE_PATH"
  end

  test "a pin that still works is left in place" do
    write_config("---\nBUNDLE_PATH: \"vendor/bundle\"\n")
    stub_bundler(install: true, checks: [ true, true ])

    BundleInstallJob.perform_now(@session.id, @working_directory)

    assert File.exist?(bundle_config_path)
  end

  test "a .bundle/config the repository owns is never probed or deleted" do
    write_config("---\nBUNDLE_PATH: \"vendor/bundle\"\nBUNDLE_JOBS: \"8\"\n")
    stub_bundler

    BundleInstallJob.perform_now(@session.id, @working_directory)

    assert_equal %w[install check], @bundler.subcommands,
      "a config carrying keys this job does not manage must be left alone"
  end

  # --- half two of #410: an interrupted install resumes ------------------------------

  test "an interrupt re-enqueues the job instead of discarding it" do
    stub_bundler(install: -> { raise GoodJob::InterruptError, "Interrupted after starting perform" })

    assert_enqueued_with(job: BundleInstallJob) do
      BundleInstallJob.perform_now(@session.id, @working_directory)
    end
  end

  test "an interrupt is retried without ever logging at ERROR" do
    # The property ApplicationJob.discard_interrupt_quietly exists to protect: a deploy
    # interrupts jobs routinely, and a single ERROR line trips the "any Zimmer ERROR →
    # critical" Grafana rule. Retrying must not reintroduce it — which is why this job uses a
    # bare rescue_from rather than `retry_on`, whose exhaustion path instruments :retry_stopped
    # and ActiveJob logs that at ERROR.
    stub_bundler(install: -> { raise GoodJob::InterruptError, "Interrupted after starting perform" })

    records = capture_log_records do
      BundleInstallJob.perform_now(@session.id, @working_directory)
      last_attempt.perform_now
    end

    assert_empty records.select { |severity, _| severity == "ERROR" },
      "a deploy interrupt must never reach the ERROR channel"
  end

  test "retries are bounded, and the final attempt reports to the session" do
    stub_bundler(install: -> { raise StandardError, "boom" })

    # perform_now increments `executions` itself, so executions=n-1 enters attempt n.
    (0...(BundleInstallJob::MAX_ATTEMPTS - 1)).each do |prior|
      job = BundleInstallJob.new(@session.id, @working_directory)
      job.executions = prior
      assert_enqueued_with(job: BundleInstallJob) { job.perform_now }
    end

    assert_no_enqueued_jobs(only: BundleInstallJob) do
      assert_difference -> { @session.logs.count }, 1 do
        last_attempt.perform_now
      end
    end

    log = @session.logs.last
    assert_equal "warning", log.level
    assert_match(/failed after #{BundleInstallJob::MAX_ATTEMPTS} attempts/, log.content)
    assert_match(/run `bundle install`/, log.content)
  end

  test "an exhausted job does not raise out of perform" do
    stub_bundler(install: -> { raise StandardError, "Unexpected error" })

    assert_nothing_raised { last_attempt.perform_now }
  end

  # --- the fast path: sharing the image's bundle -------------------------------------

  test "a clone matching the image shares its bundle and installs nothing" do
    share_image_bundle
    stub_bundler

    BundleInstallJob.perform_now(@session.id, @working_directory)

    assert_equal %w[check], @bundler.subcommands, "the fast path must not run an install"
    assert_equal @image_bundle, @bundler.call_for("check").env["BUNDLE_PATH"]
    assert_equal "---\nBUNDLE_PATH: \"#{@image_bundle}\"\nBUNDLE_DEPLOYMENT: \"false\"\n",
      File.read(bundle_config_path)
    assert_match(/resolves gems from #{Regexp.escape(@image_bundle)}/, @session.logs.last.content)
  end

  test "the image bundle is adopted only after bundle check proves it satisfies the clone" do
    share_image_bundle
    # The whole risk of this option, and the reason the check is not optional: a lockfile
    # that matches but a bundle that does not actually satisfy it would rebuild the exact
    # symptom being fixed.
    stub_bundler(install: true, checks: [ false, true ])

    BundleInstallJob.perform_now(@session.id, @working_directory)

    assert_equal %w[check install check], @bundler.subcommands
    assert_equal "---\nBUNDLE_PATH: \"vendor/bundle\"\nBUNDLE_DEPLOYMENT: \"false\"\n",
      File.read(bundle_config_path)
  end

  test "a clone whose Gemfile.lock differs from the image installs its own bundle" do
    share_image_bundle
    File.write(File.join(@working_directory, "Gemfile.lock"), "DIFFERENT\n")
    stub_bundler

    BundleInstallJob.perform_now(@session.id, @working_directory)

    assert_equal %w[install check], @bundler.subcommands
  end

  test "a clone whose Gemfile differs from the image installs its own bundle" do
    share_image_bundle
    File.write(File.join(@working_directory, "Gemfile"), "source 'https://rubygems.org'\n")
    stub_bundler

    BundleInstallJob.perform_now(@session.id, @working_directory)

    assert_equal %w[install check], @bundler.subcommands
  end

  test "a relative BUNDLE_PATH is never adopted as a shared bundle" do
    # A CI runner sets BUNDLE_PATH=vendor/bundle. Adopted literally it resolves against the
    # *clone*, naming a directory with nothing in it — the wedge, rebuilt from scratch.
    copy_image_gemfiles
    Bundler.stubs(:settings).returns({ path: "vendor/bundle" })
    stub_bundler

    BundleInstallJob.perform_now(@session.id, @working_directory)

    assert_equal %w[install check], @bundler.subcommands
    assert_equal "---\nBUNDLE_PATH: \"vendor/bundle\"\nBUNDLE_DEPLOYMENT: \"false\"\n",
      File.read(bundle_config_path)
  end

  test "a shared bundle path that is not a directory is never adopted" do
    copy_image_gemfiles
    Bundler.stubs(:settings).returns({ path: File.join(@working_directory, "nope") })
    stub_bundler

    BundleInstallJob.perform_now(@session.id, @working_directory)

    assert_equal %w[install check], @bundler.subcommands
  end

  test "a shared bundle path inside the clone is never adopted" do
    copy_image_gemfiles
    inside = File.join(@working_directory, "vendor", "bundle")
    FileUtils.mkdir_p(inside)
    Bundler.stubs(:settings).returns({ path: inside })
    stub_bundler

    BundleInstallJob.perform_now(@session.id, @working_directory)

    assert_equal %w[install check], @bundler.subcommands
  end

  private

  def bundle_config_path = File.join(@working_directory, ".bundle", "config")

  # [severity, message] tuples from both loggers — ActiveJob's LogSubscriber writes to its own.
  def capture_log_records
    records = []
    recorder = Logger.new(IO::NULL).tap do |logger|
      logger.define_singleton_method(:add) do |severity, message = nil, progname = nil, &block|
        records << [ Logger::SEV_LABEL[severity], (message || progname || block&.call).to_s ]
        true
      end
    end

    original_rails_logger = Rails.logger
    original_job_logger = ActiveJob::Base.logger
    Rails.logger = recorder
    ActiveJob::Base.logger = recorder
    yield
    records
  ensure
    Rails.logger = original_rails_logger
    ActiveJob::Base.logger = original_job_logger
  end

  # A job instance entering its final permitted attempt.
  def last_attempt
    BundleInstallJob.new(@session.id, @working_directory).tap do |job|
      job.executions = BundleInstallJob::MAX_ATTEMPTS - 1
    end
  end

  def write_config(contents)
    FileUtils.mkdir_p(File.dirname(bundle_config_path))
    File.write(bundle_config_path, contents)
  end

  def copy_image_gemfiles
    FileUtils.cp(Rails.root.join("Gemfile"), File.join(@working_directory, "Gemfile"))
    FileUtils.cp(Rails.root.join("Gemfile.lock"), File.join(@working_directory, "Gemfile.lock"))
  end

  # A clone that matches the running app exactly, with a real directory standing in for
  # the image's /usr/local/bundle.
  def share_image_bundle
    copy_image_gemfiles
    @image_bundle = Dir.mktmpdir("image-bundle")
    Bundler.stubs(:settings).returns({ path: @image_bundle })
  end

  def stub_bundler(install: true, checks: [ true ])
    @bundler = BundlerDouble.new(install: install, checks: checks, config_path: bundle_config_path)
    bundler = @bundler
    Open3.define_singleton_method(:capture3) do |*argv, **options|
      bundler.capture3(*argv, **options)
    end
  end
end
