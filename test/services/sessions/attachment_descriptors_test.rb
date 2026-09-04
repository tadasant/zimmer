# frozen_string_literal: true

require "test_helper"

# The round trip itself. A descriptor written into jsonb and read back has to
# arrive in the shape the CLI adapters index it with — `image[:path]`, a symbol —
# because the failure when it does not is silent in both directions: the turn
# looks like it is carrying an attachment and the agent cannot see one.
class Sessions::AttachmentDescriptorsTest < ActiveSupport::TestCase
  IMAGE_KEYS = Sessions::AttachmentDescriptors::IMAGE_KEYS
  FILE_KEYS = Sessions::AttachmentDescriptors::FILE_KEYS

  test "an image descriptor survives a round trip through JSON" do
    given = [ { path: "/data/sessions/1/images/shot.png", media_type: "image/png" } ]

    stored = Sessions::AttachmentDescriptors.for_the_record(given, keys: IMAGE_KEYS)
    # What jsonb actually does to it on the way out.
    read_back = JSON.parse(stored.to_json)

    assert_equal given,
      Sessions::AttachmentDescriptors.for_a_job(read_back, keys: IMAGE_KEYS)
  end

  test "a file descriptor survives a round trip through JSON" do
    given = [ { path: "/data/sessions/1/files/notes.txt", original_filename: "notes.txt", size: 7 } ]

    stored = Sessions::AttachmentDescriptors.for_the_record(given, keys: FILE_KEYS)
    read_back = JSON.parse(stored.to_json)

    assert_equal given,
      Sessions::AttachmentDescriptors.for_a_job(read_back, keys: FILE_KEYS)
  end

  test "what goes to the record has string keys" do
    stored = Sessions::AttachmentDescriptors.for_the_record(
      [ { path: "/a.png", media_type: "image/png" } ], keys: IMAGE_KEYS
    )

    assert_equal [ { "path" => "/a.png", "media_type" => "image/png" } ], stored
  end

  test "what goes to a job has symbol keys, whichever spelling it arrived in" do
    from_jsonb = [ { "path" => "/a.png", "media_type" => "image/png" } ]

    assert_equal [ { path: "/a.png", media_type: "image/png" } ],
      Sessions::AttachmentDescriptors.for_a_job(from_jsonb, keys: IMAGE_KEYS)
  end

  # A store must not grow a field no reader asks for — and, more to the point, a
  # descriptor read back out must be the descriptor that went in rather than
  # whatever else the caller was carrying at the time.
  test "keys no consumer reads are dropped in both directions" do
    entry = { path: "/a.png", media_type: "image/png", secret: "nope" }

    assert_equal [ %w[path media_type] ],
      Sessions::AttachmentDescriptors.for_the_record([ entry ], keys: IMAGE_KEYS).map(&:keys)
    assert_equal [ %i[path media_type] ],
      Sessions::AttachmentDescriptors.for_a_job([ entry ], keys: IMAGE_KEYS).map(&:keys)
  end

  # `path` is the only field either consumer can act on. Passing an entry without
  # one hands the adapter a nil path, which is a turn carrying an attachment that
  # is not there.
  test "an entry with no path is dropped" do
    assert_nil Sessions::AttachmentDescriptors.for_a_job(
      [ { media_type: "image/png" } ], keys: IMAGE_KEYS
    )
    assert_nil Sessions::AttachmentDescriptors.for_the_record(
      [ { "path" => "", "media_type" => "image/png" } ], keys: IMAGE_KEYS
    )
  end

  test "nothing usable reads as nil rather than an empty list" do
    [ nil, [], [ "not a hash" ], [ {} ] ].each do |raw|
      assert_nil Sessions::AttachmentDescriptors.for_a_job(raw, keys: IMAGE_KEYS),
        "#{raw.inspect} should carry nothing"
      assert_nil Sessions::AttachmentDescriptors.for_the_record(raw, keys: IMAGE_KEYS),
        "#{raw.inspect} should record nothing"
    end
  end

  test "a usable entry is kept even when an unusable one sits beside it" do
    descriptors = Sessions::AttachmentDescriptors.for_a_job(
      [ { "media_type" => "image/png" }, { "path" => "/b.png", "media_type" => "image/png" } ],
      keys: IMAGE_KEYS
    )

    assert_equal [ { path: "/b.png", media_type: "image/png" } ], descriptors
  end

  # An upload arrives as ActionController::Parameters, which is neither of the
  # two Hash spellings and has to read as both.
  test "request parameters are read like any other descriptor" do
    params = ActionController::Parameters.new(path: "/a.png", media_type: "image/png")

    assert_equal [ { path: "/a.png", media_type: "image/png" } ],
      Sessions::AttachmentDescriptors.for_a_job([ params ], keys: IMAGE_KEYS)
  end

  # A size of 0 is a real (if empty) file, and `||` would have thrown away a
  # `false`-y value the same way.
  test "a zero size is recorded rather than treated as missing" do
    descriptors = Sessions::AttachmentDescriptors.for_a_job(
      [ { "path" => "/empty.txt", "original_filename" => "empty.txt", "size" => 0 } ],
      keys: FILE_KEYS
    )

    assert_equal 0, descriptors.first[:size]
  end
end
