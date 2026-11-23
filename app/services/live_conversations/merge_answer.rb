# frozen_string_literal: true

module LiveConversations
  # What a line of a Live conversation says about one pull request's merge, as
  # far as Zimmer can read it: the words half of AuthorizeMerge.
  #
  # Two halves, held to different standards, because a voice call has two
  # speakers and only one of them is the authority.
  #
  # == The person
  #
  # Their answer is what authorizes, so it has to be read as a yes before it
  # counts (#answer): at least one word of assent, and every other word one that
  # goes with it. Words, not phrases, so "yeah okay go ahead and merge that PR"
  # needs no entry of its own. Anything else is `:unclear` and counts for
  # nothing. A refusal is `:no`; a condition, a correction or another PR's number
  # is `:takes_back`, which is what undoes a yes already given.
  #
  # == The assistant
  #
  # Its line is the model's own choice of words, transcribed, cut where the
  # person talked over it, and recorded in whatever order it arrived. So nothing
  # a merge needs is read out of it. It is only ever read for a reason a yes was
  # about something else (#changes_subject?): an offer to do another thing, or
  # another PR's number. What is not recognised counts for nothing either way:
  # half a question, "Say yes, and I'll do it.", "Okay, merging."
  class MergeAnswer
    ASSENT = /\b(yes|yeah|yea|yep|yup|yah|correct|confirm|confirmed|affirmative|absolutely|definitely|of\ course|do\ it|
                 do\ that|go\ ahead|go\ for\ it|please\ do|that's\ right|thats\ right|approve|approved|merge|ship\ it|land\ it|
                 sounds\ good|send\ it|proceed|sure|ok|okay)\b/x
    # An assent that can be nothing but the person's own: "okay" also answers
    # "I'll leave it, then."
    STRONG_ASSENT = /\b(yes|yeah|yea|yep|yup|correct|confirm|confirmed|affirmative|absolutely|definitely|do\ it|go\ ahead|
                        go\ for\ it|approve|approved|merge|ship\ it|land\ it|send\ it|proceed)\b/x
    REFUSAL = /\b(no|nope|nah|naw|not|never|none|stop|wait|cancel|cannot|hold|hang\ on|abort|skip|dont|
                  nevermind|forget\ it|leave\ it|unable|[a-z]+n't)\b/x
    # Short conditions and corrections. Any of these after a yes undoes it.
    TAKES_BACK = /\b(but|first|until|unless|after|before|once|when|later|instead|if|wrong|other\ one|another\ one|another\ pr|
                     different|tomorrow|tonight|laptop|computer|revert|undo|rather|except|change\ my\ mind)\b/x
    # What people say next once they have answered. Nothing about the merge.
    MOVING_ON = /\b((and|so|okay|ok|now|then)\s+)*(what('s|s| is) (up )?next|what else)\b.*\z/m
    # Words that go with an assent without changing what it assents to.
    FILLER = %w[
      uh uhh um umm er erm hm hmm mm mhm oh ah so well and then just now please great perfect cool nice awesome good fine
      alright all right thanks thank you lets let's let us we i i'm im it it's its this that that's thats the a one pr prs p r
      pull request number merge merging merged approve approved approval already said say saying told is am i've ive you go ahead
      do for to with in on be been my me mine happy totally exactly yo hey zimmer sounds looks look like ready green ship land
      sure ok okay yes yeah yea yep yup yah correct confirm confirmed affirmative absolutely definitely of course send proceed
    ].to_set.freeze
    # What makes the assistant's talk about merging at all.
    ABOUT_MERGING = /\b(merg\w*|ship(ping|s|ped)?|land(ing|s|ed)?|approv\w*|pull requests?|prs?|p r)\b/i

    OFFER = /\b(want\ me\ to|do\ you\ want|would\ you\ like|want\ to|wanna|should\ i|shall\ i|should\ we|shall\ we|can\ i|could\ i|how\ about|
                what\ about|or\ should)\b/x
    OTHER_ACTION = /\b(restart|re-?run|retry|archive|unarchive|start|stop|close|delete|remove|send|reply|email|deploy|
                      roll\ back|revert|skip|wait|hold|ask|check|look|open|update|schedule|remind|pause|resume|cancel|
                      move\ on|next\ one|show|read|tell|create|run)(ed|d|ing|s)?\b/x
    # Its own merge question may carry an offer word ("should I land it or hold it?").
    ASKS_MERGE = /\b(merg\w*|ship\ it|land\ (it|this|that)|approv\w*)\b/x
    # An order the assistant proposes without asking ("Restart session seven too.").
    OTHER_ORDER = /\A(?:(?:also|and|or|then|so|okay|ok)[\ ,]+)*(restart|rerun|re-run|retry|archive|unarchive|close|delete|remove|
                   send|reply|email|deploy|revert|cancel|pause|resume)\b/x
    # The assistant saying it will not: an "okay" to that is not a yes.
    DECLINES = /\b(won't|wont|will not|not going to|not gonna|hold off|holding off|leave it|leaving it|not merging)\b/

    ONES = %w[zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen
              seventeen eighteen nineteen].freeze
    TENS = %w[_ _ twenty thirty forty fifty sixty seventy eighty ninety].freeze

    Reading = Data.define(:kind, :strong) do
      def yes? = kind == :yes
      def no? = kind == :no
      def takes_back? = kind == :takes_back
    end

    # @param number [String] the PR's number
    # @param names [Array<String>] texts Zimmer knows the PR by (its repository,
    #   the session's title): a person naming the right PR is not a correction
    def initialize(number:, names: [])
      @number = number.to_s
      @forms = spoken_forms(@number)
      @name_words = names.flat_map { |name| words(name) }.to_set
    end

    # @return [Reading] what one line of the person's says
    def answer(text)
      line = plain(text)
      return Reading.new(kind: :no, strong: false) if line.match?(REFUSAL)
      return Reading.new(kind: :takes_back, strong: false) if line.match?(TAKES_BACK) || other_number?(line)

      said = line.sub(MOVING_ON, " ")
      return Reading.new(kind: :unclear, strong: false) if said.include?("?") || !said.match?(ASSENT)

      rest = without_number(words(said)).reject { |word| FILLER.include?(word) || @name_words.include?(word) }
      Reading.new(kind: rest.empty? ? :yes : :unclear, strong: said.match?(STRONG_ASSENT))
    end

    # Whether an assistant line gives a yes after it something else to be about.
    # @param answer [Reading] that yes
    def changes_subject?(text, answer)
      sentences(text).any? do |sentence|
        next true if sentence.match?(DECLINES) && !answer.strong
        next true if other_pr?(sentence)
        next false if sentence.match?(ASKS_MERGE)

        (sentence.match?(OFFER) && sentence.match?(OTHER_ACTION)) || other_order?(sentence)
      end
    end

    # Whether the last thing an assistant asked is to merge one PR. Read only to
    # spare a question (AuthorizeMerge#already_said_yes), so it is strict.
    def self.asks_to_merge?(text)
      question = text.to_s.downcase.split(/(?<=[.?!;])\s+/).reverse.find { |sentence| sentence.include?("?") }
      return false if question.nil?

      question.match?(/(?<!the )\bmerge\b(?! gate| queue| of\b)/) && !question.match?(/\b(them|both|either|which|all|two|three|these|those|or)\b/)
    end

    # Whether the person told it to merge, rather than answering.
    def self.says_merge?(text) = text.to_s.match?(/\b(merge|ship it|land it)\b/i)

    def self.about_merging?(text) = text.to_s.match?(ABOUT_MERGING)

    private

    def plain(text) = text.to_s.tr("‘’ʼ", "'").downcase.gsub(/\[[^\]]*\]?/, " ").gsub(/[^a-z0-9'?,.]+/, " ").squish

    def words(text) = plain(text).gsub(/(\d),(\d)/, '\1\2').gsub(/[^a-z0-9']+/, " ").split

    # Zimmer's question quotes the session's title, which is not the model's.
    def sentences(text)
      text.to_s.gsub(/["“][^"”]*["”]/, " ").split(/(?<=[.?!;])\s+/).map { |sentence| plain(sentence) }
    end

    # Not a fragment of the title ("Archive old sessions", "stop the sweep"),
    # which a cut-off question leaves behind.
    def other_order?(sentence)
      return false unless sentence.match?(OTHER_ORDER) && sentence.match?(/\?|\bsession\b|\btoo\b|\bas well\b/)

      !words(sentence).all? { |word| @name_words.include?(word) || FILLER.include?(word) }
    end

    # A sentence that asks to merge a pull request by a number that is not this
    # PR's, nor the start of it where the line was cut. Only right after
    # "merge": "it follows up pull request 12, want to merge it?" is this PR's
    # question.
    def other_pr?(sentence)
      tokens = words(sentence)
      named = tokens.each_index.filter_map do |i|
        next unless %w[request requests pr prs number].include?(tokens[i]) && tokens[[ i - 6, 0 ].max...i].include?("merge")

        run = tokens.drop(i + 1).take_while { |word| number_word?(word) }
        run if run.size > 1 || run.first.to_s.match?(/\A\d{2,}\z/)
      end
      named.any? && named.none? { |run| ours?(run) }
    end

    # A number in the person's line that is not this PR's. One number word on
    # its own ("that one", "two seconds") names nothing.
    def other_number?(line)
      runs = without_number(words(line)).chunk_while { |one, two| number_word?(one) == number_word?(two) }.select { |run| number_word?(run.first) }
      runs.any? { |run| run.size > 1 || run.first.match?(/\A\d{2,}\z/) }
    end

    def ours?(run)
      joined = run.join(" ")
      @forms.any? { |form| form == joined || form.start_with?("#{joined} ") } ||
        (run.all? { |word| word.match?(/\A\d+\z/) } && @number.start_with?(run.join))
    end

    # The words with this PR's number taken out, however it was said. A whole
    # run of number words at a time, so "fourteen ninety one" is not 1490.
    def without_number(list)
      list = list.reject.with_index { |word, i| word == "and" && i.positive? && %w[hundred thousand].include?(list[i - 1]) }
      list.chunk_while { |one, two| number_word?(one) == number_word?(two) }
          .reject { |run| @forms.include?(run.join(" ")) }.flatten
    end

    def number_word?(word) = word.match?(/\A\d+\z/) || ONES.include?(word) || TENS.include?(word) || %w[oh hundred thousand].include?(word)

    # Every way a transcript is likely to write the number, as plain words.
    def spoken_forms(digits)
      return [] unless digits.match?(/\A[1-9]\d{0,5}\z/)

      forms = [ digits, cardinal(digits.to_i) ]
      if digits.length >= 3 && digits.end_with?("00")
        prefix = digits[0..-3]
        forms << "#{prefix} hundred" << "#{cardinal(prefix.to_i)} hundred"
      end
      chunkings(digits).each do |chunks|
        chunks.map { |chunk| chunk_forms(chunk) }.reduce { |acc, nxt| acc.product(nxt).map { |a, b| "#{a} #{b}" } }
              .each { |form| forms << form }
      end
      forms.uniq
    end

    # The number split into runs of one or two digits, every way.
    def chunkings(digits)
      return [ [] ] if digits.empty?

      [ 1, 2 ].flat_map do |size|
        next [] if digits.length < size

        chunkings(digits[size..]).map { |rest| [ digits[0, size], *rest ] }
      end
    end

    def chunk_forms(chunk)
      value = chunk.to_i
      spoken = if chunk.length == 1
        [ ONES[value], (value.zero? ? "oh" : nil) ].compact
      elsif chunk.start_with?("0")
        [ "oh #{ONES[value]}", "zero #{ONES[value]}" ]
      else
        [ cardinal(value) ]
      end
      spoken << chunk
    end

    def cardinal(value)
      return ONES[value] if value < 20
      return [ TENS[value / 10], (ONES[value % 10] unless (value % 10).zero?) ].compact.join(" ") if value < 100
      if value < 1_000
        return [ ONES[value / 100], "hundred", (cardinal(value % 100) unless (value % 100).zero?) ].compact.join(" ")
      end

      [ cardinal(value / 1_000), "thousand", (cardinal(value % 1_000) unless (value % 1_000).zero?) ].compact.join(" ")
    end
  end
end
