# frozen_string_literal: true

module GateDecisions
  # Backfills the historical gate ledgers into `gate_decisions`.
  #
  # SAFE TO RUN BEFORE ANYTHING WRITES, AND SAFE TO RUN AGAIN. It only ever
  # inserts. It never updates a row, never deletes one, and never touches the
  # source JSON — the files stay exactly where they are, which is what lets this
  # ship ahead of the gates being cut over in a later phase.
  #
  # THE IDEMPOTENCY KEY, AND WHY IT CARRIES AN ORDINAL
  #
  # The natural key is `(gate, surface, artifact_url, decided_at)`. On the real
  # corpus that key is NOT unique: 52 of its groups hold two or three entries,
  # 59 rows in total. Those are re-rates — a gate rating the same PR twice in one
  # day because the base branch moved under it, or correcting itself — and they
  # are genuinely distinct decisions, which is precisely the history a gate
  # calibrating against its own record needs to see. Keying on the bare tuple
  # would have silently dropped all 59.
  #
  # So the key is the tuple plus the entry's ordinal WITHIN that tuple's group, in
  # file order. The ledgers are append-only, so an entry's position among its
  # same-key siblings never changes, which is what makes a second pass a no-op.
  class LedgerImporter
    # A decision's whole entry averages 11.5 KB, so a batch is sized for a
    # sensible transaction rather than for row count.
    BATCH_SIZE = 50

    FileResult = Struct.new(:name, :gate, :surface, :entries, :imported, :skipped, :feedback_imported,
                            keyword_init: true)

    Result = Struct.new(:files, :remaining, keyword_init: true) do
      def entries = files.sum(&:entries)
      def imported = files.sum(&:imported)
      def skipped = files.sum(&:skipped)
      def feedback_imported = files.sum(&:feedback_imported)
      def complete? = remaining.empty?
    end

    attr_reader :source, :logger

    def initialize(source: LedgerSource.resolve, logger: Rails.logger)
      @source = source
      @logger = logger
    end

    # @param done [Array<String>] file names an earlier slice already finished
    # @param stop_when [Proc, nil] called between files; truthy means hand the
    #   worker thread back and report what is left
    # @return [Result]
    def call(done: [], stop_when: nil)
      finished = done.to_set
      pending = source.files.reject { |file| finished.include?(file.name) }
      results = []

      pending.each_with_index do |file, index|
        results << import_file(file)

        remaining = pending[(index + 1)..] || []
        return Result.new(files: results, remaining: remaining.map(&:name)) if remaining.any? && stop_when&.call
      end

      Result.new(files: results, remaining: [])
    end

    private

    def import_file(file)
      entries = source.entries(file)
      ordinals = Hash.new(0)
      imported = 0
      skipped = 0
      feedback = 0

      entries.each_slice(BATCH_SIZE) do |slice|
        GateDecision.transaction do
          slice.each do |raw|
            parsed = Entry.new(gate: file.gate, surface: file.surface, raw: raw)
            key = source_key(file, parsed, ordinals)

            existing = GateDecision.find_by(source_key: key)
            if existing
              skipped += 1
              feedback += import_feedback(existing, parsed)
              next
            end

            result = Record.call(
              gate: file.gate, surface: file.surface, entry: raw,
              recorded_via: GateDecision::IMPORT, source_key: key
            )
            result.created? ? imported += 1 : skipped += 1
            feedback += import_feedback(result.decision, parsed)
          end
        end
      end

      logger.info("[GateDecisions::LedgerImporter] #{file.name}: #{entries.size} entries, " \
                  "#{imported} imported, #{skipped} already present")

      FileResult.new(name: file.name, gate: file.gate, surface: file.surface, entries: entries.size,
                     imported: imported, skipped: skipped, feedback_imported: feedback)
    end

    # `#<ordinal>` disambiguates re-rates sharing a natural key; see the class
    # comment. Truncated at the URL, which is the only unbounded part, so the key
    # always fits a btree index entry.
    def source_key(file, parsed, ordinals)
      natural = [ file.gate, file.surface, parsed.artifact_url.to_s.truncate(512), parsed.decided_at ].join("|")
      ordinals[natural] += 1
      "#{natural}##{ordinals[natural]}"
    end

    # The `human_feedback` array a source entry carried, as GateDecisionFeedback
    # rows on the `imported` channel.
    #
    # Written here and nowhere else on any machine path. The channel says plainly
    # what these are — notes transcribed from the JSON ledgers, not words typed
    # into Zimmer by a person — so a reader can tell a backfilled note from one
    # that came through the human boundary. Existing notes are matched on what
    # they say, so a re-run adds nothing.
    def import_feedback(decision, parsed)
      notes = parsed.human_feedback
      return 0 if notes.empty?

      existing = decision.feedbacks.pluck(:received_at, :verdict, :note).to_set
      created = 0

      notes.each do |note|
        received_at = parse_date(note["received_at"])
        verdict = note["verdict"].presence || "unspecified"
        body = note["note"].presence&.to_s&.truncate(GateDecisionFeedback::MAX_NOTE_LENGTH)
        next if existing.include?([ received_at, verdict, body ])

        decision.feedbacks.create!(
          verdict: verdict.to_s.truncate(GateDecisionFeedback::MAX_VERDICT_LENGTH),
          note: body,
          received_at: received_at,
          # Nullable on this channel deliberately: the source recorded what was
          # said, not always who said it, and a plausible-looking author invented
          # by an importer is the exact forgery this table exists to prevent.
          author: note["author"].presence&.to_s,
          channel: GateDecisionFeedback::IMPORTED,
          payload: note.except("received_at", "verdict", "note", "author")
        )
        existing << [ received_at, verdict, body ]
        created += 1
      end

      created
    end

    def parse_date(value)
      return nil if value.blank?
      return value if value.is_a?(Date)

      Date.iso8601(value.to_s.strip)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
