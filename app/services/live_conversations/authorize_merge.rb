# frozen_string_literal: true

module LiveConversations
  # The Merge button, by voice: the Live Mode assistant's `authorize_merge`
  # function, which ends in the same Sessions::AuthorizeMerge the dashboard's and
  # the iOS app's Merge buttons call.
  #
  # == Why a spoken Merge needs one confirmation
  #
  # A tap carries its referent: the button is drawn next to one PR, by Zimmer,
  # and the click lands on that row. "Merge it" carries none. The PR it means
  # lives in the conversation, and the only thing that has named it is the live
  # model. So this is two calls, Zimmer names the PR, and the person answers
  # one short question about it:
  #
  # 1. **Prepare** — `authorize_merge(session_id)`. Zimmer reads the session's PR
  #    off its own record (Sessions::PrSummary, the button's source), refuses
  #    anything the button would refuse, and composes the confirmation: the
  #    repository, the number, a few words of the session's title, and "the
  #    merge gate held it for you" if it did. The model asks it once, in its own
  #    words if it likes, and asks for a yes.
  # 2. **Confirm** — `authorize_merge(session_id, confirm: true)`. Zimmer checks
  #    the conversation itself, not the model's account of it:
  #    * the newest prepare in this conversation is for this session, under
  #      CONFIRM_WINDOW old, and its PR is still the session's PR. Prepares
  #      repeated back to back for the same PR, each under CONFIRM_WINDOW old,
  #      count from the earliest, so asking again keeps a yes already given;
  #      after anything but a yes, the newer prepare starts over;
  #    * the person's newest words are fresh, one signed-in person's, and from a
  #      conversation nothing unvouched-for has written into
  #      (HumanMessageCapture.live_mode_words, the `live_mode` rule);
  #    * after the prepare, the assistant asked to merge this PR: a sentence
  #      that says "merge" as a request (not "merged", not "the merge of"),
  #      negates nothing outside a quoted title, and says the number (in digits
  #      or spoken, "thirty six hundred") right after "pull request", "PR" or
  #      the repository, in a line that asks nothing else. That is the transcript of what
  #      the person heard, or the text they read;
  #    * nothing the person said between the prepare and that first asking
  #      line was a refusal ("no", "wait", "hold on"…);
  #    * everything the person said after the first asking line is a plain
  #      yes: at most six words, all from a closed list ("yes", "yeah", "do
  #      it", "merge it", "okay", "please"…) with at least one real yes among
  #      them, and no question. Crude on purpose, and it fails closed: an answer
  #      it cannot read as a yes merges nothing;
  #    * the assistant said nothing in between but filler, a line made only of
  #      words like "okay", "sure", "here's the full read-back", or the same
  #      question again. Anything else ends the confirmation.
  #
  # The person's words are counted from the asking line, not from the line just
  # before them, because a voice call records lines in the order transcription
  # finished, not the order they were spoken: a "yes" said as the model starts
  # repeating itself lands after "Okay." or after half a sentence that names
  # nothing.
  #
  # Only then does it send the merge authorization to the session holding the
  # PR, and record the person's words there as a `live_mode` HumanMessage
  # (entry point `live_mode.authorize_merge`) carrying the PR Zimmer named, the
  # confirmation it composed, and the line the assistant actually said. That is
  # the `here` record a tap leaves, plus the evidence a tap does not need. The
  # authorization the merging session reads carries only Zimmer's words and the
  # person's answer, never the model's.
  #
  # The function exists only on ToolBridge, which runs in process for a Live
  # conversation. Nothing on POST /mcp reaches it, and an agent that types into
  # a conversation (`action_live_conversation`) taints it, so its words can
  # never be the yes.
  class AuthorizeMerge
    NAME = "authorize_merge"

    # How long a confirmation stays answerable.
    CONFIRM_WINDOW = 3.minutes

    # A plain yes is made of these phrases and nothing else, at least one of
    # them a YES, and is short. A closed list on purpose: "please say that
    # again", "okay, one sec" and "merge 3601" are not on it, so they merge
    # nothing. Spoken noise ("uh", "um") is dropped first.
    YES = [ "yes", "yeah", "yea", "yep", "yup", "correct", "confirmed", "confirm", "affirmative", "sure", "absolutely",
            "definitely", "ok", "okay", "do it", "go ahead", "go for it", "ship it", "merge it", "merge that",
            "please do", "yes please", "that's right", "thats right" ].freeze
    YES_EXTRAS = [ "please", "great", "perfect", "cool", "alright", "all right", "thanks", "thank you", "uh", "um", "umm",
                   "er", "erm", "hmm", "mm", "oh", "so" ].freeze
    PLAIN_YES_MAX_WORDS = 6
    # A word that turns an answer before the question into a refusal, and an
    # assistant line naming the PR into something other than asking to merge it.
    REFUSAL = /\b(no|nope|nah|not|don't|do not|stop|wait|cancel|hold|abort|never ?mind)\b/i
    NEGATION = /\b(not|never|no longer|already|won't|wont|don't|dont|didn't|isn't|wasn't|can't|cannot|couldn't|shouldn't)\b|n't\b/i
    # How a model's question starts when the transcript drops the "?".
    QUESTION_OPENER = /(?:\A|[.!?,;]\s*)(?:(?:also|or|and|so|then|but),?\s+)?(should|shall|want|wanna|do you|can i|could i|would you|did you|are you|is it|any|anything|how about|what about)\b/i
    # An assistant line made only of these words does not move the
    # conversation on: "Okay.", "Here's the full read-back.", "Sure, merging it."
    FILLER_WORDS = %w[okay ok sure alright all right got it one sec second moment just a here's heres here is the full
                      read back readback merging now on so um uh great thanks thank you yes yeah yep let me say that
                      again].to_set.freeze
    # Words before "merge" that make it a noun ("the merge of …"), not a request.
    MERGE_NOUN_BEFORE = %w[the a this that its his her their gate's].freeze

    # Words of the session's title said beside the PR: enough to recognise it.
    TITLE_WORDS = 8
    # Kept for the model to say only if the person asks why it was held.
    GATE_REASON_LIMIT = 240

    ONES = %w[zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen
              seventeen eighteen nineteen].freeze
    TENS = %w[_ _ twenty thirty forty fifty sixty seventy eighty ninety].freeze

    # Said to the person; and what ToolBridge raises it as.
    Refused = Class.new(StandardError)

    DESCRIPTION = "Merge a pull request for the person, the way the Merge button in Zimmer does. Use this, not a " \
                  "follow-up or a new session, whenever the person tells you to merge, ship or approve a PR. Two calls. " \
                  "First call it with the session_id of the session that opened the PR (find it with the zimmer tool's " \
                  "quick_search_sessions, querying the PR URL with show_archived false): Zimmer answers with one short " \
                  "confirmation. Ask it once, in your own words if you like, but say \"merge\", the repository and the " \
                  "number, and ask for a yes. As soon as they say yes (\"yes\", \"yeah\", \"do it\", \"merge it\"), call it " \
                  "again with the same session_id and confirm true, without asking again. If they say no or anything " \
                  "else, do not call it again. Never call it with confirm true before you have asked."

    def self.function
      ToolBridge::Function.new(
        name: NAME,
        description: DESCRIPTION,
        parameters: {
          type: "object",
          properties: {
            session_id: { type: "integer", description: "The session that opened the PR and holds it." },
            confirm: { type: "boolean", description: "True only on the second call, after the person said yes to the confirmation." }
          },
          required: %w[session_id]
        }
      )
    end

    def initialize(conversation, now: Time.current)
      @conversation = conversation
      @now = now
    end

    # @param args [Hash] the model's arguments
    # @return [String] what the model is told
    # @raise [Refused] with what the model should tell the person
    def call(args)
      session = find_session!(args["session_id"])
      summary = Sessions::PrSummary.for(session)
      if (reason = summary.merge_blocked_reason)
        raise Refused, "Cannot merge from session #{session.id}: #{reason} Tell the person."
      end

      truthy?(args["confirm"]) ? confirm(session, summary.url) : prepare(session, summary.url)
    end

    # The question the person is asked to say yes to. Composed here, from
    # Zimmer's own records, so the model has nothing to choose. Short, because
    # it is said aloud once.
    def self.read_back(session, pr_url)
      repo = AutomatedPrompts.repo_slug_from_pr_url(pr_url).to_s.split("/").last
      title = spoken_title(session)
      sentence = +"Merge #{repo} pull request #{pr_number(pr_url)}"
      sentence << ", \"#{title}\"" if title
      sentence << "?"
      sentence << " The merge gate held it for you." if latest_gate_hold_reason(pr_url)
      sentence
    end

    # A few words of the session's title. The title is the session's text, so
    # it loses anything that could read as another PR's number before it is
    # spoken beside this one's: a "(repo#123)" reference goes whole, and so does
    # any other bare number.
    def self.spoken_title(session)
      title = session.title.to_s
                     .gsub(%r{\(\s*[\w./-]*#\d+\s*\)}, " ")
                     .gsub(%r{[\w./-]*#\d+}, " ")
                     .gsub(/\b\d+\b/, " ")
                     .delete("#")
                     .gsub(/\(\s*\)/, " ")
                     .squish
      words = title.split
      words.size > TITLE_WORDS ? "#{words.first(TITLE_WORDS).join(' ')}…" : title.presence
    end

    def self.pr_number(pr_url) = pr_url.to_s[%r{/pull/(\d+)}, 1]

    # Whether a line asks to merge this PR: it says "merge", says nothing
    # negating it ("I won't merge…", "…is not merged"), and says the number (in
    # digits or spoken) right after "pull request", "PR" or the repository's
    # name. Case does not matter, so a transcript's "tadasant internal" matches
    # "tadasant-internal" and "thirty six hundred" matches 3600.
    def self.asks_to_merge?(text, pr_url)
      repo = AutomatedPrompts.repo_slug_from_pr_url(pr_url).to_s.split("/").last
      number = pr_number(pr_url)
      return false if repo.blank? || number.blank?

      anchors = %w[request pr r pull number] + normalize(repo).split.last(1)
      sentences = text.to_s.gsub(/(\d),(\d)/, '\1\2').split(/(?<=[.?!;])\s+/)
      asking, others = sentences.partition { |sentence| merge_verb?(sentence) && number_clauses(sentence, number, anchors: anchors).any? }
      return false if asking.empty?
      # A quoted title is Zimmer's text, not the model's, so it can say "Don't".
      return false if asking.any? { |sentence| sentence.gsub(/["\u201C][^"\u201D]*["\u201D]/, " ").tr("\u2018\u2019\u02BC", "'").match?(NEGATION) }

      # A line that also asks something else is not this question.
      others.none? { |sentence| sentence.include?("?") || sentence.match?(QUESTION_OPENER) }
    end

    # Whether the sentence says "merge" as a request: "merge pull request 12",
    # "shall I merge PR 12", not "merged", "merging" or "the merge of PR 12".
    def self.merge_verb?(sentence)
      words = normalize(sentence).split
      words.each_index.any? do |i|
        words[i] == "merge" && words[i + 1] != "of" && (i.zero? || !MERGE_NOUN_BEFORE.include?(words[i - 1]))
      end
    end

    # Whether the text says the number, in digits ("3600", "3,600") or as
    # speech is transcribed ("thirty six hundred", "three thousand six hundred
    # and five", "three six zero zero", "fourteen oh five"). The match is the
    # whole number said, within one clause (punctuation ends a number, so a
    # quoted title starting "Two…" does not run on from it), so "thirty six" in
    # "thirty six hundred" is not 36.
    def self.says_number?(text, number) = number_clauses(text, number).any?

    # The clauses of the text that say the number. With `anchors`, one of those
    # words has to come at most four words before it.
    def self.number_clauses(text, number, anchors: nil)
      forms = spoken_forms(number).map(&:split)
      clauses = text.to_s.gsub(/(\d),(\d)/, '\1\2').split(/[,.;:!?"\u201C\u201D()\[\]]+/)
      clauses.select do |clause|
        words = normalize(clause).split
        words = words.reject.with_index { |w, i| w == "and" && %w[hundred thousand].include?(words[i - 1]) && i.positive? }
        forms.any? do |form|
          (0..(words.size - form.size)).any? do |i|
            before = i.zero? ? nil : words[i - 1]
            next false unless words[i, form.size] == form && !number_word?(before) && !number_word?(words[i + form.size])

            anchors.nil? || words[[ i - 4, 0 ].max...i].intersect?(anchors)
          end
        end
      end
    end

    def self.number_word?(word)
      return false if word.nil?

      word.match?(/\A\d+\z/) || ONES.include?(word) || TENS.include?(word) || %w[oh hundred thousand].include?(word)
    end

    # Every way a transcript is likely to write the number, as normalized words.
    def self.spoken_forms(number)
      digits = number.to_s
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
    def self.chunkings(digits)
      return [ [] ] if digits.empty?

      [ 1, 2 ].flat_map do |size|
        next [] if digits.length < size

        chunkings(digits[size..]).map { |rest| [ digits[0, size], *rest ] }
      end
    end

    # Spoken only: digits count as the whole number in one token, so "12 and
    # 34" is not 1234.
    def self.chunk_forms(chunk)
      value = chunk.to_i
      if chunk.length == 1
        [ ONES[value], (value.zero? ? "oh" : nil) ].compact
      elsif chunk.start_with?("0")
        [ "oh #{ONES[value]}", "zero #{ONES[value]}" ]
      else
        [ cardinal(value) ]
      end
    end

    def self.cardinal(value)
      return ONES[value] if value < 20
      return [ TENS[value / 10], (ONES[value % 10] unless (value % 10).zero?) ].compact.join(" ") if value < 100
      if value < 1_000
        return [ ONES[value / 100], "hundred", (cardinal(value % 100) unless (value % 100).zero?) ].compact.join(" ")
      end

      [ cardinal(value / 1_000), "thousand", (cardinal(value % 1_000) unless (value % 1_000).zero?) ].compact.join(" ")
    end

    def self.plain_yes?(answer)
      text = answer.to_s.tr("\u2018\u2019\u02BC", "'")
      return false if text.include?("?")

      words = text.downcase.gsub(/[^a-z' ]+/, " ").split
      return false if words.empty? || words.size > PLAIN_YES_MAX_WORDS

      phrases = (YES + YES_EXTRAS).map(&:split).sort_by { |phrase| -phrase.size }
      said_yes = false
      until words.empty?
        phrase = phrases.find { |candidate| words.first(candidate.size) == candidate }
        return false unless phrase

        said_yes ||= YES.include?(phrase.join(" "))
        words = words.drop(phrase.size)
      end
      said_yes
    end

    def self.normalize(text) = text.to_s.downcase.gsub(/[^a-z0-9]+/, " ").squish

    def self.latest_gate_hold_reason(pr_url)
      decision = GateDecision.for_gate(GateDecision::PR_MERGE).for_artifact(pr_url).recent_first.first
      return nil unless decision&.decision == "hold"

      reason = decision.payload.is_a?(Hash) ? decision.payload["reason"].to_s.squish : ""
      reason.presence&.truncate(GATE_REASON_LIMIT, separator: " ") || "no reason given"
    end

    private

    def prepare(session, pr_url)
      if Sessions::AuthorizeMerge.authorized_at(session, pr_url)
        return "Already authorized: session #{session.id} has been told to merge #{pr_url}. Tell the person."
      end

      hold = self.class.latest_gate_hold_reason(pr_url)
      "READ-BACK: #{self.class.read_back(session, pr_url)}\n\n" \
        "PR: #{pr_url}\n" \
        "Ask the person this once, now: your own words are fine, but say \"merge\", the repository and the number, and " \
        "ask for a yes. Do not repeat it unless they ask which pull request. As soon as they say yes, call #{NAME} with " \
        "session_id #{session.id} and confirm true. If they say no, or anything else, merge nothing." \
        "#{"\nWhy the gate held it, only if they ask: #{hold}" if hold}"
    end

    def confirm(session, pr_url)
      prepared = confirm_window_start(session, pr_url)
      latest = prepared.last
      if latest.nil?
        raise Refused, "Not merging: Zimmer has not asked the person about this pull request yet. Call #{NAME} with " \
                       "session_id #{session.id} and no confirm first, and ask what it returns."
      end
      if latest.created_at < @now - CONFIRM_WINDOW
        raise Refused, "Not merging: the question was more than #{CONFIRM_WINDOW.inspect} ago. Call #{NAME} again " \
                       "without confirm, ask it again, and wait for a fresh yes."
      end
      start = prepared.first

      words = HumanMessageCapture.live_mode_words(@conversation, now: @now, after_turn_id: start.id)
      raise Refused, "Not merging, because #{words.declined}. Tell the person." if words.declined

      number = self.class.pr_number(pr_url)
      lines = @conversation.turns.where(role: %w[user assistant]).where("id > ?", start.id).reorder(:id).to_a
      last_answer = lines.reverse.find(&:user?)
      asking = lines.select { |t| !t.user? && t.id < last_answer.id && self.class.asks_to_merge?(t.content, pr_url) }
      unless (first_asked = asking.first)
        raise Refused, "Not merging: since Zimmer gave you the question, nothing you said asked the person to merge pull " \
                       "request #{number} by number. Ask once: say \"merge\", the repository and the number, then call " \
                       "with confirm true after their yes."
      end

      # What they said before the question is the request, or noise; it only
      # matters when it is a refusal. Everything after it has to be a yes.
      if (refusal = lines.find { |t| t.user? && t.id < first_asked.id && t.content.to_s.match?(REFUSAL) })
        raise Refused, "Not merging: the person said \"#{refusal.content.to_s.squish.truncate(120)}\" before you asked. " \
                       "Leave it unless they ask to merge again."
      end
      after = lines.select { |t| t.id > first_asked.id && t.id <= last_answer.id }
      if (question = after.find { |t| !t.user? && something_else?(t.content, pr_url) })
        raise Refused, "Not merging: after you asked about pull request #{number} you asked something else " \
                       "(\"#{question.content.to_s.squish.truncate(80)}\"), so their yes answers that. If they still want " \
                       "it merged, ask once more about pull request #{number}."
      end

      answers = after.select(&:user?)
      asked = asking.last
      speaker = words.turns.last.author
      # Every answer is after the prepare run's start, so under CONFIRM_WINDOW old.
      if answers.any? { |t| t.author != speaker }
        raise Refused, "Not merging: the person's latest words are not one signed-in person's alone. Tell the person."
      end
      if (other = answers.find { |t| !self.class.plain_yes?(t.content) })
        raise Refused, "Not merging: \"#{other.content.to_s.squish.truncate(120)}\" is not a plain yes. If it was a no, " \
                       "leave it. If you are not sure, call #{NAME} again without confirm and ask once more."
      end

      answer = answers.map(&:content).join(" ").squish
      surface = HumanMessage::LIVE_MODE_SURFACES[answers.last.author_provenance.to_h["surface"]]
      where = [ "Zimmer Live Mode", surface ].compact.join(" on ")
      read_back = latest.tool_output.to_s[/\AREAD-BACK: (.*)$/, 1].to_s
      # Only Zimmer's sentence and the person's answer go into the authorization.
      # What the model said stays in the HumanMessage, labelled as the model's.
      result = Sessions::AuthorizeMerge.call(
        session: session, surface: where,
        act: "said yes in #{where} when Zimmer asked them to confirm this PR by repository and number " \
             "(they answered: \"#{answer.truncate(60)}\")"
      )
      raise Refused, "#{result.message} Tell the person." unless result.ok?

      if result.sent?
        HumanMessageCapture.record_live_mode_merge_approval(
          session: session, conversation: @conversation,
          words: words.with(turns: answers, replying_to: asked),
          pr_url: pr_url, read_back: read_back, relayed: "Merge #{pr_url}", occurred_at: @now
        )
      end
      "#{result.message} Tell the person, in one short sentence."
    end

    # An assistant line after the first asking line that moves the
    # conversation on: anything but asking about this PR again or short filler
    # ("Okay.", "Here's the full read-back."). A question, with or without its
    # "?", or a line about merging some other pull request, always does.
    def something_else?(text, pr_url)
      return false if self.class.asks_to_merge?(text, pr_url)

      text = text.to_s
      text.include?("?") || text.match?(QUESTION_OPENER) || !text.downcase.gsub(/[^a-z' ]+/, " ").split.all? { |w| FILLER_WORDS.include?(w) }
    end

    def find_session!(value)
      id = Integer(value.to_s, exception: false)
      session = id && Session.find_by(id: id)
      raise Refused, "No session #{value.inspect}. Find the session that opened the PR with quick_search_sessions." if session.nil?

      session
    end

    # The newest run of successful prepares in this conversation for this
    # session and PR, oldest first, or [] when the newest prepare is for
    # anything else: a yes answers the last PR the person was asked about, and
    # no other. A prepare the model repeats for the same PR does not move the
    # start, so a yes to the first asking still counts; one older than
    # CONFIRM_WINDOW is not part of the run.
    def confirm_window_start(session, pr_url)
      prepares = @conversation.turns.where(role: "tool", tool_name: NAME, tool_error: false).reorder(id: :desc).limit(20)
                              .select { |turn| prepare?(turn) }
      run = []
      prepares.each do |turn|
        break unless prepared_session_id(turn) == session.id && turn.tool_output.to_s.include?("PR: #{pr_url}\n")
        if run.any?
          break if turn.created_at < @now - CONFIRM_WINDOW
          # The model asked again because the person did not just say yes: the
          # new question starts over, and what they said before it is behind it.
          said = @conversation.turns.where(role: "user").where(id: (turn.id + 1)...run.first.id).pluck(:content)
          break unless said.all? { |content| self.class.plain_yes?(content) }
        end

        run.unshift(turn)
      end
      run
    end

    def prepare?(turn) = !truthy?(turn.tool_arguments.to_h["confirm"]) && turn.tool_output.to_s.start_with?("READ-BACK: ")

    def prepared_session_id(turn) = Integer(turn.tool_arguments.to_h["session_id"].to_s, exception: false)

    def truthy?(value) = value == true || value.to_s.strip.casecmp?("true")
  end
end
