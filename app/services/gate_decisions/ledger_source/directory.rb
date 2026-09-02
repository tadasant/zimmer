# frozen_string_literal: true

module GateDecisions
  module LedgerSource
    # Ledger files read off the local filesystem — a checkout of
    # `tadasant/tadasant-internal`, or the fixture directory the tests build.
    class Directory
      attr_reader :path

      def initialize(path)
        @path = path.to_s
      end

      def describe = "directory #{path}"

      # @return [Array<LedgerFile>] in a stable order, so a resumed import walks
      #   the same sequence the first pass did.
      def files
        raise Unavailable, "#{path} is not a directory" unless File.directory?(path)

        Dir.children(path).sort.filter_map { |name| LedgerFile.parse(name) }
      end

      # @return [Array<Hash>] the entries, in file order
      def entries(file)
        parsed = JSON.parse(File.read(File.join(path, file.name)))
        parsed.is_a?(Array) ? parsed.select { |entry| entry.is_a?(Hash) } : []
      rescue JSON::ParserError => e
        raise Unavailable, "#{file.name} is not valid JSON: #{e.message}"
      end
    end
  end
end
