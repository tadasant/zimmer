require "test_helper"

# The seam two hooks classify `gh` commands through, tested on the segment array
# itself rather than through either hook's fixtures.
#
# Both hooks ask a question of a *command*, and both answers are silent when
# wrong: GithubPrUrlHook records a pull request the session never opened, or fails
# to record one it did (#89/#214), and GithubCommentAuthorshipHook suppresses a
# human's review comment or re-delivers the agent's own. A split that is wrong in
# either direction is where that starts, so it is worth stating directly.
class TranscriptHooks::ShellSegmentsTest < ActiveSupport::TestCase
  class Splitter
    include TranscriptHooks::ShellSegments
  end

  setup { @splitter = Splitter.new }

  def segments(command) = @splitter.shell_segments(command)

  # --- Separators -------------------------------------------------------------

  test "splits on the separators that end a command" do
    assert_equal [ "gh pr view 1", "gh pr list", "gh pr diff", "gh pr checks", "cat" ],
                 segments("gh pr view 1 && gh pr list || gh pr diff; gh pr checks | cat")
  end

  test "splits on newlines" do
    assert_equal [ "cd /repo", "gh pr create --fill" ], segments("cd /repo\ngh pr create --fill")
  end

  test "keeps a lone ampersand, which does not end a command" do
    assert_equal [ "gh pr create --fill 2>&1" ], segments("gh pr create --fill 2>&1")
  end

  test "folds a line continuation back into the command it continues" do
    assert_equal [ "gh api repos/o/r/pulls    -X POST -f title=T" ],
                 segments("gh api repos/o/r/pulls \\\n  -X POST -f title=T")
  end

  test "drops empty segments" do
    assert_equal [ "gh pr list" ], segments("gh pr list;")
    assert_equal [], segments("")
    assert_equal [], segments(nil)
  end

  # --- Quoting ----------------------------------------------------------------
  #
  # A separator inside a quoted string is data. #772 is what happens when it is
  # not read that way: the pipes of a grep pattern cut the pattern into pieces,
  # one of which was the bare literal `gh pr create`, and a read-only grep was
  # recorded as having opened a pull request.

  test "does not split on a separator inside a quoted string" do
    assert_equal [ %q(grep -rE "gh pr create|gh api" app/) ],
                 segments(%q(grep -rE "gh pr create|gh api" app/))

    assert_equal [ %q(gh pr create --title 'fix: a|b; c' --body B) ],
                 segments(%q(gh pr create --title 'fix: a|b; c' --body B))
  end

  test "does not split on an escaped separator" do
    assert_equal [ %q(grep -n "def \|pull/\|gh pr create" hook.rb) ],
                 segments(%q(grep -n "def \|pull/\|gh pr create" hook.rb))
  end

  test "reads a quote of the other kind as an ordinary character" do
    assert_equal [ %q(echo "it's here"), "gh pr list" ], segments(%q(echo "it's here" && gh pr list))
    assert_equal [ %q(echo 'say "hi"'), "gh pr list" ], segments(%q(echo 'say "hi"' && gh pr list))
  end

  test "reads a backslash inside single quotes as a literal backslash" do
    assert_equal [ %q(sed -i 's/a\|b/c/' f), "gh pr list" ], segments(%q(sed -i 's/a\|b/c/' f && gh pr list))
  end

  test "keeps a trailing lone backslash rather than running off the end" do
    assert_equal [ "gh pr list \\" ], segments("gh pr list \\")
  end

  # --- Quoting that does not resolve -------------------------------------------
  #
  # Prose carries apostrophes, and a heredoc body is prose. Quote state is read
  # one line at a time so that two stray apostrophes cannot re-balance across the
  # lines between them and swallow a real command; a line that ends inside a quote
  # falls back to the crude split, which over-splits rather than merging.

  test "does not carry quote state across lines" do
    assert_equal [ "# Let's open the PR", "gh pr create --fill", "# That's it" ],
                 segments("# Let's open the PR\ngh pr create --fill\n# That's it")
  end

  test "falls back to the plain split on a line that ends inside a quote" do
    assert_equal [ "echo 'unterminated", "gh pr create --fill" ],
                 segments("echo 'unterminated | gh pr create --fill")
  end

  test "leaves a heredoc body's own lines alone and the command after it intact" do
    command = <<~SH
      cat > /tmp/body.md <<'EOF'
      It's ready, and I've rerun CI.
      EOF
      gh pr create --title T --body-file /tmp/body.md
    SH

    assert_equal "gh pr create --title T --body-file /tmp/body.md", segments(command).last
  end

  # --- Prefixes ---------------------------------------------------------------
  #
  # Stripped so that a caller reading the *front* of a segment — `\Agh\s+api\b` in
  # both hooks — sees the invocation rather than what precedes it.

  test "strips an environment prefix" do
    assert_equal [ "gh api repos/o/r/pulls -X POST" ], segments("GH_TOKEN=x GH_HOST=github.com gh api repos/o/r/pulls -X POST")
  end

  test "strips a capture, with or without an assignment" do
    assert_equal [ "gh api repos/o/r/pulls -X POST)" ], segments("out=$(gh api repos/o/r/pulls -X POST)")
    assert_equal [ "gh api repos/o/r/pulls)" ], segments("$(gh api repos/o/r/pulls)")
    assert_equal [ "gh api repos/o/r/pulls`" ], segments("`gh api repos/o/r/pulls`")
  end

  # --- Wrapped scripts ---------------------------------------------------------
  #
  # What a shell is handed is more commands, not data, so it is split rather than
  # kept whole. Codex writes the unquoted spelling in front of every command it
  # runs; an agent writing the quoted one by hand gets the same reading.

  test "splits the script a shell is handed" do
    assert_equal [ "cd /repo", "gh pr create --fill" ], segments("bash -lc cd /repo && gh pr create --fill")
    assert_equal [ "cd /repo", "gh pr create --fill" ], segments(%q(bash -lc "cd /repo && gh pr create --fill"))
    assert_equal [ "cd /repo", "gh pr create --fill" ], segments(%q(sh -c 'cd /repo && gh pr create --fill'))
    assert_equal [ "gh pr create --fill" ], segments(%q(eval "gh pr create --fill"))
  end

  test "splits a wrapped script so one of its commands cannot vouch for another" do
    # The module header's worked example, wrapped: read as one command, `rm -f`
    # supplies the write flag for the read in front of it and every comment that
    # read printed is recorded as the agent's own (#214).
    assert_equal [ "gh api repos/o/r/issues/1/comments --paginate", "rm -f /tmp/x" ],
                 segments(%q(bash -lc "gh api repos/o/r/issues/1/comments --paginate && rm -f /tmp/x"))
  end

  test "finds a wrapper behind whatever runs it" do
    assert_equal [ "cd /repo", "gh pr create --fill" ],
                 segments(%q(timeout 300 bash -lc "cd /repo && gh pr create --fill"))
    assert_equal [ "gh pr create --fill" ], segments(%q(sudo -E bash -c "gh pr create --fill"))
    assert_equal [ "echo x", "gh pr create --title {}" ],
                 segments(%q(echo x | xargs -I{} sh -c "gh pr create --title {}"))
  end

  test "does not read a wrapper that a command merely names" do
    assert_equal [ %q(echo "bash -c gh pr create") ], segments(%q(echo "bash -c gh pr create"))
  end

  test "strips a compound-statement keyword from the command it runs" do
    assert_equal [ "for i in 1 2 3", "gh api repos/o/r/pulls -X POST", "done" ],
                 segments("for i in 1 2 3; do gh api repos/o/r/pulls -X POST; done")

    assert_equal [ "if [ -z $x ]", "gh api repos/o/r/pulls -X POST", "fi" ],
                 segments("if [ -z $x ]; then gh api repos/o/r/pulls -X POST; fi")
  end

  test "leaves a command that merely starts with a keyword's letters alone" do
    assert_equal [ "docker ps", "done" ], segments("docker ps; done")
  end

  # --- #unquoted ---------------------------------------------------------------

  test "blanks out what a command was handed, leaving what it runs" do
    # Blanked to the same width, so a position in the result is a position in the
    # segment — which is what tells a wrapper from the mention of one.
    assert_equal "grep -n                hook.rb", @splitter.unquoted(%q(grep -n "gh pr create" hook.rb))
    assert_equal "rg -n                app/", @splitter.unquoted(%q(rg -n 'gh pr create' app/))
  end

  test "leaves a quote with no partner alone" do
    # Blanking to the end of the line on the strength of one stray apostrophe
    # would delete the command after it.
    assert_equal %q(echo don't && gh pr create --fill), @splitter.unquoted(%q(echo don't && gh pr create --fill))
  end

  test "does not end a double-quoted string on an escaped quote" do
    assert_equal "echo                             done", @splitter.unquoted(%q(echo "she said \"gh pr create\"" done))
  end

  test "reads nil as nothing rather than raising" do
    assert_equal "", @splitter.unquoted(nil)
  end

  test "leaves an unquoted command untouched" do
    assert_equal "gh pr create --fill", @splitter.unquoted("gh pr create --fill")
  end
end
