# frozen_string_literal: true

require "test_helper"

class SessionMaintenanceIndexTest < ActiveSupport::TestCase
  test "sessions table has indexes for scheduled maintenance scans" do
    index_names = ActiveRecord::Base.connection.indexes(:sessions).map(&:name)

    assert_includes index_names, "index_sessions_on_id_where_transcript_present"
    assert_includes index_names, "index_sessions_on_archived_stale_clone_candidates"
    assert_includes index_names, "index_sessions_on_legacy_archived_stale_clone_candidates"
    assert_includes index_names, "index_sessions_on_failed_stale_clone_candidates"
    assert_includes index_names, "index_sessions_on_status_trash_after_with_clone_path"
    assert_includes index_names, "index_sessions_on_status_clone_path_expression"
  end
end
