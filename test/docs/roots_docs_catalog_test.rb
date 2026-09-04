# frozen_string_literal: true

require "test_helper"

# Two docs pages write down how many agent roots the catalog ships, and one of
# them also names every root in a hand-maintained table. The catalog moves under
# them: the roots count went 11 -> 12 in a single day, and agent-roots.md's
# frontmatter claimed ten against a catalog resolving twelve
# (tadasant/zimmer#911) -- the same drift docs/air/zimmer-integration.md carried
# before it was guarded (#841, #909).
#
# The counts are spelled as English words rather than digits, which is harder to
# spot by eye, so they are read back out of the prose and compared against a live
# resolve. The table gets more than a count: a catalog change that swaps one root
# for another keeps the number right and leaves the row set wrong.
class RootsDocsCatalogTest < ActiveSupport::TestCase
  ROOTS_PAGE = Rails.root.join("docs/src/content/docs/air/agent-roots.md")
  CONCEPTS_PAGE = Rails.root.join("docs/src/content/docs/intro/concepts.md")

  # Index is the value, so this both parses a word out of the prose and renders
  # the word the prose should have used. Deliberately finite: a catalog that
  # outgrows it fails loudly here rather than silently stopping checking.
  NUMBER_WORDS = %w[
    zero one two three four five six seven eight nine ten eleven twelve
    thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty
    twenty-one twenty-two twenty-three twenty-four twenty-five twenty-six
    twenty-seven twenty-eight twenty-nine thirty
  ].freeze

  # The repo the "roots point at a repository that does not exist" callout is
  # about. Which repo is the fact; how many roots point at it is not.
  MISSING_REPO_URL = "https://github.com/tadasant/zimmer-catalog.git"

  # The prefix concepts.md uses to talk about the subagent phase roots as a group.
  SUBAGENT_ROOT_PREFIX = "catalog-mgmt-"

  TABLE_HEADINGS = %w[Root Invocable].freeze
  INVOCABLE_MARKS = { "✅" => true, "❌" => false }.freeze

  setup do
    @roots = AirCatalogService.entries_for(:roots)
  end

  # --- reading the pages ------------------------------------------------------

  def page_source(page)
    @page_sources ||= {}
    @page_sources[page] ||= page.read
  end

  def page_name(page)
    page.relative_path_from(Rails.root.join("docs/src/content")).to_s
  end

  # The single number-word `pattern` captures on `page`, as an Integer.
  def stated_count(page, pattern, description)
    found = page_source(page).scan(pattern).flatten
    assert_equal 1, found.size,
                 "expected exactly one #{description} in #{page_name(page)}, found #{found.size}. " \
                 "This test reads the count back out of the prose; keep it phrased so it can be found."

    word = found.first.downcase
    index = NUMBER_WORDS.index(word)
    assert index, "#{page_name(page)} spells the #{description} as \"#{found.first}\", " \
                  "which is not a number word this test knows. Use one of: #{NUMBER_WORDS.join(', ')}."
    index
  end

  def assert_stated_count(expected, page, pattern, description)
    actual = stated_count(page, pattern, description)
    return if actual == expected

    expected_word = NUMBER_WORDS[expected]
    assert expected_word,
           "the catalog puts the #{description} at #{expected}, past the end of NUMBER_WORDS. " \
           "Extend it, then fix the pages."
    flunk "#{page_name(page)} states the #{description} as \"#{NUMBER_WORDS[actual]}\" (#{actual}), " \
          "but a live catalog resolve produces #{expected}. Change the page to say \"#{expected_word}\"."
  end

  # The rows of the table under the "roots that ship" heading, as
  # [root id, invocable] pairs in page order.
  def roots_table
    @roots_table ||= begin
      after_heading = page_source(ROOTS_PAGE)[/^## The \S+ roots that ship[^\n]*\n(.*)\z/m, 1]
      assert after_heading,
             "#{page_name(ROOTS_PAGE)} no longer has a \"## The <count> roots that ship\" heading; " \
             "this test finds the roots table by looking underneath it."

      lines = after_heading.lines.map(&:strip)
      first = lines.index { |line| line.start_with?("|") }
      assert first, "#{page_name(ROOTS_PAGE)} has no markdown table under the \"roots that ship\" heading."

      table = lines[first..].take_while { |line| line.start_with?("|") }
      # Row 0 names the columns, row 1 is the --- separator. Only the first two
      # columns are machine-checkable; Repo and Notes are prose.
      assert_operator table.size, :>, 2, "the roots table in #{page_name(ROOTS_PAGE)} has no rows"
      assert_equal TABLE_HEADINGS, cells(table[0]).first(2),
                   "the roots table in #{page_name(ROOTS_PAGE)} no longer starts with " \
                   "#{TABLE_HEADINGS.join(' / ')} columns; this test reads those two by position."

      assert_match(/\A\|[\s:|-]+\|\z/, table[1],
                   "the roots table in #{page_name(ROOTS_PAGE)} has no --- separator row under its headings.")

      table[2..].map { |row| parse_row(row) }
    end
  end

  def cells(row)
    row.delete_prefix("|").delete_suffix("|").split("|").map(&:strip)
  end

  def parse_row(row)
    name, invocable = cells(row).first(2)

    id = name[/\A`([^`]+)`\z/, 1]
    assert id, "row #{row.inspect} in #{page_name(ROOTS_PAGE)} does not name a root as `<id>` in its first column."

    assert_includes INVOCABLE_MARKS, invocable,
                    "root `#{id}` in #{page_name(ROOTS_PAGE)} has #{invocable.inspect} in its Invocable column; " \
                    "expected #{INVOCABLE_MARKS.keys.join(' or ')}."

    [ id, INVOCABLE_MARKS.fetch(invocable) ]
  end

  # --- the counts -------------------------------------------------------------

  test "agent-roots.md counts the roots the catalog resolves, in its frontmatter and its heading" do
    assert_stated_count @roots.size, ROOTS_PAGE, /^description:.*\bthe (\S+)(?: roots)? that ship\b/, "frontmatter roots count"
    assert_stated_count @roots.size, ROOTS_PAGE, /^## The (\S+) roots that ship\b/, "roots-that-ship heading count"
  end

  test "concepts.md counts the roots the catalog resolves" do
    assert_stated_count @roots.size, CONCEPTS_PAGE, /catalog ships (\S+) roots\b/, "roots count"
  end

  test "concepts.md counts the subagent phase roots the catalog resolves" do
    expected = @roots.keys.count { |id| id.start_with?(SUBAGENT_ROOT_PREFIX) }

    assert_stated_count expected, CONCEPTS_PAGE, /(\S+) `#{Regexp.escape(SUBAGENT_ROOT_PREFIX)}\*` roots\b/, "subagent roots count"
  end

  # --- the table --------------------------------------------------------------

  test "the roots table names every root the catalog resolves, and only those" do
    listed = roots_table.map(&:first)

    duplicated = listed.tally.select { |_id, count| count > 1 }.keys
    assert_empty duplicated,
                 "#{page_name(ROOTS_PAGE)} lists #{duplicated.join(', ')} more than once in the roots table."

    missing = @roots.keys - listed
    extra = listed - @roots.keys
    # flunk rather than assert_equal: the message below already names both sides,
    # and a set diff of ids reads worse than the sentence.
    return if missing.empty? && extra.empty?

    flunk <<~MESSAGE.strip
      the roots table in #{page_name(ROOTS_PAGE)} disagrees with a live catalog resolve.
        in the catalog but not in the table: #{missing.presence&.join(', ') || '(none)'}
        in the table but not in the catalog: #{extra.presence&.join(', ') || '(none)'}
      Add a row for each root the catalog resolves, and drop the rows for roots it no longer does.
    MESSAGE
  end

  test "the roots table marks each root invocable exactly as the catalog declares" do
    wrong = roots_table.filter_map do |id, invocable|
      root = @roots[id]
      # A row naming a root the catalog does not have is the row-set test's failure, not this one's.
      next if root.nil?

      # Optional in roots.json, and AgentRootsConfig reads an absent key as true --
      # so an omitted key means an invocable root, not a crash in here.
      declared = root.fetch("user_invocable", true)
      next if declared == invocable

      "`#{id}` (the catalog resolves user_invocable: #{declared}, " \
        "so the table's Invocable column should be #{INVOCABLE_MARKS.key(declared)})"
    end

    return if wrong.empty?

    flunk "the roots table in #{page_name(ROOTS_PAGE)} contradicts roots.json:\n  #{wrong.join("\n  ")}"
  end

  # --- the callout about the roots whose repo does not exist ------------------

  test "agent-roots.md's missing-repository callout covers exactly the roots pointing there" do
    expected = @roots.count { |_id, root| root["url"] == MISSING_REPO_URL }
    heading = /^:::danger\[(\S+) roots? points? at a repository that does not exist\]/
    present = page_source(ROOTS_PAGE).match?(heading)

    if expected.zero?
      refute present,
             "no root points at #{MISSING_REPO_URL} any more, but #{page_name(ROOTS_PAGE)} still carries the " \
             "\"points at a repository that does not exist\" callout. Drop it."
      return
    end

    assert present,
           "#{expected} roots point at #{MISSING_REPO_URL}, " \
           "but #{page_name(ROOTS_PAGE)} no longer warns about it."
    assert_stated_count expected, ROOTS_PAGE, heading, "missing-repository callout count"
  end
end
