# frozen_string_literal: true

# Joins zip files into one by copying their compressed bytes verbatim.
#
# WHY THIS EXISTS RATHER THAN RUBYZIP
#
# TranscriptArchiveJob carries a multi-gigabyte archive forward on every rebuild, and the
# two things rubyzip does on the way are each a run-ender at that size:
#
#   * Opening an archive seeks to every entry's local header, so the cost is one random
#     read per entry. The archive holds tens of thousands.
#   * Writing one copies 128 KiB at a time through Ruby. Each chunk is a read and a write
#     that give up the interpreter lock and then queue to get it back, and in a worker
#     full of busy threads that is up to a scheduler quantum (100 ms) each time. Measured
#     on production on 2026-11-23: 391 seconds to write a 77 MB archive.
#
# Here the source is described by its central directory alone (one contiguous read), runs
# of neighbouring entries are copied with one `IO.copy_stream` (which stays in the kernel
# and holds no interpreter lock), and only the directory's offsets are rewritten. An
# unchanged archive is one copy, whatever its entry count.
#
# An entry's bytes are taken as everything from its local header to the next entry's, so
# this reads archives whose entries are packed back to back: what rubyzip writes and what
# this writes. Every slot is checked against the entry's own sizes. When one does not fit,
# the entries are found by walking the local headers instead, which rubyzip keeps right
# when its directory is wrong: moving an entry from above 4 GiB to below it leaves the old
# 64-bit offset in the directory. Anything that still does not add up raises Invalid before
# a byte is copied.
class TranscriptArchiveSplicer
  class Invalid < StandardError; end

  LOCAL_HEADER_SIZE = 30
  RECORD_SIG = 0x02014b50
  RECORD_SIZE = 46
  EOCD_SIG = 0x06054b50
  EOCD_SIZE = 22
  EOCD64_SIG = 0x06064b50
  EOCD64_SIZE = 56
  LOCATOR_SIG = 0x07064b50
  LOCATOR_SIZE = 20
  MAX_COMMENT = 0xFFFF
  LOCAL_SIG = 0x04034b50
  # The most a local header's extra field adds to an entry: a ZIP64 block and a timestamp.
  LOCAL_EXTRA_MAX = 64
  ZIP64_ID = 0x0001
  ZIP64_VERSION = 45
  U16 = 0xFFFF
  U32 = 0xFFFFFFFF

  # One central-directory record: its raw bytes, and where its entry lives in the source.
  Entry = Struct.new(:name, :record, :offset, :length, :compressed)

  class << self
    # The entries of the zip open at +io+, in file order.
    def entries(io)
      directory_offset, directory_size, count = locate_directory(io)
      directory = io.pread(directory_size, directory_offset) if directory_size.positive?
      parsed = parse_directory(directory || "".b, count).sort_by(&:offset)

      parsed.each_with_index do |entry, index|
        ends_at = parsed[index + 1]&.offset || directory_offset
        entry.length = ends_at - entry.offset
      end
      parsed.all? { |entry| fits?(entry) } ? parsed : relocate_by_walking(io, parsed, directory_offset)
    rescue EOFError, TypeError, ArgumentError, RangeError, NoMethodError, Errno::EINVAL => e
      raise Invalid, "unreadable zip: #{e.message}"
    end

    def entries_at(path) = File.open(path, "rb") { |io| entries(io) }

    # Writes the kept entries of every source to +out+ as one zip. +sources+ is a list of
    # [source, entries to keep], each source an open File or a path. A path is open only
    # while it is copied, so thousands of small sources do not need thousands of handles.
    def splice(out, sources)
      out.sync = true
      position = 0
      records = []

      sources.each do |source, kept|
        next if kept.empty?

        io = source.is_a?(File) ? source : (opened = File.open(source, "rb"))
        contiguous_runs(kept).each do |run|
          start = run.first.offset
          length = run.sum(&:length)
          copied = IO.copy_stream(io, out, length, start)
          raise Invalid, "source ended after #{copied} of #{length} bytes at #{start}" unless copied == length

          run.each { |entry| records << relocate(entry.record, position + entry.offset - start) }
          position += length
        end
      ensure
        opened&.close
      end

      out.write(directory_bytes(records, position))
    end

    # A central-directory record pointing at +offset+. The ZIP64 block, when the record
    # needs one, is rebuilt to hold exactly the fields the fixed part marks as overflowed.
    def relocate(record, offset)
      size, compressed = record.unpack("@24V@20V")
      name_length, extra_length, comment_length = record.unpack("@28vvv")
      name_and_fixed = record.byteslice(0, RECORD_SIZE + name_length)
      extra = record.byteslice(RECORD_SIZE + name_length, extra_length)
      comment = record.byteslice(RECORD_SIZE + name_length + extra_length, comment_length)

      wide, others = split_zip64(extra)
      values = []
      values << wide.shift if size == U32
      values << wide.shift if compressed == U32
      raise Invalid, "a ZIP64 record is missing its sizes" if values.any?(&:nil?)

      values << offset if offset >= U32
      extra = others
      extra = [ ZIP64_ID, values.size * 8, *values ].pack("vvQ<*") + extra if values.any?

      head = name_and_fixed.dup
      head[6, 2] = [ [ head.unpack1("@6v"), ZIP64_VERSION ].max ].pack("v") if values.any?
      head[30, 2] = [ extra.bytesize ].pack("v")
      head[42, 4] = [ [ offset, U32 ].min ].pack("V")
      head + extra + comment
    end

    private

    def locate_directory(io)
      file_size = io.size
      tail_size = [ file_size, EOCD_SIZE + MAX_COMMENT ].min
      raise Invalid, "#{file_size} bytes is too small to be a zip" if tail_size < EOCD_SIZE

      tail = io.pread(tail_size, file_size - tail_size)
      at = tail.rindex([ EOCD_SIG ].pack("V"))
      raise Invalid, "no end-of-central-directory record" unless at && tail_size - at >= EOCD_SIZE

      count, size, offset, comment_length = tail.unpack("@#{at}x10vVVv")
      raise Invalid, "bytes after the end of the archive" unless at + EOCD_SIZE + comment_length == tail_size

      eocd_at = file_size - tail_size + at
      ends_at = eocd_at
      if count == U16 || size == U32 || offset == U32
        count, size, offset, ends_at = locate_directory64(io, eocd_at) || [ count, size, offset, eocd_at ]
      end
      raise Invalid, "the central directory does not end where its record says" unless offset + size == ends_at

      [ offset, size, count ]
    end

    # Nil when there is no ZIP64 locator: 65,535 entries is also a legal plain count.
    def locate_directory64(io, eocd_at)
      return if eocd_at < LOCATOR_SIZE

      signature, _disk, at = io.pread(LOCATOR_SIZE, eocd_at - LOCATOR_SIZE).unpack("VVQ<")
      return unless signature == LOCATOR_SIG

      record = io.pread(EOCD64_SIZE, at)
      raise Invalid, "no ZIP64 end-of-central-directory record" unless record.unpack1("V") == EOCD64_SIG

      count, size, offset = record.unpack("@32Q<Q<Q<")
      [ count, size, offset, at ]
    end

    def parse_directory(directory, count)
      at = 0
      entries = []
      while at < directory.bytesize
        raise Invalid, "bad central-directory record at #{at}" unless directory.unpack1("V", offset: at) == RECORD_SIG

        name_length, extra_length, comment_length = directory.byteslice(at + 28, 6).unpack("vvv")
        length = RECORD_SIZE + name_length + extra_length + comment_length
        record = directory.byteslice(at, length)
        raise Invalid, "truncated central-directory record at #{at}" unless record.bytesize == length

        name = record.byteslice(RECORD_SIZE, name_length).force_encoding(Encoding::UTF_8)
        entries << entry_for(name, record, extra_length)
        at += length
      end
      raise Invalid, "expected #{count} entries, found #{entries.size}" unless entries.size == count

      entries
    end

    def entry_for(name, record, extra_length)
      compressed, size = record.unpack("@20VV")
      offset = record.unpack1("@42V")
      wide, = split_zip64(record.byteslice(RECORD_SIZE + name.bytesize, extra_length))
      wide.shift if size == U32
      compressed = wide.shift if compressed == U32
      offset = wide.shift if offset == U32
      raise Invalid, "a ZIP64 record is missing a value" if compressed.nil? || offset.nil?

      Entry.new(name, record, offset, nil, compressed)
    end

    # The slack above the minimum is the local header's extra field.
    def fits?(entry)
      least = LOCAL_HEADER_SIZE + entry.name.bytesize + entry.compressed
      entry.length.between?(least, least + LOCAL_EXTRA_MAX)
    end

    # Takes each entry's place from the local headers, read one after another from the
    # start of the file. One small read per entry, so it is the fallback, not the rule.
    def relocate_by_walking(io, entries, directory_offset)
      found = {}
      at = 0
      while at < directory_offset
        header = io.pread(LOCAL_HEADER_SIZE, at)
        raise Invalid, "no entry where one was expected, at #{at}" unless header.unpack1("V") == LOCAL_SIG

        compressed, size, name_length, extra_length = header.unpack("@18VVvv")
        rest = io.pread(name_length + extra_length, at + LOCAL_HEADER_SIZE)
        if compressed == U32
          wide, = split_zip64(rest.byteslice(name_length, extra_length))
          compressed = wide[size == U32 ? 1 : 0] || raise(Invalid, "a ZIP64 entry at #{at} is missing its size")
        end
        length = LOCAL_HEADER_SIZE + name_length + extra_length + compressed
        name = rest.byteslice(0, name_length).force_encoding(Encoding::UTF_8)
        found[name] = [ at, length, compressed ]
        at += length
      end
      raise Invalid, "the last entry runs into the central directory" unless at == directory_offset

      entries.each do |entry|
        entry.offset, entry.length, compressed = found[entry.name]
        raise Invalid, "#{entry.name} is not where its size says" unless compressed == entry.compressed
      end
      entries.sort_by(&:offset)
    end

    # [the ZIP64 block's 64-bit values, every other extra block's bytes]
    def split_zip64(extra)
      wide = []
      others = +"".b
      at = 0
      while at + 4 <= extra.bytesize
        id, length = extra.byteslice(at, 4).unpack("vv")
        block = extra.byteslice(at, 4 + length)
        if id == ZIP64_ID
          wide = block.byteslice(4, length).unpack("Q<*")
        else
          others << block
        end
        at += 4 + length
      end
      [ wide, others ]
    end

    def contiguous_runs(entries)
      entries.slice_when { |a, b| a.offset + a.length != b.offset }
    end

    def directory_bytes(records, offset)
      directory = records.join
      eocd64 = +"".b
      if records.size >= U16 || offset >= U32 || directory.bytesize >= U32
        eocd64 << [ EOCD64_SIG, EOCD64_SIZE - 12, ZIP64_VERSION, ZIP64_VERSION, 0, 0,
                    records.size, records.size, directory.bytesize, offset ].pack("VQ<vvVVQ<Q<Q<Q<")
        eocd64 << [ LOCATOR_SIG, 0, offset + directory.bytesize, 1 ].pack("VVQ<V")
      end
      eocd = [ EOCD_SIG, 0, 0, [ records.size, U16 ].min, [ records.size, U16 ].min,
               [ directory.bytesize, U32 ].min, [ offset, U32 ].min, 0 ].pack("VvvvvVVv")
      directory.b << eocd64 << eocd
    end
  end
end
