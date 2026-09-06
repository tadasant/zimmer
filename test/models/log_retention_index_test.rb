# frozen_string_literal: true

require "test_helper"

# `logs` is the highest-write table in the schema and the one whose retention
# sweep saturated Postgres (tadasant/zimmer#329), so what indexes it carries is
# worth pinning rather than leaving to whatever the last schema dump happened to
# hold.
class LogRetentionIndexTest < ActiveSupport::TestCase
  setup { @indexes = ActiveRecord::Base.connection.indexes(:logs) }

  test "logs carries the index LogRetentionJob's verbose batch selector needs" do
    index = @indexes.find { |i| i.name == "index_logs_on_level_and_id_and_created_at" }

    # This pins the committed schema dump, which is what a fresh database loads.
    # On a deployed database the index's existence is the post-deploy task's job —
    # the migration declines to build it there.
    assert index, "the retention scan index must be in db/schema.rb"
    assert_equal %w[level id created_at], index.columns,
      "the order is load-bearing: `level` is the equality, `id` is the ordered range the LIMIT " \
      "stops on, and `created_at` rides along to make the scan index-only"
    assert_not index.unique
    assert_nil index.where, "the index serves the general pass too, so it is not partial on `verbose`"
  end

  test "the index index_logs_on_level was a strict prefix of it and is gone" do
    assert_not_includes @indexes.map(&:name), "index_logs_on_level",
      "carrying both would put a fourth btree on the hot path of every session's timeline writes"
  end
end
