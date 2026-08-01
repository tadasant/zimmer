# frozen_string_literal: true

require "test_helper"

class AlertSnippetTest < ActiveSupport::TestCase
  # Builds an exception carrying a synthetic backtrace, so frame selection is
  # tested against a known stack rather than whatever the test runner produces.
  def exception_with(backtrace, klass: RuntimeError, message: "boom")
    error = klass.new(message)
    error.set_backtrace(backtrace)
    error
  end

  def app_frame(path, line, method)
    "#{Rails.root}/#{path}:#{line}:in '#{method}'"
  end

  def gem_frame(gem_name, path, line, method)
    "/usr/local/bundle/gems/#{gem_name}/lib/#{path}:#{line}:in '#{method}'"
  end

  # === build: basics ===

  test "build returns nil for nil" do
    assert_nil AlertSnippet.build(nil)
  end

  test "build returns nil for a blank string" do
    assert_nil AlertSnippet.build("   \n  ")
  end

  test "build renders exception class and message on the first line" do
    error = exception_with([ app_frame("app/models/trigger.rb", 42, "fire!") ],
                           klass: ArgumentError, message: "unknown agent root 'ghost'")

    assert_equal "ArgumentError: unknown agent root 'ghost'", AlertSnippet.build(error).lines.first.chomp
  end

  test "build accepts a raw log string" do
    assert_equal "Errno::ECONNREFUSED: Connection refused - connect(2)",
                 AlertSnippet.build("Errno::ECONNREFUSED: Connection refused - connect(2)")
  end

  # === build: frame selection (the "high signal, not boilerplate" bar) ===

  test "build prefers app-owned frames over vendored ones" do
    backtrace = [
      gem_frame("net-http-0.4.1", "net/http.rb", 1611, "connect"),
      gem_frame("net-http-0.4.1", "net/http.rb", 1600, "do_start"),
      gem_frame("faraday-2.9.0", "faraday/adapter.rb", 40, "call"),
      app_frame("app/services/github_search_service.rb", 88, "search"),
      app_frame("app/jobs/github_trigger_poller_job.rb", 150, "perform")
    ]

    snippet = AlertSnippet.build(exception_with(backtrace))

    assert_includes snippet, "app/services/github_search_service.rb:88"
    assert_includes snippet, "app/jobs/github_trigger_poller_job.rb:150"
    # The topmost frame is where the raise happened — kept even though vendored.
    assert_includes snippet, "net/http.rb:1611"
    # The vendored frame between the kept ones is dropped, and said so.
    assert_not_includes snippet, "faraday/adapter.rb:40"
    assert_includes snippet, "1 frame elided"
  end

  test "build strips the Rails root prefix from app frames" do
    snippet = AlertSnippet.build(exception_with([ app_frame("app/models/trigger.rb", 42, "fire!") ]))

    assert_includes snippet, "app/models/trigger.rb:42"
    assert_not_includes snippet, Rails.root.to_s
  end

  test "build keeps top frames when no frame is app-owned" do
    backtrace = Array.new(5) { |i| gem_frame("pg-1.5.6", "pg/connection.rb", 100 + i, "exec") }

    snippet = AlertSnippet.build(exception_with(backtrace))

    assert_includes snippet, "pg/connection.rb:100"
  end

  test "build bounds the number of app frames and reports the remainder" do
    backtrace = Array.new(40) { |i| app_frame("app/services/deep.rb", i, "step_#{i}") }

    snippet = AlertSnippet.build(exception_with(backtrace))

    assert_equal AlertSnippet::APP_FRAME_LIMIT, snippet.scan(/app\/services\/deep\.rb:/).length
    assert_includes snippet, "#{40 - AlertSnippet::APP_FRAME_LIMIT} frames elided"
  end

  test "build handles an exception with no backtrace" do
    snippet = AlertSnippet.build(RuntimeError.new("never raised"))

    assert_equal "RuntimeError: never raised", snippet
  end

  # === build: cause chain ===

  test "build includes the cause chain" do
    root = exception_with([ gem_frame("pg-1.5.6", "pg/connection.rb", 10, "exec") ],
                          klass: IOError, message: "connection reset")
    wrapper = nil
    begin
      begin
        raise root
      rescue IOError
        raise ArgumentError, "could not load trigger"
      end
    rescue ArgumentError => e
      wrapper = e
    end

    snippet = AlertSnippet.build(wrapper)

    assert_includes snippet, "ArgumentError: could not load trigger"
    assert_includes snippet, "Caused by: IOError: connection reset"
  end

  test "build survives a self-referential cause without looping" do
    error = exception_with([ app_frame("app/a.rb", 1, "go") ])
    error.define_singleton_method(:cause) { self }

    snippet = AlertSnippet.build(error)

    assert_includes snippet, "RuntimeError: boom"
    assert_not_includes snippet, "Caused by"
  end

  # === Redaction ===

  # The fake tokens below are assembled from pieces rather than written as
  # literals: they are synthetic, but a literal one trips GitHub's push
  # protection and blocks the push.
  SLACK_TOKEN = "xox" + "b-1234567890-ABCDEFGHIJKLMNOP"
  GITHUB_TOKEN = "gh" + "p_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  ANTHROPIC_KEY = "sk-" + "ant-api03-AAAABBBBCCCCDDDDEEEE"

  test "build redacts secret-shaped values" do
    raw = [
      "Slack call failed with token #{SLACK_TOKEN}",
      "gh auth: #{GITHUB_TOKEN}",
      "Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345",
      "PG connection postgres://zimmer:hunter2secret@db.example.com:5432/zimmer",
      "ANTHROPIC_API_KEY=#{ANTHROPIC_KEY}"
    ].join("\n")

    snippet = AlertSnippet.build(raw)

    assert_not_includes snippet, SLACK_TOKEN
    assert_not_includes snippet, GITHUB_TOKEN
    assert_not_includes snippet, "abcdefghijklmnopqrstuvwxyz012345"
    assert_not_includes snippet, "hunter2secret"
    assert_not_includes snippet, ANTHROPIC_KEY
    assert_includes snippet, "[REDACTED]"
    # Non-secret context around the secrets survives — the point is diagnosis.
    assert_includes snippet, "db.example.com:5432/zimmer"
  end

  test "build redacts a secret inside an exception message" do
    token = "xox" + "b-9999999999-ZZZZZZZZZZZZZZZZ"
    error = exception_with([], klass: RuntimeError, message: "auth failed for token #{token}")

    assert_not_includes AlertSnippet.build(error), token
  end

  # === Truncation boundary ===

  test "build leaves output at exactly the cap untouched" do
    exact = "x" * AlertSnippet::MAX_CHARS

    snippet = AlertSnippet.build(exact)

    assert_equal AlertSnippet::MAX_CHARS, snippet.length
    assert_not_includes snippet, "elided"
  end

  test "build elides one character over the cap" do
    over = "x" * (AlertSnippet::MAX_CHARS + 1)

    snippet = AlertSnippet.build(over)

    assert_operator snippet.length, :<=, AlertSnippet::MAX_CHARS
    assert_includes snippet, "characters elided"
  end

  test "build keeps head and tail of a very long log, marking the cut" do
    body = Array.new(500) { |i| "line #{i} — filler filler filler" }
    raw = ([ "FIRST LINE" ] + body + [ "LAST LINE" ]).join("\n")

    snippet = AlertSnippet.build(raw)

    assert_operator snippet.length, :<=, AlertSnippet::MAX_CHARS
    assert_includes snippet, "FIRST LINE"
    assert_includes snippet, "LAST LINE"
    assert_match(/… \d+ characters elided …/, snippet)
  end

  test "build bounds a pathological input" do
    assert_operator AlertSnippet.build("y" * 1_000_000).length, :<=, AlertSnippet::MAX_CHARS
  end

  test "build honors a custom max_chars" do
    snippet = AlertSnippet.build("z" * 5000, max_chars: AlertSnippet::MAX_BATCHED_CHARS)

    assert_operator snippet.length, :<=, AlertSnippet::MAX_BATCHED_CHARS
  end

  test "clamp is a no-op below the cap" do
    assert_equal "short", AlertSnippet.clamp("short", 100)
  end

  test "clamp reports how much it dropped" do
    clamped = AlertSnippet.clamp("a" * 1000, 200)

    assert_operator clamped.length, :<=, 200
    assert_match(/… (\d+) characters elided …/, clamped)
    assert_operator clamped[/… (\d+) characters elided …/, 1].to_i, :>, 0
  end

  # === Fencing ===

  test "fenced wraps in a code block" do
    assert_equal "```\nboom\n```", AlertSnippet.fenced("boom")
  end

  test "fenced defangs an inner fence so the block cannot terminate early" do
    fenced = AlertSnippet.fenced("before ``` after")

    assert_not_includes fenced[4..-5], "```"
    assert fenced.start_with?("```\n")
    assert fenced.end_with?("\n```")
  end
end
