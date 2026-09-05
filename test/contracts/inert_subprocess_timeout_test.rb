# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# CI wiring, and the behavioural spec, for InertSubprocessTimeoutGuard — the
# guard behind "there is one way to bound a subprocess, and it is
# BoundedSubprocess" (zimmer#908).
#
# The first test is the one that matters day to day: it fails the moment
# `Timeout.timeout { Open3.capture3(...) }` reappears under app/ or lib/. The
# rest exist because a guard that has rotted into a no-op is worse than no
# guard — they pin down what it catches and, just as importantly, what it does
# not, so the assertion above cannot quietly become vacuous.
class InertSubprocessTimeoutTest < ActiveSupport::TestCase
  test "no Timeout.timeout in app/ or lib/ wraps an Open3 subprocess call" do
    violations = InertSubprocessTimeoutGuard.violations

    assert_empty violations, InertSubprocessTimeoutGuard.report(violations)
  end

  test "it catches the shape zimmer#908 was filed about" do
    findings = scan_source(<<~RUBY)
      def installed_cli_version
        stdout, _stderr, status = Timeout.timeout(10) do
          Open3.capture3(binary_name, "--version")
        end
        SubprocessStatus.success?(status)
      end
    RUBY

    assert_equal 1, findings.length
    assert_equal 2, findings.first.line
    assert_equal 3, findings.first.subprocess_line
    assert_equal "Open3.capture3", findings.first.subprocess_source
  end

  # `Timeout::timeout` is the same method, and `do…end` is not the only way to
  # hand it a body — a brace block and a one-line `Timeout.timeout(n) { … }` are
  # the forms most likely to be written next.
  test "it catches the colon-colon spelling and a brace block" do
    findings = scan_source(<<~RUBY)
      out, = Timeout::timeout(5) { Open3.capture3("git", "status") }
    RUBY

    assert_equal 1, findings.length
    assert_equal "Open3.capture3", findings.first.subprocess_source
  end

  # capture3 is the site the issue happened to find. Every Open3 entry point
  # routes through `popen_run`, so they all inherit the ensure-then-join, and a
  # guard that knew only capture3 would wave the next one through.
  test "it catches the rest of the Open3 family, not just capture3" do
    %w[capture2 capture2e capture3 popen2 popen2e popen3].each do |method|
      findings = scan_source("Timeout.timeout(1) { Open3.#{method}('true') }")

      assert_equal [ "Open3.#{method}" ], findings.map(&:subprocess_source),
        "Timeout.timeout around Open3.#{method} should be reported"
    end
  end

  # The nesting can be arbitrarily deep — a rescue, a loop, a helper block — and
  # the call is still made inside the timeout, so it is still inert.
  test "it looks through intervening blocks rather than only the immediate body" do
    findings = scan_source(<<~RUBY)
      Timeout.timeout(30) do
        candidates.each do |cmd|
          begin
            Open3.capture3(*cmd)
          rescue Errno::ENOENT
            next
          end
        end
      end
    RUBY

    assert_equal 1, findings.length
    assert_equal 4, findings.first.subprocess_line
  end

  # The three shapes that read like the bug and are not it. If any of these
  # started reporting, the guard would be noise and the next contributor would
  # reach for a disable comment.
  test "it leaves the legitimate neighbours alone" do
    # native_claude_print_runner.rb: spawn, then wait under a timeout, then kill
    # the pid in the rescue. This is the correct shape, not the broken one.
    assert_empty scan_source(<<~RUBY)
      def wait_for_completion(pid, timeout)
        Timeout.timeout(timeout) { @process_manager.wait(pid) }
      rescue Timeout::Error
        terminate_process(pid)
      end
    RUBY

    # cert_expiry_checker.rb: in-thread IO, no child process at all.
    assert_empty scan_source("Timeout.timeout(@timeout) { ssl.connect }")

    # An Open3 call that is simply not inside a Timeout.timeout.
    assert_empty scan_source(<<~RUBY)
      Timeout.timeout(10) { sleep 1 }
      Open3.capture3("git", "status")
    RUBY

    # BoundedSubprocess itself: Open3.popen3, correctly, with no Timeout around it.
    assert_empty scan_source("Open3.popen3(env, *command_array, spawn_opts) { |i, o, e, t| t.value }")
  end

  # Parsed, not grepped: a comment or a heredoc that spells the pattern out —
  # this guard's own header does exactly that — is documentation, not a call.
  test "it does not fire on the pattern written in a comment or a string" do
    assert_empty scan_source(<<~'RUBY')
      # Never write Timeout.timeout(1) { Open3.capture3("sleep", "8") } — it bounds nothing.
      EXAMPLE = 'Timeout.timeout(1) { Open3.capture3("sleep", "8") }'
    RUBY
  end

  test "violations scans a directory tree and the report names the file and both lines" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "services"))
      File.write(File.join(dir, "services", "bounded.rb"), "BoundedSubprocess.run([bin, \"--version\"], timeout: 10)\n")

      assert_empty InertSubprocessTimeoutGuard.violations([ dir ])

      offender = File.join(dir, "services", "inert.rb")
      File.write(offender, <<~RUBY)
        def probe
          Timeout.timeout(10) do
            Open3.capture3(bin, "--version")
          end
        end
      RUBY

      violations = InertSubprocessTimeoutGuard.violations([ dir ])

      assert_equal 1, violations.length
      report = InertSubprocessTimeoutGuard.report(violations)
      assert_includes report, "services/inert.rb:2"
      assert_includes report, "Open3.capture3 on line 3"
      assert_includes report, "BoundedSubprocess"
      assert_empty InertSubprocessTimeoutGuard.report([])

      # And the fix clears it, which is what the message tells you to do.
      File.write(offender, "BoundedSubprocess.run([bin, \"--version\"], timeout: 10)\n")

      assert_empty InertSubprocessTimeoutGuard.violations([ dir ])
    end
  end

  private

  def scan_source(source)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "scanned.rb")
      File.write(path, source)
      InertSubprocessTimeoutGuard.scan_file(path)
    end
  end
end
