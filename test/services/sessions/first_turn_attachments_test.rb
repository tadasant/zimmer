# frozen_string_literal: true

require "test_helper"

# The attachments a first turn was created with, read back off the durable
# volume. Two properties matter: what it returns is what the turn was created
# with (not what a queued follow-up owns), and it NEVER raises — every caller is
# a start path, and one of them is a restart reached because something already
# went wrong.
class Sessions::FirstTurnAttachmentsTest < ActiveSupport::TestCase
  include AttachmentFixtures

  teardown { cleanup_stored_attachments! }

  def session_with_attachments
    Session.create!(
      git_root: "https://github.com/t/r.git", prompt: "here is the screenshot, fix this",
      status: :failed, metadata: { "failure_reason" => "git_clone_failed" }
    )
  end

  test "describes the images and files the session was created with" do
    session = session_with_attachments
    image = store_image_for(session)
    file = store_file_for(session, filename: "notes.txt", content: "read me")

    images, files = Sessions::FirstTurnAttachments.for(session)

    assert_equal [ { path: image[:path], media_type: "image/png" } ], images
    assert_equal [ file[:path] ], files.map { |entry| entry[:path] }
    assert_equal [ "notes.txt" ], files.map { |entry| entry[:original_filename] }
  end

  test "a session that stored nothing carries nothing" do
    assert_equal [ [], [] ], Sessions::FirstTurnAttachments.for(session_with_attachments)
  end

  # Both kinds live in the same per-session directory, so "everything on disk"
  # is not the same set as "what the first turn carried".
  test "an attachment a queued message owns is left for that message" do
    session = session_with_attachments
    first_turn = store_image_for(session)
    follow_up = store_image_for(session)
    session.enqueued_messages.create!(
      content: "and now this one", position: 1,
      images: [ { "path" => follow_up[:path], "media_type" => "image/png" } ]
    )

    images, = Sessions::FirstTurnAttachments.for(session)

    assert_equal [ { path: first_turn[:path], media_type: "image/png" } ], images
  end

  # A turn short an attachment is a worse turn; a turn carrying somebody else's
  # is a wrong one. An unreadable queue therefore falls back to the former.
  test "an unreadable message queue falls back to no attachments" do
    session = session_with_attachments
    store_image_for(session)

    session.stub(:enqueued_messages, ->(*) { raise ActiveRecord::StatementInvalid, "boom" }) do
      assert_equal [ [], [] ], Sessions::FirstTurnAttachments.for(session)
    end
  end

  # The property the restart paths depend on: a storage tree that cannot be read
  # is a turn with no attachments, never an exception that refuses the restart.
  test "an unreadable storage tree is no attachments rather than a raise" do
    session = session_with_attachments
    store_image_for(session)

    ImageStorageService.stub(:stored_for, ->(*) { raise Errno::EACCES, "storage" }) do
      assert_equal [ [], [] ], Sessions::FirstTurnAttachments.for(session)
    end
  end

  test "the carrying clause names what a turn holds, and is empty when it holds nothing" do
    assert_equal "", Sessions::FirstTurnAttachments.carrying_clause([], [])
    assert_equal ", carrying 1 image", Sessions::FirstTurnAttachments.carrying_clause([ {} ], [])
    assert_equal ", carrying 2 images and 1 file",
      Sessions::FirstTurnAttachments.carrying_clause([ {}, {} ], [ {} ])
  end
end
