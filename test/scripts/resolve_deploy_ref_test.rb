# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"

# The bug this script exists to prevent is not "the deploy failed" -- it is "the deploy
# failed for sixty seconds without saying which ref was wrong". So the assertions here are
# mostly about WHICH sentence comes out, and about how many requests it took to get there.
#
# Every case runs with `curl` stubbed on PATH: no network, no token, and a log of the URLs
# the script actually asked for, which is what proves the forms that need no request
# (empty input, a full SHA) really make none.
class ResolveDeployRefTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("scripts", "resolve-deploy-ref.sh")

  EXIT_OK = 0
  EXIT_UNRESOLVED = 1
  EXIT_BAD_USAGE = 2

  FULL_SHA = "9e95b4dda8c8f513789357db0f8643079a498482"

  NOT_FOUND_BODY = '{"message":"No commit found for SHA: 9e95b4d","status":"422"}'

  # A `curl` that answers with STUB_CODES (one status per call, last one repeating) and
  # writes STUB_BODY to the -o path, plus a `sleep` that costs the suite nothing but logs
  # that it was called.
  def stub_bin(dir)
    File.write(File.join(dir, "curl"), <<~SH)
      #!/bin/sh
      out=""; url=""; next_is_out=""
      for a in "$@"; do
        if [ -n "$next_is_out" ]; then out="$a"; next_is_out=""; continue; fi
        [ "$a" = "-o" ] && next_is_out=1
        url="$a"
      done
      echo "$url" >> "$STUB_LOG"
      calls=$(wc -l < "$STUB_LOG" | tr -d ' ')
      i=0
      for code in $STUB_CODES; do
        i=$((i + 1))
        [ "$i" -ge "$calls" ] && break
      done
      [ -n "$out" ] && printf '%s' "$STUB_BODY" > "$out"
      printf '%s' "$code"
      # Faithful to curl: on a transport failure it writes its reason to stderr, prints 000
      # for %{http_code}, and exits non-zero. A stub that exits 0 here hides a whole class
      # of status-capture bug -- it did, until it didn't.
      if [ "$code" = "000" ]; then
        echo "curl: (6) Could not resolve host: api.example" >&2
        exit 7
      fi
      exit 0
    SH
    File.write(File.join(dir, "sleep"), "#!/bin/sh\necho \"$1\" >> \"$STUB_SLEEP_LOG\"\nexit 0\n")
    %w[curl sleep].each { |bin| File.chmod(0o755, File.join(dir, bin)) }
    "#{dir}:#{ENV["PATH"]}"
  end

  # Returns [exit status, combined output, GITHUB_OUTPUT contents, requested URLs].
  # Sets @sleeps to the backoffs the script asked for.
  def resolve(requested:, fallback: "refs/heads/main", codes: "200", body: FULL_SHA, env: {})
    Dir.mktmpdir do |dir|
      log = File.join(dir, "urls")
      sleeps = File.join(dir, "sleeps")
      output = File.join(dir, "github_output")
      [ log, sleeps, output ].each { |file| File.write(file, "") }

      full_env = {
        "PATH" => stub_bin(dir),
        "TMPDIR" => dir,
        "REQUESTED_REF" => requested,
        "FALLBACK_REF" => fallback,
        "GITHUB_REPOSITORY" => "tadasant/zimmer",
        "GITHUB_API_URL" => "https://api.github.com",
        "GITHUB_OUTPUT" => output,
        "STUB_LOG" => log,
        "STUB_SLEEP_LOG" => sleeps,
        "STUB_BODY" => body
      }.merge("STUB_CODES" => codes).merge(env)

      # unsetenv_others: nothing ambient (an ATTEMPTS left in the shell, a real GH_TOKEN)
      # may reach the script, or these cases would quietly stop testing what they say.
      stdout, stderr, status = Open3.capture3(full_env, "bash", SCRIPT.to_s, unsetenv_others: true)
      @sleeps = File.read(sleeps).split("\n")

      [ status.exitstatus, stdout + stderr, File.read(output), File.read(log).split("\n") ]
    end
  end

  test "an abbreviated SHA is resolved to a full one before checkout ever sees it" do
    code, out, github_output, urls = resolve(requested: "9e95b4d")

    assert_equal EXIT_OK, code
    assert_equal "ref=#{FULL_SHA}\n", github_output
    assert_match(/resolved from '9e95b4d'/, out)
    assert_equal [ "https://api.github.com/repos/tadasant/zimmer/commits/9e95b4d" ], urls
  end

  test "an empty input deploys the dispatching branch without asking the API" do
    code, out, github_output, urls = resolve(requested: "")

    assert_equal EXIT_OK, code
    assert_equal "ref=refs/heads/main\n", github_output
    assert_match(/no ref was pinned/, out)
    assert_empty urls
  end

  # Resolving a full SHA could only narrow what the workflow accepts: checkout already
  # handles it, and the API declines to show some commits it can fetch.
  test "a full SHA is passed through untouched, without asking the API" do
    code, _out, github_output, urls = resolve(requested: FULL_SHA)

    assert_equal EXIT_OK, code
    assert_equal "ref=#{FULL_SHA}\n", github_output
    assert_empty urls
  end

  test "a branch name resolves, slashes and all" do
    code, _out, github_output, urls = resolve(requested: "feature/some-branch")

    assert_equal EXIT_OK, code
    assert_equal "ref=#{FULL_SHA}\n", github_output
    assert_equal [ "https://api.github.com/repos/tadasant/zimmer/commits/feature/some-branch" ], urls
  end

  # A ref pasted out of a terminal arrives with padding, and an invisible character is a
  # miserable thing to fail a deploy over.
  test "whitespace around a pasted ref is stripped rather than 422'd" do
    code, _out, github_output, urls = resolve(requested: "  9e95b4d\n")

    assert_equal EXIT_OK, code
    assert_equal "ref=#{FULL_SHA}\n", github_output
    assert_equal [ "https://api.github.com/repos/tadasant/zimmer/commits/9e95b4d" ], urls
  end

  # The whole point: name the ref, once, immediately -- not three git retries later.
  test "an unresolvable ref fails fast, names itself, and quotes GitHub's own sentence" do
    code, out, github_output, urls = resolve(requested: "9e95b4d", codes: "422", body: NOT_FOUND_BODY)

    assert_equal EXIT_UNRESOLVED, code
    assert_match(/::error::.*'9e95b4d'/, out)
    assert_match(/No commit found for SHA: 9e95b4d/, out)
    assert_equal 1, urls.length, "a 4xx is a verdict about the ref; retrying it wastes the minute"
    assert_empty github_output
  end

  # The misdiagnosis to avoid: telling an operator their ref is bad when the API was down.
  test "an unreachable API is diagnosed as unreachable, not as a bad ref" do
    code, out, _github_output, urls = resolve(requested: "9e95b4d", codes: "000", env: { "ATTEMPTS" => "3" })

    assert_equal EXIT_UNRESOLVED, code
    assert_match(/Could not reach the GitHub API/, out)
    assert_match(/curl: \(6\) Could not resolve host: api\.example/, out,
      "curl's own reason is the only explanation a 000 will ever have")
    assert_match(/The ref may well be fine; the API was not/, out)
    refute_match(/has no commit, branch, or tag/, out)
    assert_equal 3, urls.length
  end

  test "a transport blip is retried and the deploy still resolves" do
    code, _out, github_output, urls = resolve(requested: "9e95b4d", codes: "000 500 200")

    assert_equal EXIT_OK, code
    assert_equal "ref=#{FULL_SHA}\n", github_output
    assert_equal 3, urls.length
  end

  test "a refused token is diagnosed as a token problem" do
    code, out, _github_output, _urls = resolve(
      requested: "9e95b4d", codes: "403", body: '{"message":"API rate limit exceeded"}'
    )

    assert_equal EXIT_UNRESOLVED, code
    assert_match(/token or rate-limit problem, not a bad ref/, out)
    assert_match(/API rate limit exceeded/, out)
  end

  # A 200 whose body is an HTML error page or a redirect notice must not become the thing
  # the deploy checks out.
  test "a 200 that is not a commit SHA is refused rather than checked out" do
    code, out, github_output, _urls = resolve(requested: "9e95b4d", codes: "200", body: "<html>nope</html>")

    assert_equal EXIT_UNRESOLVED, code
    assert_match(/not a commit SHA/, out)
    assert_empty github_output
  end

  # The ref lands in a URL path. `main/../../users/octocat` and `v1..2` are the cases the
  # character allowlist alone lets through: curl normalizes `..` away, so without the
  # second clause the request lands on a different endpoint entirely.
  test "a ref that is not a ref is refused before a request is made" do
    [ "../../users/octocat", "main/../../users/octocat", "v1..2",
      "main?per_page=1", "main#x", "-oops", "feature x" ].each do |junk|
      code, out, github_output, urls = resolve(requested: junk)

      assert_equal EXIT_UNRESOLVED, code, "#{junk.inspect} was not refused"
      assert_match(/only accepts refs made of/, out)
      assert_empty urls, "#{junk.inspect} reached the API"
      assert_empty github_output
    end
  end

  # Narrower than `git check-ref-format`, and the message has to admit that rather than
  # tell someone their real branch is invalid -- this PR exists to stop the deploy lying
  # about why it failed.
  test "a ref git would accept but this cannot encode is refused honestly" do
    code, out, _github_output, _urls = resolve(requested: "fix#123")

    assert_equal EXIT_UNRESOLVED, code
    refute_match(/not a valid branch/, out)
    assert_match(/full 40-character SHA instead/, out)
  end

  test "an uppercase full SHA is passed through lowercased, to match what is validated" do
    code, _out, github_output, urls = resolve(requested: FULL_SHA.upcase)

    assert_equal EXIT_OK, code
    assert_equal "ref=#{FULL_SHA}\n", github_output
    assert_empty urls
  end

  # A decision nothing can consume is the silent wrong deploy this script exists to
  # prevent: checkout with an empty `ref:` quietly takes the default branch.
  test "a decision with nowhere to go is a usage error, not a green step" do
    code, out, _github_output, _urls = resolve(requested: "", env: { "GITHUB_OUTPUT" => nil })

    assert_equal EXIT_BAD_USAGE, code
    assert_match(/GITHUB_OUTPUT is not set/, out)
  end

  test "a throttled request is retried rather than treated as a verdict on the ref" do
    code, _out, github_output, urls = resolve(requested: "9e95b4d", codes: "429 200")

    assert_equal EXIT_OK, code
    assert_equal "ref=#{FULL_SHA}\n", github_output
    assert_equal 2, urls.length
  end

  # Backoff belongs BETWEEN attempts; after the last one there is nothing left to wait for.
  test "the backoff does not sleep after the final attempt" do
    resolve(requested: "9e95b4d", codes: "000", env: { "ATTEMPTS" => "3" })

    assert_equal 2, @sleeps.length, "slept #{@sleeps.length} times for 3 attempts"
  end

  test "being called with neither a requested nor a fallback ref is a usage error" do
    code, out, _github_output, urls = resolve(requested: "", fallback: "")

    assert_equal EXIT_BAD_USAGE, code
    assert_match(/nothing to check out/, out)
    assert_empty urls
  end

  test "a non-numeric ATTEMPTS is refused instead of silently skipping the request" do
    code, out, _github_output, urls = resolve(requested: "9e95b4d", env: { "ATTEMPTS" => "many" })

    assert_equal EXIT_BAD_USAGE, code
    assert_match(/ATTEMPTS must be a positive integer/, out)
    assert_empty urls
  end
end
