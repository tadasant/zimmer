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
  # needs no entry of its own. A refusal is `:no`; a condition, a correction or
  # another PR's number is `:takes_back`; a line of nothing but filler, or moving
  # on ("what's next"), is `:neutral`; anything else is `:unclear`. A yes stands
  # only while what follows it is another yes or neutral, so a retraction needs
  # no entry here either.
  #
  # == The assistant
  #
  # Its line is the model's own choice of words, transcribed, cut where the
  # person talked over it, and recorded in whatever order it arrived. So a clear
  # yes needs nothing read out of it. It is read for a reason a yes was about
  # something else (#changes_subject?): an offer to do another thing, another
  # PR's number, or asking to merge at another time, and for a yes that is not
  # clear, the assistant saying it will not merge. What is not recognised there
  # counts for nothing: half a question, "Say yes, and I'll do it.", "Okay,
  # merging." And it is read for the merge being asked about (#asks?) where that
  # is the stricter side: an "okay", which answers anything, and a yes nobody has
  # called a confirmation.
  class MergeAnswer
    ASSENT = /\b(yes|yeah|yea|yep|yup|yah|correct|confirm|confirmed|affirmative|absolutely|definitely|of\ course|do\ it|
                 do\ that|go\ ahead|go\ for\ it|please\ do|that's\ right|thats\ right|approve|approved|merge|ship\ it|land\ it|
                 sounds\ good|send\ it|proceed|fine\ by\ me|works\ for\ me|that\ works|lgtm|sure|ok|okay)\b/x
    # An assent that does not also answer "I'll leave it, then" or "here's what
    # it changes".
    STRONG_ASSENT = /\b(yes|yeah|yea|yep|yup|correct|confirm|confirmed|affirmative|absolutely|definitely|do\ it|go\ ahead|
                        go\ for\ it|approve|approved|merge|ship\ it|land\ it|send\ it|proceed|lgtm)\b/x
    REFUSAL = /\b(no|nope|nah|naw|not|never|none|stop|wait|cancel|cannot|cant|hold|hang\ on|abort|skip|dont|pause|
                  nevermind|forget|scratch|leave|unable|[a-z]+n't)\b/x
    # Not refusals, whatever word they start with.
    NO_OBJECTION = /\bno (problem|worries)\b/
    # Conditions and corrections.
    TAKES_BACK = /\b(but|first|until|unless|after|before|once|when|later|instead|if|wrong|other\ one|another\ one|another\ pr|
                     different|tomorrow|tonight|laptop|computer|revert|undo|rather|except|take\ (it|that)\ back|
                     chang(e|ed)\ my\ mind|i\ meant?)\b/x
    # What people say next once they have answered. Nothing about the merge.
    MOVING_ON = /\b((and|so|okay|ok|now|then|let's)[\s,]+)*
                 (what('s|s|\ is)\ (up\ )?next|what\ else(\ (is\ there|do\ you\ have|have\ you\ got|do\ we\ have|do\ i\ have|needs\ me))?|
                 next(\ (one|pr|up|item|thing))?|keep\ going|hang\ up)
                 [\s?.!,]*\z/x
    # "Move on" alone can mean "leave it", so only after being told to merge.
    MERGE_AND_MOVE_ON = /\b(merge\ (?:it|this|that)(?:\ one)?|do\ it),?\ (and|then|and\ then)?\ ?(let's\ )?move\ on\b.*\z/
    # Merging something into the PR, which is the opposite of merging it.
    INTO_THE_PR = /\bmerge\ (in\ )?(the\ )?(main|master|base)\b|\bmerge\b.*\binto\ (it|this|that|the\ (pr|branch)|the\ pull)\b/
    # The person asking, whether or not the transcript kept the "?".
    QUESTION = /\b(is|are|was|can|could|does|did|should|will|would|has|have)\ (it|this|that|we|you|i|the|they)\b|
                \bdo\ (we|you|i|they)\b|\b(what|why|how|where|who|which)\b/x
    # Longer than any answer to a yes or no question.
    ANSWER_LIMIT = 200
    ALL_OF_IT = /\b(100|a hundred|one hundred|hundred) ?(%|percent\b)/
    # Sounds a transcript writes down. Any other bracket is words.
    NOISE = /\[(tongue click|inhale|exhale|breath\w*|cough\w*|hum\w*|laugh\w*|sigh\w*|noise|music|silence|sniff\w*|beep\w*)\]?/
    # A transcript's own typography. Any other character beyond ASCII is
    # something said that this does not read.
    THUMBS_UP = /\u{1F44D}[\u{1F3FB}-\u{1F3FF}]?/
    UNREAD = /[^\u0000-\u007F‘’ʼ“”–—… �]/
    NEUTRAL = %w[uh uhh um umm er erm hm hmm mm mhm oh ah so well and then now please great perfect cool nice awesome good
                 alright all right thanks thank you very much got it zimmer bye goodbye].to_set.freeze
    # Words that go with an assent without changing what it assents to.
    FILLER = (NEUTRAL + %w[
      just fine lets let's let us we i i'm im i'd it's its this that that's thats the a one pr prs p r by me my mine
      pull request number merge merging merged approve approved approval already said say saying told is am i've ive go ahead
      do for to with in into on be been happy totally exactly yo hey sounds looks like ready lgtm sir green ship land main want wanna
      can get works thing percent sure ok okay yes yeah yea yep yup yah correct confirm confirmed affirmative absolutely
      definitely of course send proceed
    ]).to_set.freeze

    # What makes their talk about merging at all.
    ABOUT_MERGING = /\b(merg\w*|ship(ping|s|ped)?|land(ing|s|ed)?|approv\w*|pull requests?|prs?|p r)\b/i
    OFFER = /\b(?:(?:do\ you\ |would\ you\ |you\ )?(?:(?:want|like)(?:\ me)?\ to|wanna)|should\ (?:i|we)|shall\ (?:i|we)|can\ i|could\ i|how\ about|what\ about)/x
    ACTION = /(?:(?:restart|re-?run|retry|archive|unarchive|stop|close|delete|remove|send\ (?!it)|reply|email|deploy|roll\ back|
                    revert|skip|wait|hold|check|look|open|update|schedule|remind|pause|resume|cancel|move\ on|show|read|create|
                    hear|know|explain|review|dig|walk|go\ (?:through|over)|find|fix|see(?!\ it\ merged)|
                    (?:tell|ask)(?!\ (?:\w+\ ){1,3}to\ merge))|
                  (?:start|run)(?!(?:ing)?\ (?:the\ |that\ )?merg))(?:ing)?\b/x
    # An offer to do another thing, whatever that thing would let them merge.
    OTHER_OFFER = /#{OFFER}(?:\ (?:just|also|quickly|first|go\ ahead\ and))*\ #{ACTION}|
                   \b(?:want|like)\ (?:some\ |any\ |the\ )?(?:more|details?|context|summary|background)\b|
                   \bwant\ (?:it|that|session\ \w+)\ (?:restarted|archived|closed|deleted|stopped|reverted|rerun)\b/x
    # An order the assistant proposes without asking ("Restart session seven too.").
    OTHER_ORDER = /\A(?:(?:also|and|or|then|so|okay|ok)[\ ,]+)*(restart|rerun|re-run|retry|archive|unarchive|close|delete|remove|
                   send|reply|email|deploy|revert|cancel|pause|resume)\b/x
    # The assistant saying it will not merge, rather than that it is waiting for a
    # yes.
    DECLINES = /\b(won't|wont|will not|not going to|not gonna) (merge|ship|land)\b(?!.*\b(without|until|unless)\b)|\b(not merging|holding off)\b/
    # Asking to merge, as something to do: "want me to go ahead and merge", "so,
    # merge zimmer …", "say yes to merge it". Not "it's ready to merge", "I
    # won't merge", "how we merge".
    MERGE = /(?:merge\b(?!\ (?:gate|queue|of\b|conflict|check|status|commit|button|base|train|is\b|are\b|was\b))|(?:ship|land)\ (?:it|this|that|the|pr|pull)\b)/x
    LEAD = /(?:(?:so|okay|ok|now|well|alright|and|to|just\ to\ confirm|to\ confirm|sorry)[\ ,]+)*/x
    ASK = /#{OFFER}(?:\ \w+){0,3}\ #{MERGE}|(?:\A|[,:]\ )#{LEAD}(?:go\ ahead\ and\ )?#{MERGE}|\bsay\ yes\ (?:to|and\ i'll)\ #{MERGE}/x
    # Asking to merge at another time, or after something else: not this one, now.
    # "Once you say yes" is this one, now.
    DEFERS = /(?:#{MERGE}(?:\ (?:it|this|that|one|pr|pull\ request|\d+))*\ (?:tomorrow|tonight|later|(?:after|once|when|until|if)\b(?!\ you\b))|
              \A(?:after|once|when|if)\b(?!\ you\ (?:say|confirm|approve|want))(?=.*\bmerge\b)|\band\ then\ merge\b).*\?/x
    # "Want to merge it?", and nothing else in the sentence.
    BARE_ASK = /(?:\A|,\ )(?:(?:so|okay|ok|now|well|alright)[\ ,]+)*(?:#{OFFER}\ )?(?:just\ |go\ ahead\ and\ )?
                (?:merge|ship|land)\ (?:it|this|that)(?:\ (?:one|pr|pull\ request))?(?:\ now|\ then)?\?\z/x

    ONES = %w[zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen
              seventeen eighteen nineteen].freeze
    TENS = %w[_ _ twenty thirty forty fifty sixty seventy eighty ninety].freeze

    Reading = Data.define(:kind, :strong) do
      def yes? = kind == :yes
      def no? = kind == :no
      def takes_back? = kind == :takes_back
      def neutral? = kind == :neutral
      def unclear? = kind == :unclear
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

      return Reading.new(kind: :unclear, strong: false) if line.length > ANSWER_LIMIT || text.to_s.gsub(THUMBS_UP, "").match?(UNREAD)

      said = line.sub(MOVING_ON, " ").sub(MERGE_AND_MOVE_ON, '\1 ')
      return Reading.new(kind: :unclear, strong: false) if said.include?("?") || said.match?(QUESTION) || said.match?(INTO_THE_PR)

      rest = phrases(said).flat_map { |phrase| without_number(phrase) }
      if said.match?(ASSENT)
        goes_with_it = rest.all? { |word| FILLER.include?(word) || @name_words.include?(word) }
        return Reading.new(kind: goes_with_it ? :yes : :unclear, strong: said.match?(STRONG_ASSENT))
      end
      Reading.new(kind: rest.all? { |word| NEUTRAL.include?(word) } ? :neutral : :unclear, strong: false)
    end

    # Whether an assistant line gives a yes after it something else to be about.
    #
    # @param clear [Boolean] whether that yes needs nothing from the assistant's
    #   line, so a line declining the merge is not a reason to doubt it
    # @param merging [Boolean] whether that yes itself says to merge, so an offer
    #   to do another thing is not what it answers
    def changes_subject?(text, clear: false, merging: false)
      sentences(text).any? do |sentence|
        next true if sentence.match?(DEFERS) || other_pr?(sentence)
        next true if sentence.match?(DECLINES) && !clear

        !merging && (sentence.match?(OTHER_OFFER) || other_order?(sentence))
      end
    end

    # Whether an assistant line asks to merge.
    def asks?(text) = sentences(text).any? { |sentence| sentence.match?(ASK) }

    # Whether the last thing an assistant asked is, in so many words, "merge
    # it?". Read only to spare a question (AuthorizeMerge#already_said_yes), so
    # it is strict.
    def self.asks_only_to_merge?(text)
      question = text.to_s.downcase.squish.split(/(?<=[.?!;])\s+/).reverse.find { |sentence| sentence.include?("?") }
      question.to_s.match?(BARE_ASK) && !question.match?(TAKES_BACK)
    end

    # Whether the person told it to merge, rather than answering.
    def self.says_merge?(text) = text.to_s.match?(/\b(merge|ship it|land it)\b/i)

    def self.about_merging?(text) = text.to_s.match?(ABOUT_MERGING)

    private

    def plain(text)
      text.to_s.tr("‘’ʼ", "'").downcase.gsub(NOISE, " ").gsub(ALL_OF_IT, " ").gsub(NO_OBJECTION, " ")
          .gsub(THUMBS_UP, " yes ")
          .gsub(/[^a-z0-9'?,.]+/, " ").squish
    end

    def words(text) = plain(text).gsub(/(\d),(\d)/, '\1\2').gsub(/[^a-z0-9']+/, " ").split

    # The line's runs of words between its commas and full stops, so "that one,
    # 1490" is not one number.
    def phrases(text) = plain(text).gsub(/(\d),(\d)/, '\1\2').split(/[,.?]+/).map { |phrase| words(phrase) }

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

    # A sentence that names a pull request by number as the thing to merge, and it
    # is not this PR's nor the start of it where the line was cut. Only the
    # verb's own object: "it follows up pull request 12, want to merge it?" and
    # "merge the one that fixes issue 12" are this PR's question.
    def other_pr?(sentence)
      named = phrases(sentence).flat_map do |tokens|
        tokens.each_index.filter_map do |i|
          next unless number_word?(tokens[i]) && (i.zero? || !number_word?(tokens[i - 1]))

          verb = tokens.take(i).rindex { |word| word.match?(/\A(merg(e|ing)|ship(ping)?|land(ing)?|approv(e|ing))\z/) }
          next unless verb && tokens[(verb + 1)...i].all? { |word| @name_words.include?(word) || %w[the pull request requests pr prs p r number].include?(word) }

          run = tokens.drop(i).take_while { |word| number_word?(word) }
          run if run.size > 1 || run.first.match?(/\A\d{2,}\z/)
        end
      end
      named.any? && named.none? { |run| ours?(run) }
    end

    # A number in the person's line that is not this PR's. One number word on
    # its own ("that one", "two seconds") names nothing.
    def other_number?(line)
      phrases(line).any? do |phrase|
        number_runs(phrase).any? { |run| !@forms.include?(run.join(" ")) && (run.size > 1 || run.first.match?(/\A\d{2,}\z/)) }
      end
    end

    def ours?(run)
      joined = run.join(" ")
      @forms.any? { |form| form == joined || form.start_with?("#{joined} ") } ||
        (run.all? { |word| word.match?(/\A\d+\z/) } && @number.start_with?(run.join))
    end

    # The words with this PR's number taken out, however it was said. A whole run
    # of number words at a time, so "fourteen ninety one" is not 1490.
    def without_number(list) = runs(list).reject { |run| @forms.include?(run.join(" ")) }.flatten

    def number_runs(list) = runs(list).select { |run| number_word?(run.first) }

    def runs(list)
      list.reject.with_index { |word, i| word == "and" && i.positive? && %w[hundred thousand].include?(list[i - 1]) }
          .chunk_while { |one, two| number_word?(one) == number_word?(two) }.to_a
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
      if digits.length == 4 && digits[1] != "0" && !digits.end_with?("00")
        forms << "#{cardinal(digits[0, 2].to_i)} hundred #{cardinal(digits[2, 2].to_i)}"
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
