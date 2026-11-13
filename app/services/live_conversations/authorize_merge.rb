# frozen_string_literal: true

module LiveConversations
  # The Merge button, by voice: the Live Mode assistant's `authorize_merge`
  # function, which ends in the same Sessions::AuthorizeMerge the dashboard's and
  # the iOS app's Merge buttons call.
  #
  # == Why a button needs a read-back when it is spoken
  #
  # A tap carries its referent: the button is drawn next to one PR, by Zimmer,
  # and the click lands on that row. "Merge it" carries none. The PR it means
  # lives in the conversation, and the only thing that has named it is the live
  # model. So this is two calls, and Zimmer, not the model, decides what is
  # being agreed to:
  #
  # 1. **Prepare** — `authorize_merge(session_id)`. Zimmer reads the session's PR
  #    off its own record (Sessions::PrSummary, the button's source), refuses
  #    anything the button would refuse, and composes the read-back: the
  #    repository, the number, the session's title, and the merge gate's hold
  #    reason if it held it. The model is told to say it and ask for a yes.
  # 2. **Confirm** — `authorize_merge(session_id, confirm: true)`. Zimmer checks
  #    the conversation itself, not the model's account of it:
  #    * the newest prepare in this conversation is for this session, under
  #      CONFIRM_WINDOW old, and its PR is still the session's PR;
  #    * the person's newest words are fresh, one signed-in person's, and from a
  #      conversation nothing unvouched-for has written into
  #      (HumanMessageCapture.live_mode_words, the `live_mode` rule);
  #    * the assistant line just before those words, with nothing they said in
  #      between, came after the prepare and names the PR by repository and
  #      number. That is the transcript of what the person heard, or the text
  #      they read, so their words answer the read-back and not some later
  #      question;
  #    * those words are a plain yes: short, starting with "yes" or the like,
  #      with no question and nothing qualifying it ("not", "wait", "but",
  #      "after", "first"…). This test is deliberately crude and fails closed:
  #      an answer it cannot read as a yes merges nothing, and the model asks
  #      again.
  #
  # Only then does it send the merge authorization to the session holding the
  # PR, and record the person's words there as a `live_mode` HumanMessage
  # (entry point `live_mode.authorize_merge`) carrying the PR Zimmer named, the
  # read-back it composed, and the line the assistant actually said. That is
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

    # How long a read-back stays answerable.
    CONFIRM_WINDOW = 3.minutes

    # A plain yes: it starts with one of these, is short, asks nothing, and
    # qualifies nothing. Crude on purpose, and closed: whatever it cannot read
    # as a yes merges nothing.
    AFFIRMATIVE_START = /\A(yes|yeah|yep|yup|correct|confirmed?|affirmative|sure|do it|go ahead|merge it|merge that|please do)\b/i
    NOT_PLAIN = /\?|\b(no|nope|nah|not|don't|do not|stop|wait|cancel|hold|abort|never ?mind|but|after|first|once|if|later|until|unless|before|instead|other|different)\b/i
    PLAIN_YES_MAX_WORDS = 6

    # Read aloud, so short.
    GATE_REASON_LIMIT = 240

    # Said to the person; and what ToolBridge raises it as.
    Refused = Class.new(StandardError)

    DESCRIPTION = "Merge a pull request for the person, the way the Merge button in Zimmer does. Use this, not a " \
                  "follow-up or a new session, whenever the person tells you to merge, ship or approve a PR. Two calls. " \
                  "First call it with the session_id of the session that opened the PR (find it with the zimmer tool's " \
                  "quick_search_sessions, querying the PR URL with show_archived false): Zimmer answers with a read-back. " \
                  "Say the read-back to the person word for word, including the repository and the number, and ask " \
                  "them to say yes. Only when they answer yes, call it again with the same session_id and confirm true. " \
                  "If they say anything else, do not call it again. Never call it with confirm true before they have " \
                  "heard the read-back and answered it."

    def self.function
      ToolBridge::Function.new(
        name: NAME,
        description: DESCRIPTION,
        parameters: {
          type: "object",
          properties: {
            session_id: { type: "integer", description: "The session that opened the PR and holds it." },
            confirm: { type: "boolean", description: "True only on the second call, after the person said yes to the read-back." }
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

    # The sentence the person is asked to say yes to. Composed here, from
    # Zimmer's own records, so the model has nothing to choose.
    def self.read_back(session, pr_url)
      repo = AutomatedPrompts.repo_slug_from_pr_url(pr_url)
      number = pr_number(pr_url)
      # The title is the session's text, so it loses anything that could read
      # as another PR's number before it is spoken beside this one's.
      title = session.title.to_s.gsub(/[#\d]+/, " ").squish.truncate(90).presence
      hold = latest_gate_hold_reason(pr_url)
      sentence = +"Merge #{repo} pull request #{number}"
      sentence << ", from the session \"#{title}\"" if title
      sentence << "?"
      sentence << " The merge gate held it: #{hold}" if hold
      sentence
    end

    def self.pr_number(pr_url) = pr_url.to_s[%r{/pull/(\d+)}, 1]

    # Whether a line names this PR the way the read-back does: the repository's
    # name and the number, as words. Punctuation and case do not matter, so a
    # transcript's "tadasant internal" matches "tadasant-internal".
    def self.names_pr?(text, pr_url)
      repo = AutomatedPrompts.repo_slug_from_pr_url(pr_url).to_s.split("/").last
      number = pr_number(pr_url)
      return false if repo.blank? || number.blank?

      words = " #{normalize(text)} "
      words.include?(" #{normalize(repo)} ") && words.include?(" #{number} ")
    end

    def self.plain_yes?(answer)
      text = answer.to_s.tr("\u2018\u2019\u02BC", "'").squish
      text.match?(AFFIRMATIVE_START) && !text.match?(NOT_PLAIN) && text.split.size <= PLAIN_YES_MAX_WORDS
    end

    def self.normalize(text) = text.to_s.downcase.gsub(/[^a-z0-9]+/, " ").squish

    def self.latest_gate_hold_reason(pr_url)
      decision = GateDecision.for_gate(GateDecision::PR_MERGE).for_artifact(pr_url).recent_first.first
      return nil unless decision&.decision == "hold"

      reason = decision.payload.is_a?(Hash) ? decision.payload["reason"].to_s.squish : ""
      reason.presence&.truncate(GATE_REASON_LIMIT, separator: " ")
    end

    private

    def prepare(session, pr_url)
      if Sessions::AuthorizeMerge.authorized_at(session, pr_url)
        return "Already authorized: session #{session.id} has been told to merge #{pr_url}. Tell the person."
      end

      "READ-BACK: #{self.class.read_back(session, pr_url)}\n\n" \
        "PR: #{pr_url}\n" \
        "Say the read-back to the person now, word for word, and ask them to say yes. Then call #{NAME} with " \
        "session_id #{session.id} and confirm true only if they say yes. If they say anything else, merge nothing."
    end

    def confirm(session, pr_url)
      prepared = latest_prepare
      if prepared.nil? || prepared_session_id(prepared) != session.id || !prepared.tool_output.to_s.include?("PR: #{pr_url}\n")
        raise Refused, "Not merging: Zimmer has not read this pull request back to the person yet. Call #{NAME} with " \
                       "session_id #{session.id} and no confirm first, and say what it returns."
      end
      if prepared.created_at < @now - CONFIRM_WINDOW
        raise Refused, "Not merging: the read-back was more than #{CONFIRM_WINDOW.inspect} ago. Call #{NAME} again " \
                       "without confirm, read it back again, and ask for a fresh yes."
      end

      words = HumanMessageCapture.live_mode_words(@conversation, now: @now, after_turn_id: prepared.id)
      raise Refused, "Not merging, because #{words.declined}. Tell the person." if words.declined

      # The person's answer has to answer the read-back itself: the assistant
      # line just before their words (nothing they said in between) is after
      # the prepare and names this PR by repository and number. A yes to any
      # later question, however the model came to ask it, is not a yes to this.
      said = words.replying_to
      unless said && said.id > prepared.id && self.class.names_pr?(said.content, pr_url)
        raise Refused, "Not merging: the person's last words do not answer the read-back. Say the read-back again word " \
                       "for word, with the repository and the number, and ask for a yes."
      end

      answer = words.turns.map(&:content).join(" ").squish
      unless self.class.plain_yes?(answer)
        raise Refused, "Not merging: \"#{answer.truncate(120)}\" is not a plain yes. Ask the person again if they meant " \
                       "to, or leave it."
      end

      surface = HumanMessage::LIVE_MODE_SURFACES[words.turns.last.author_provenance.to_h["surface"]]
      where = [ "Zimmer Live Mode", surface ].compact.join(" on ")
      read_back = prepared.tool_output.to_s[/\AREAD-BACK: (.*)$/, 1].to_s
      # Only Zimmer's sentence and the person's answer go into the authorization.
      # What the model said stays in the HumanMessage, labelled as the model's.
      result = Sessions::AuthorizeMerge.call(
        session: session, surface: where,
        act: "said yes in #{where} when Zimmer read this PR back to them by repository and number " \
             "(they answered: \"#{answer.truncate(60)}\")"
      )
      raise Refused, "#{result.message} Tell the person." unless result.ok?

      if result.sent?
        HumanMessageCapture.record_live_mode_merge_approval(
          session: session, conversation: @conversation, words: words, pr_url: pr_url,
          read_back: read_back, relayed: "Merge #{pr_url}", occurred_at: @now
        )
      end
      "#{result.message} Tell the person, in one short sentence."
    end

    def find_session!(value)
      id = Integer(value.to_s, exception: false)
      session = id && Session.find_by(id: id)
      raise Refused, "No session #{value.inspect}. Find the session that opened the PR with quick_search_sessions." if session.nil?

      session
    end

    # The newest successful prepare in this conversation, for any session: a
    # yes answers the last read-back the person heard, and no other.
    def latest_prepare
      @conversation.turns.where(role: "tool", tool_name: NAME, tool_error: false).reorder(id: :desc).limit(20)
                   .detect { |turn| !truthy?(turn.tool_arguments.to_h["confirm"]) && turn.tool_output.to_s.start_with?("READ-BACK: ") }
    end

    def prepared_session_id(turn) = Integer(turn.tool_arguments.to_h["session_id"].to_s, exception: false)

    def truthy?(value) = value == true || value.to_s.strip.casecmp?("true")
  end
end
