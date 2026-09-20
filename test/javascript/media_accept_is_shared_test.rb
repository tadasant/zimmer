require "test_helper"

# The `accept` string on every composer's media picker exists twice, in two
# languages, and the two halves are not interchangeable:
#
#   - `ApplicationHelper::MEDIA_PICKER_ACCEPT` renders the attribute, so it decides
#     what the OS picker offers.
#   - `MEDIA_ACCEPT` in `app/javascript/lib/media_kinds.js` documents the same
#     contract next to `partitionMedia`, which decides what happens to whatever the
#     picker hands back.
#
# They cannot be collapsed into one — a Ruby constant cannot be read from an
# importmap module without a build step this app does not have — so a source scan
# is what keeps them honest. The failure it guards against is silent in both
# directions: widen only the Ruby half and the split stops covering a type the
# picker now offers; widen only the JS half and the picker still greys it out.
#
# A source scan rather than a runtime assertion, for the same reason
# CsrfLookupIsSharedTest is one: the thing being pinned is a property of the
# files, and no page render exercises the JS constant at all.
class MediaAcceptIsSharedTest < ActiveSupport::TestCase
  MEDIA_KINDS_JS = Rails.root.join("app/javascript/lib/media_kinds.js")

  test "the JS media accept string matches the Ruby one exactly" do
    source = File.read(MEDIA_KINDS_JS)
    match = source.match(/export const MEDIA_ACCEPT = "([^"]*)"/)

    assert match, "MEDIA_ACCEPT is no longer declared in #{MEDIA_KINDS_JS.basename} — " \
                  "if it moved, point this test at its new home rather than deleting it"
    assert_equal ApplicationHelper::MEDIA_PICKER_ACCEPT, match[1],
      "the picker's accept attribute and lib/media_kinds.js disagree about what a " \
      "composer offers; widening one without the other either hides a type from the " \
      "picker or lets one through that partitionMedia does not route"
  end

  test "the accept string offers a phone's own stills and video" do
    accept = ApplicationHelper::MEDIA_PICKER_ACCEPT

    # `image/*` and `video/*` are what put "Photo Library" and "Take Photo or Video"
    # on the iOS sheet. Narrowing to the four storable types is the regression this
    # pins: it greys out an iPhone's camera roll, since an iPhone still is HEIC.
    assert_includes accept, "image/*"
    assert_includes accept, "video/*"

    ImageStorageService::SUPPORTED_TYPES.each_key do |type|
      assert_not_includes accept, type,
        "#{type} is listed explicitly, which narrows the picker back to named types"
    end
  end
end
