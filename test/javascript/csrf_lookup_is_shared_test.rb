require "test_helper"

# The structural half of #733. That issue was filed because 25 Stimulus
# controllers had each re-derived the CSRF token themselves — 28
# `document.querySelector` call sites, three selector spellings, six access
# shapes — and nothing stopped the twenty-sixth from doing it again. The
# conversion to `app/javascript/lib/csrf.js` fixes the 28; this test is what
# makes it stick.
#
# A source scan rather than a runtime assertion, for the same reason
# NoWholeColumnMetadataWritersTest is one: it is the only thing that covers all
# of `app/javascript/` at once, and the failure it guards against is a new file
# reintroducing the old shape rather than an existing one misbehaving.
#
# It looks for the *name of the meta tag* rather than for `querySelector`,
# because the name is the thing a second lookup cannot avoid mentioning —
# hoisting the selector into a constant would slip past a `querySelector(...)`
# pattern, and hoisting it is exactly what a tidy re-implementation would do.
class CsrfLookupIsSharedTest < ActiveSupport::TestCase
  SCANNED = Rails.root.join("app/javascript")

  # The one file allowed to name the meta tag. Everything else imports from it.
  HELPER = "lib/csrf.js"

  # Covers all three spellings the issue counted — `meta[name="csrf-token"]`,
  # `meta[name='csrf-token']`, and the unqualified `[name='csrf-token']` — and
  # anything else that reaches for the tag by name.
  TOKEN_TAG_NAME = /csrf-token/

  # The getters and methods the conversion deleted, by every name they had.
  HAND_ROLLED_ACCESSOR = /\b(?:get\s+csrfToken\s*\(|getCsrfToken\s*\(|getCSRFToken\s*\()/

  test "the CSRF meta tag is named in exactly one place" do
    offenders = scan(TOKEN_TAG_NAME)

    assert_empty offenders, <<~MESSAGE
      These files reach for the CSRF meta tag themselves:

      #{offenders.join("\n")}

      Import it instead — `import { csrfToken, csrfHeaders } from "lib/csrf"` —
      so the app keeps one selector and one policy for a missing token. See #733.
    MESSAGE
  end

  test "no controller re-implements a csrfToken accessor" do
    offenders = scan(HAND_ROLLED_ACCESSOR)

    assert_empty offenders, <<~MESSAGE
      These files define their own CSRF token accessor:

      #{offenders.join("\n")}

      `lib/csrf.js` exports `csrfToken()`. A per-controller copy of it is what
      #733 removed — there were eight, in three different spellings.
    MESSAGE
  end

  test "the helper is meta-qualified and reads the tag" do
    helper = SCANNED.join(HELPER).read

    assert_includes helper, %(meta[name="csrf-token"]),
      "#{HELPER} must stay meta-qualified: an unqualified [name='csrf-token'] " \
      "matches the first element in document order with that name, <meta> or not."
    assert_match(/document\.querySelector\(/, helper,
      "#{HELPER} is supposed to be the single lookup; it no longer performs one.")
  end

  private

  def scan(pattern)
    Dir.glob(SCANNED.join("**/*.js")).sort.filter_map do |path|
      relative = Pathname.new(path).relative_path_from(SCANNED).to_s
      next if relative == HELPER

      hits = File.readlines(path).each_with_index.filter_map do |line, index|
        "  #{relative}:#{index + 1}: #{line.strip}" if line.match?(pattern)
      end
      hits.presence&.join("\n")
    end
  end
end
