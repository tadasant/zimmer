# frozen_string_literal: true

require "test_helper"
require "zip"

class TranscriptArchiveSplicerTest < ActiveSupport::TestCase
  setup { @dir = Dir.mktmpdir("transcript_archive_splicer_test") }
  teardown { FileUtils.rm_rf(@dir) }

  def path(name) = File.join(@dir, name)

  # rubyzip's two shapes: what a fragment is, and what `latest.zip` was when the job wrote
  # it through `write_buffer`.
  def streamed(name, files)
    Zip::OutputStream.open(path(name)) { |zip| files.each { |k, v| zip.put_next_entry(k); zip.write(v) } }
    path(name)
  end

  def buffered(name, files)
    zip = Zip::File.new(path("absent.zip"), create: true)
    files.each { |k, v| zip.get_output_stream(k) { |os| os.write(v) } }
    File.open(path(name), "wb") { |file| zip.write_buffer(file).close }
    path(name)
  end

  def splice(*sources)
    out = path("out.zip")
    File.open(out, "wb") { |io| TranscriptArchiveSplicer.splice(io, sources) }
    out
  end

  def all(source) = [ source, TranscriptArchiveSplicer.entries_at(source) ]

  def contents(zip_path)
    Zip::File.open(zip_path) { |zip| zip.entries.to_h { |e| [ e.name.b, zip.read(e).b ] } }
  end

  test "joins rubyzip archives of both shapes, byte for byte" do
    files = { "a.json" => "A" * 10_000, "é.json" => SecureRandom.random_bytes(50_000), "empty" => "" }
    more = { "b.json" => "B" }

    merged = splice(all(buffered("base.zip", files)), all(streamed("more.zip", more)))

    expected = files.merge(more).to_h { |name, data| [ name.b, data.b ] }
    assert contents(merged) == expected, "the merged archive must hold exactly the source entries"
    FileUtils.mv(merged, path("merged.zip"))
    assert contents(splice(all(path("merged.zip")))) == expected, "it reads its own output"
  end

  test "drops entries from the middle and closes the gap" do
    base = streamed("base.zip", (1..5).to_h { |n| [ n.to_s, "x" * n * 1000 ] })
    kept = TranscriptArchiveSplicer.entries_at(base).reject { |e| %w[2 4].include?(e.name) }

    merged = splice([ base, kept ])

    assert_equal %w[1 3 5], contents(merged).keys.sort
    assert_operator File.size(merged), :<, File.size(base)
  end

  test "an unchanged archive is one copy, however many entries it has" do
    base = streamed("base.zip", (1..200).to_h { |n| [ n.to_s, n.to_s ] })
    entries = TranscriptArchiveSplicer.entries_at(base)
    IO.expects(:copy_stream).once.with { |_, _, length, start| start.zero? && length == entries.sum(&:length) }.returns(entries.sum(&:length))
    splice([ base, entries ])
  end

  test "an archive with no entries and one past 65,535 entries both round-trip" do
    assert_empty TranscriptArchiveSplicer.entries_at(splice([ path("unused"), [] ]))

    names = (1..66_000).map { |n| "sessions/#{n}.json" }
    merged = splice(all(streamed("many.zip", names.index_with { "" })))
    assert_equal names, TranscriptArchiveSplicer.entries_at(merged).map(&:name)
    assert_equal 66_000, Zip::File.open(merged) { |zip| zip.size }
  end

  # Past 4 GiB an offset moves into the ZIP64 block. Checked on the record itself, read
  # back by rubyzip, rather than by writing 4 GiB.
  test "relocating a record across the 4 GiB boundary and back" do
    record = TranscriptArchiveSplicer.entries_at(streamed("one.zip", "a.json" => "A" * 100)).sole.record
    read = ->(bytes) { Zip::Entry.read_c_dir_entry(StringIO.new(bytes)) }
    offset = ->(entry) { entry.extra[:zip64]&.relative_header_offset || entry.local_header_offset }

    [ 0, 12_345, 0xFFFFFFFE, 0xFFFFFFFF, 14_000_000_000 ].each do |target|
      moved = TranscriptArchiveSplicer.relocate(record, target)
      entry = read.(moved)
      assert_equal target, offset.(entry)
      assert_equal [ "a.json", 100 ], [ entry.name, entry.size ]

      back = read.(TranscriptArchiveSplicer.relocate(moved, 7))
      assert_equal 7, offset.(back)
    end
  end

  test "refuses a file that is not a whole zip" do
    good = File.binread(streamed("good.zip", "a" => "A" * 1000, "b" => "B"))
    {
      "empty" => "", "garbage" => "x" * 5000, "truncated" => good[0...-30],
      "headless" => good[10..], "trailing" => good + ("x" * 40)
    }.each do |name, bytes|
      File.binwrite(path(name), bytes)
      assert_raises(TranscriptArchiveSplicer::Invalid, name) { TranscriptArchiveSplicer.entries_at(path(name)) }
    end
  end

  test "a source that shrinks under the copy raises rather than writing a short archive" do
    source = streamed("base.zip", "a" => SecureRandom.random_bytes(100_000))
    entries = TranscriptArchiveSplicer.entries_at(source)
    File.truncate(source, 50_000)
    assert_raises(TranscriptArchiveSplicer::Invalid) { splice([ source, entries ]) }
  end
end
