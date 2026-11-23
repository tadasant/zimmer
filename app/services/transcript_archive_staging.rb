# frozen_string_literal: true

require "zip"
require "fileutils"

# Where TranscriptArchiveJob keeps the sessions it has read but not yet joined into
# `latest.zip`: one small zip per session, `<id>@<stamp>.zip`.
#
# A fragment is the job's unit of durable progress. It appears by rename once it is whole,
# and its name carries the freshness stamp it was built at, so a run killed at any point
# loses at most the session it was reading: the next run finds the rest here and does not
# read them again. Nothing is a candidate for deletion until a finished `latest.zip` holds it.
class TranscriptArchiveStaging
  FRAGMENT_PATTERN = /\A(\d+)@(.+)\.zip\z/
  TEMP_NAME = "fragment.zip.tmp"

  Fragment = Struct.new(:path, :session_id, :stamp)

  attr_reader :pruned_ids

  def initialize(dir)
    @dir = dir
    @pruned_ids = Set.new
    FileUtils.mkdir_p(dir)
    discard_open_fragment
    delete(all_fragments - fragments.values)
  end

  # The newest fragment per session id. A kill between a commit's rename and its cleanup
  # leaves two for one session; the stamps are fixed-width ISO 8601, so the later one wins.
  def fragments
    all_fragments.group_by(&:session_id).transform_values { |copies| copies.max_by(&:stamp) }
  end

  def stamps = fragments.transform_values(&:stamp)

  def any? = Dir.each_child(@dir).any? { |name| name.match?(FRAGMENT_PATTERN) }

  def bytes = fragments.each_value.sum { |fragment| File.size(fragment.path) }

  # Adds one entry to the fragment being written. Compressed in a single call, so the
  # deflate runs outside the interpreter lock instead of fighting for it per chunk.
  # A retried read puts the same names again; the first copy is kept.
  def put(name, data)
    @open ||= ::Zip::OutputStream.open(temp_path)
    return unless (@names ||= Set.new).add?(name)

    @open.put_next_entry(name)
    @open.write(data)
  end

  # Makes the fragment being written durable as +session_id+'s, and returns +stamp+.
  def commit(session_id, stamp)
    @open.close
    @open = @names = nil
    File.open(temp_path) { |file| file.fsync }
    path = File.join(@dir, "#{session_id}@#{stamp}.zip")
    File.rename(temp_path, path)
    paths_for([ session_id ]).each { |other| FileUtils.rm_f(other) unless other == path }
    stamp
  end

  # Forgets sessions that are gone, and remembers them so the merge drops their entries.
  def prune(session_ids)
    @pruned_ids.merge(session_ids.map(&:to_s))
    paths_for(session_ids).each { |path| FileUtils.rm_f(path) }
  end

  def delete(fragments)
    fragments.each { |fragment| FileUtils.rm_f(fragment.path) }
  end

  # Drops the fragment a failed or killed run was part-way through.
  def discard_open_fragment
    @open&.close
  rescue StandardError
    nil
  ensure
    @open = @names = nil
    FileUtils.rm_f(temp_path)
  end

  private

  def all_fragments
    Dir.each_child(@dir).filter_map do |name|
      match = FRAGMENT_PATTERN.match(name)
      Fragment.new(File.join(@dir, name), match[1], match[2]) if match
    end
  end

  def temp_path = File.join(@dir, TEMP_NAME)

  def paths_for(session_ids)
    wanted = session_ids.to_set(&:to_s)
    return [] if wanted.empty?

    Dir.each_child(@dir).filter_map do |name|
      File.join(@dir, name) if wanted.include?(name[FRAGMENT_PATTERN, 1])
    end
  end
end
