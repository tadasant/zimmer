# frozen_string_literal: true

module LiveConversations
  # The Merge button, by voice: the Live Mode assistant's `authorize_merge`
  # function, which ends in the same Sessions::AuthorizeMerge the iOS app's Merge
  # button calls.
  #
  # == One clear yes
  #
  # A tap carries its referent: the button is drawn next to one PR, by Zimmer,
  # and the click lands on that row. "Merge it" carries none, so Zimmer binds
  # the PR and the person says yes to it once:
  #
  # 1. **Name** — `authorize_merge(session_id)`. Zimmer reads the session's PR
  #    off its own record (Sessions::PrSummary, the button's source), refuses
  #    anything the button would refuse, and composes one short question.
  # 2. **Confirm** — `authorize_merge(session_id, confirm: true)`, once the
  #    person has answered. A yes already given merges on either call, so a
  #    clear one is never answered with another question.
  #
  # == What is checked, and what is not
  #
  # Checked, because Zimmer can: who spoke, when, to which PR, and what they
  # said (MergeAnswer).
  #
  # * the newest question in this conversation is for this session and PR, under
  #   QUESTION_WINDOW old. Questions repeated for the same PR count from the
  #   earliest, until something the person says refuses or takes it back;
  # * the conversation is one nothing unvouched-for has written into
  #   (HumanMessageCapture.live_mode_taint), and every line the person said since
  #   the question is one signed-in person's;
  # * one of those lines is a clear yes, under CONFIRM_WINDOW old, that no merge
  #   sent since has used up, and that did not answer something else the
  #   assistant had just offered. An "okay" counts only to a line that asks to
  #   merge;
  # * none of them is a refusal, and everything after the yes is another yes,
  #   filler or moving on;
  # * merging came up aloud around then, so a question that was never spoken
  #   cannot be answered by a yes to the weather.
  #
  # Not checked: how the assistant worded its question, whether its transcript
  # spells the number, whether its line was cut off, and what order its lines
  # were recorded in. On a GPT-Live call the model that speaks is not the model
  # that calls this function (Claude), its lines break wherever the person talks
  # over them, and each is posted on a request of its own, so a gate on those
  # lines refuses yeses nobody would mistake
  # (docs: sessions/hierarchy-and-human-messages, "Merging by voice").
  #
  # == A yes nobody has called a confirmation
  #
  # People answer "want to merge it?" before any of this is called, and a model
  # whose confirm did not land starts over. Either way the first call is not a
  # claim that the person said yes, so it merges only where the recorded line
  # they answered asks for the merge. Before any question, the last session
  # Zimmer showed the conversation (`get_session`) must also be the one holding
  # the PR, with the PR in what it showed, and the person's words the answer to a
  # bare "merge it?", or "merge it" itself (#already_said_yes). The binding is
  # Zimmer's record from before they spoke, like a question's. Anything short of
  # that gets the one question.
  #
  # Only then does it send the merge authorization to the session holding the
  # PR, and record the person's words there as a `live_mode` HumanMessage
  # (entry point `live_mode.authorize_merge`) carrying the PR Zimmer named, the
  # question it composed if it did, and the line the assistant actually said.
  # That is the `here` record a tap leaves, plus the evidence a tap does not
  # need. The authorization the merging session reads carries only Zimmer's
  # words and the person's answer, never the model's.
  #
  # == A PR another Zimmer holds
  #
  # A session here can drive a session on another Zimmer deployment
  # through a catalog MCP server, and the PR that needs the yes is then held
  # over there. Called with `pr_url` naming such a PR, the same two calls run
  # with the remote's account of it instead of a local session's record:
  #
  # * the session must be, or be in a spawn hierarchy with, a session carrying
  #   one of MERGE_ATTESTATION_REMOTE_SERVERS, and that remote must answer
  #   MergeAttestations::TARGET_TOOL saying one of its sessions holds the PR,
  #   that it is open and green, its head commit, and that it trusts this
  #   Zimmer's key. The read-back names the repository, the number, a few words
  #   of the remote session's title and the deployment holding it;
  # * on confirm, every conversation check above runs unchanged, the remote is
  #   asked again and its head must still be the commit the person was asked
  #   about, the yes is recorded as a `live_mode` HumanMessage on the driving
  #   session, and only then MergeAttestations::Issuer signs an approval for
  #   that PR at that commit, which Rails hands to the remote's
  #   MergeAttestations::SUBMIT_TOOL. The model never sees the token. A yes
  #   before the question is not enough here: the question is what pins the
  #   commit.
  #
  # The function exists only on ToolBridge, which runs in process for a Live
  # conversation. Nothing on POST /mcp reaches it, and an agent that types into
  # a conversation (`action_live_conversation`) taints it, so its words can
  # never be the yes.
  class AuthorizeMerge
    NAME = "authorize_merge"

    # How long a yes stays good.
    CONFIRM_WINDOW = 3.minutes
    # How long a question stays answerable: people talk a decision over.
    QUESTION_WINDOW = 10.minutes
    # How recent a yes from before any question has to be.
    EARLY_YES_WINDOW = 2.minutes
    # How far before the question talk of merging still counts as being about it.
    TALK_BEFORE = 2.minutes
    # How long a confirm waits for an answer still on its way: a voice call posts
    # the line and the delegation that acts on it side by side.
    ANSWER_GRACE = 4.seconds
    ANSWER_POLL = 0.25

    # Words of the session's title said beside the PR: enough to recognise it.
    TITLE_WORDS = 8
    # Kept for the model to say only if the person asks why it was held.
    GATE_REASON_LIMIT = 240

    # What every answer that merged starts with.
    MERGED = /\AMerge (already )?authorized\b/

    # Said to the person; and what ToolBridge raises it as.
    Refused = Class.new(StandardError)

    DESCRIPTION = "Merge a pull request for the person, the way the Merge button in Zimmer does. Use this, not a " \
                  "follow-up or a new session, whenever merging, shipping or approving a PR comes up. Call it with the " \
                  "session_id of the session that opened the PR (find it with the zimmer tool's quick_search_sessions, " \
                  "querying the PR URL with show_archived false) BEFORE you ask whether to merge, so the question you " \
                  "then ask is the only one. If the person has already said yes it merges at once and says so; otherwise it " \
                  "answers with the question. Ask it once, in your own words, and add nothing after it. As soon as they " \
                  "answer yes, in any words, call it again with the same session_id and confirm true. Never ask them a " \
                  "second time unless a result here tells you to: a yes they gave keeps counting. If they say no or change " \
                  "their mind, do not call it. If the PR is held by a session on another Zimmer that a session here " \
                  "drives, pass that PR's URL as pr_url on both calls, with the session_id of the session here that drives it."

    def self.function
      ToolBridge::Function.new(
        name: NAME,
        description: DESCRIPTION,
        parameters: {
          type: "object",
          properties: {
            session_id: { type: "integer", description: "The session that opened the PR and holds it." },
            confirm: { type: "boolean", description: "True once the person has answered the question with a yes." },
            pr_url: { type: "string", description: "Only for a PR held by a session on another Zimmer that this session drives: the PR's URL. Leave it out for the session's own PR." }
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
      # A wait re-reads within one request, which would otherwise be answered
      # from its query cache.
      ActiveRecord::Base.uncached { authorize(args) }
    end

    # The read-back for a PR a session on another Zimmer holds: the same
    # sentence, with the remote session's title and where it is held.
    def self.remote_read_back(target, held_on:)
      sentence = +"Merge #{target.repo.to_s.split('/').last} pull request #{pr_number(target.pr_url)}"
      title = spoken_text(target.title)
      sentence << ", \"#{title}\"" if title
      sentence << "?"
      sentence << " A session on #{held_on} holds it."
      sentence << " Its merge gate held it for you." if target.gate_hold_reason
      sentence
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
    def self.spoken_title(session) = spoken_text(session.title)

    def self.spoken_text(text)
      title = text.to_s
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

    def self.latest_gate_hold_reason(pr_url)
      decision = GateDecision.for_gate(GateDecision::PR_MERGE).for_artifact(pr_url).recent_first.first
      return nil unless decision&.decision == "hold"

      reason = decision.payload.is_a?(Hash) ? decision.payload["reason"].to_s.squish : ""
      reason.presence&.truncate(GATE_REASON_LIMIT, separator: " ") || "no reason given"
    end

    private

    def authorize(args)
      session = find_session!(args["session_id"])
      summary = Sessions::PrSummary.for(session)
      confirming = truthy?(args["confirm"])
      requested = args["pr_url"].to_s.strip.presence
      return remote(session, requested, confirming) if requested && requested != summary.url

      if (reason = summary.merge_blocked_reason)
        raise Refused, "Cannot merge from session #{session.id}: #{reason} Tell the person."
      end

      local(session, summary.url, confirming)
    end

    # A yes Zimmer may act on.
    #
    # `question`: the tool turn of the question they answered, or nil for a yes
    # from before any.
    Confirmation = Data.define(:answers, :asked, :question, :surface, :answer) do
      def where = [ "Zimmer Live Mode", surface ].compact.join(" on ")
      def read_back = question&.tool_output.to_s[/\AREAD-BACK: (.*)$/, 1]
      def words = HumanMessageCapture::LiveModeWords.new(turns: answers, replying_to: asked, declined: nil)
    end

    # No yes to act on, and why. `heard_yes`: the person said one all the same.
    Unanswered = Data.define(:code, :message, :heard_yes)

    def local(session, pr_url, confirming)
      if Sessions::AuthorizeMerge.authorized_at(session, pr_url)
        return "Already authorized: session #{session.id} has been told to merge #{pr_url}. Tell the person."
      end

      let_an_answer_land(session, pr_url) if confirming
      refuse_tainted!
      asked = questions(session, pr_url)
      names = [ repo_name(pr_url), self.class.spoken_title(session).to_s ]
      yes = asked.any? ? answer_to(asked, pr_url, names, confirming) : already_said_yes(session, pr_url, names)
      return merge(session, pr_url, yes) if yes.is_a?(Confirmation)
      return refuse!(yes || not_asked(session), session) if confirming

      report_asked_again(session, asked, yes)
      prepare(session, pr_url)
    end

    def prepare(session, pr_url)
      hold = self.class.latest_gate_hold_reason(pr_url)
      "READ-BACK: #{self.class.read_back(session, pr_url)}\n\n" \
        "PR: #{pr_url}\n" \
        "#{how_to_ask("session_id #{session.id}")}" \
        "#{"\nWhy the gate held it, only if they ask: #{hold}" if hold}"
    end

    def how_to_ask(arguments)
      "Nothing is merged yet, and no yes given so far counts. Ask the person now, once, in your own words, naming the " \
        "repository and the number, and stop there. When they answer yes, in any words, call #{NAME} with " \
        "#{arguments} and confirm true, without asking again. If they say no, or change their mind, merge nothing."
    end

    def merge(session, pr_url, yes)
      # Only Zimmer's sentence and the person's answer go into the authorization.
      # What the model said stays in the HumanMessage, labelled as the model's.
      result = Sessions::AuthorizeMerge.call(
        session: session, surface: yes.where,
        act: "said yes in #{yes.where} to merging this PR, which Zimmer named from its own record of this session " \
             "(they answered: \"#{yes.answer.truncate(60)}\")"
      )
      raise Refused, "#{result.message} Tell the person." unless result.ok?

      if result.sent?
        HumanMessageCapture.record_live_mode_merge_approval(
          session: session, conversation: @conversation, words: yes.words,
          pr_url: pr_url, read_back: yes.read_back, relayed: "Merge #{pr_url}", occurred_at: @now
        )
      end
      "#{result.message} Tell the person, in one short sentence."
    end

    # --- The person's yes -------------------------------------------------------

    # Whether the person has said a clear yes since the first of `asked`, the
    # standing questions for this PR.
    #
    # @param confirming [Boolean] whether the model says they did
    # @return [Confirmation, Unanswered]
    def answer_to(asked, pr_url, names, confirming)
      latest = asked.last
      if latest.created_at < @now - QUESTION_WINDOW
        return Unanswered.new(code: :old_question, heard_yes: false,
                              message: "the question was more than #{QUESTION_WINDOW.inspect} ago. Call #{NAME} again without confirm and ask once.")
      end

      lines = lines_after(start_of(asked))
      said = lines.select(&:user?)
      if said.empty?
        return Unanswered.new(code: :silent, heard_yes: false,
                              message: "the person has not answered since Zimmer gave you the question. If you have asked since then, do " \
                                       "not ask again: wait for their answer, then call with confirm true. If you asked only " \
                                       "before it, or not at all, ask once now.")
      end
      authors = said.map(&:author).uniq
      if authors.size != 1 || authors.first.blank?
        return Unanswered.new(code: :authors, heard_yes: false,
                              message: "the person's latest words are not one signed-in person's alone. Tell the person.")
      end

      reader = MergeAnswer.new(number: self.class.pr_number(pr_url), names: names)
      readings = said.index_with { |turn| reader.answer(turn.content) }
      yeses = said.select { |turn| readings[turn].yes? }
      if (no = said.find { |turn| readings[turn].no? })
        return Unanswered.new(code: :no, heard_yes: false,
                              message: "the person said #{quoted(no)}. If that was a no, leave it. If it was about something else, " \
                                       "call #{NAME} again without confirm and ask once more.")
      end
      if yeses.empty?
        return Unanswered.new(code: :unclear, heard_yes: false,
                              message: "#{quoted(said.last)} is not a clear yes. If it was a no, leave it. If you are not sure, ask " \
                                       "what they meant, once, then call with confirm true.")
      end
      if (undone = said.find { |turn| turn.id > yeses.last.id && !readings[turn].neutral? })
        return Unanswered.new(code: :takes_back, heard_yes: false,
                              message: "after their yes the person said #{quoted(undone)}. Do what that asks. If they still want it " \
                                       "merged now, call #{NAME} again without confirm and ask once.")
      end

      # What they said between two yeses may have taken the first back, so only
      # what came after it counts, and only as the answer to being asked again.
      undone = said.reverse.find { |turn| turn.id < yeses.last.id && (readings[turn].takes_back? || (readings[turn].unclear? && yeses.first.id < turn.id)) }
      standing = undone ? yeses.select { |turn| turn.id > undone.id } : yeses
      answers = standing.select { |turn| answers_the_merge?(turn, lines, reader, readings, confirming && undone.nil?) }
      if answers.empty?
        return Unanswered.new(code: :other_question, heard_yes: true,
                              message: "what you said just before their yes was not asking to merge, so it may answer that. Ask once " \
                                       "whether to merge pull request #{self.class.pr_number(pr_url)}, and nothing else.")
      end
      if answers.last.created_at < @now - CONFIRM_WINDOW
        return Unanswered.new(code: :old_yes, heard_yes: true,
                              message: "their yes was more than #{CONFIRM_WINDOW.inspect} ago. Call #{NAME} again without confirm and ask once.")
      end
      unless merging_came_up?(asked.first)
        return Unanswered.new(code: :never_said, heard_yes: true,
                              message: "nothing said aloud since Zimmer gave you the question was about merging. Ask once whether to " \
                                       "merge pull request #{self.class.pr_number(pr_url)}.")
      end

      confirmation(answers, lines, question: latest)
    end

    # A yes from before any question, to the PR the conversation already had
    # open. See the class comment. Strict, because missing one costs a single
    # question.
    #
    # @return [Confirmation, nil]
    def already_said_yes(session, pr_url, names)
      words = HumanMessageCapture.live_mode_words(@conversation, now: @now)
      return nil if words.declined

      run = words.turns
      return nil if run.last.created_at < @now - EARLY_YES_WINDOW || run.first.id <= last_merged_id

      shown = last_session_shown(before: run.first.id)
      return nil unless shown && shown.created_at >= @now - QUESTION_WINDOW && shows?(shown, session, pr_url)
      # They have been asked about another PR since.
      return nil if merge_calls.where("id > ?", run.first.id).any? { |turn| question?(turn) }

      earlier = spoken.where("id < ?", run.first.id).where("id > ?", shown.id).reorder(:id).to_a
      heard = earlier.reverse.take_while { |turn| !turn.user? }.reverse
      return nil if heard.empty?

      reader = MergeAnswer.new(number: self.class.pr_number(pr_url), names: names)
      readings = run.map { |turn| reader.answer(turn.content) }
      yes = run.zip(readings).reverse.find { |_, reading| reading.yes? }
      return nil unless yes&.last&.strong && readings.all? { |reading| reading.yes? || reading.neutral? }

      aloud = heard.map(&:content).join(" ")
      return nil if reader.changes_subject?(aloud)
      return nil unless MergeAnswer.asks_only_to_merge?(aloud) || MergeAnswer.says_merge?(yes.first.content)

      confirmation([ yes.first ], earlier, question: nil)
    end

    def confirmation(answers, lines, question:)
      surface = HumanMessage::LIVE_MODE_SURFACES[answers.last.author_provenance.to_h["surface"]]
      before = lines.select { |turn| !turn.user? && turn.id < answers.last.id }
      asked = before.reverse.find { |turn| MergeAnswer.about_merging?(turn.content) } || before.last
      Confirmation.new(answers: answers, asked: asked, question: question, surface: surface,
                       answer: answers.map(&:content).join(" ").squish)
    end

    # Whether this yes is to the merge, going by the assistant's lines before it,
    # newest first: none may be about something else, back to one that asks or to
    # the person's last plain answer. A clear yes the model calls a confirmation
    # (`clear_is_enough`) needs no more. Any other needs a line that asks, since
    # the person last said anything but filler.
    def answers_the_merge?(turn, lines, reader, readings, clear_is_enough)
      clear = clear_is_enough && readings[turn].strong
      spoke = false
      lines.take_while { |line| line.id < turn.id }.reverse_each do |line|
        if line.user?
          break unless readings[line].unclear? || readings[line].neutral?

          spoke ||= readings[line].unclear?
        elsif reader.changes_subject?(line.content, clear: clear, merging: MergeAnswer.says_merge?(turn.content))
          return false
        elsif reader.asks?(line.content)
          break if spoke

          return true
        end
      end
      clear
    end

    # Whether merging came up aloud, by either of them, around the question or
    # since. In no particular order: the line that asked may be recorded last, or
    # be cut to nothing.
    def merging_came_up?(question)
      spoken.where("created_at >= ?", question.created_at - TALK_BEFORE).pluck(:content).any? { |text| MergeAnswer.about_merging?(text) }
    end

    # The answer may still be on its way to Zimmer when the model acts on it: no
    # yes is there, and nothing they said came after the newest line that asks.
    def let_an_answer_land(session, pr_url)
      return unless @conversation.voice?

      reader = MergeAnswer.new(number: self.class.pr_number(pr_url))
      (ANSWER_GRACE / ANSWER_POLL).to_i.times do
        asked = questions(session, pr_url)
        break if asked.empty?

        lines = lines_after(start_of(asked))
        said = lines.select(&:user?)
        break if said.any? { |turn| reader.answer(turn.content).yes? }
        break if said.any? && lines.none? { |turn| turn.id > said.last.id && reader.asks?(turn.content) }

        pause
      end
      @conversation.reload
    end

    def pause = sleep(ANSWER_POLL)

    def spoken = @conversation.turns.where(role: %w[user assistant])

    def lines_after(id) = spoken.where("id > ?", id).reorder(:id).to_a

    # A yes is spent by the merge it sent, whichever PR that was: one that came
    # back unmerged, and the next PR, are asked about.
    def start_of(asked) = [ asked.first.id, last_merged_id ].max

    def last_merged_id = merge_calls.limit(20).find { |turn| turn.tool_output.to_s.match?(MERGED) }&.id.to_i

    def merge_calls = @conversation.turns.where(role: "tool", tool_name: NAME, tool_error: false).reorder(id: :desc)

    # The newest tool turn before `before` in which Zimmer showed the
    # conversation one session: `get_session`, or a merge question.
    def last_session_shown(before:)
      @conversation.turns.where(role: "tool", tool_error: false, tool_name: [ NAME, ToolBridge::ZIMMER_TOOL ])
                   .where("id < ?", before).reorder(id: :desc).limit(40).find { |turn| shown_session_ids(turn).any? }
    end

    def shown_session_ids(turn)
      return [ called_session_id(turn) ].compact if turn.tool_name == NAME
      return [] unless turn.tool_arguments.to_h["tool"] == "get_session"

      LiveConversation.session_ids_in_arguments(turn.tool_arguments)
    end

    def shows?(turn, session, pr_url)
      shown_session_ids(turn) == [ session.id ] && turn.tool_output.to_s.match?(/#{Regexp.escape(pr_url)}(?!\d)/)
    end

    def quoted(turn) = "\"#{turn.content.to_s.squish.truncate(120)}\""

    def repo_name(pr_url) = AutomatedPrompts.repo_slug_from_pr_url(pr_url).to_s.split("/").last.to_s

    # --- Saying no --------------------------------------------------------------

    def not_asked(session)
      Unanswered.new(code: :not_asked, heard_yes: false,
                     message: "Zimmer has not asked the person about this pull request yet. Call #{NAME} with session_id " \
                              "#{session.id} and no confirm first, and ask what it returns.")
    end

    # Before anyone is asked: no yes given here could merge anything.
    def refuse_tainted!
      reason = HumanMessageCapture.live_mode_taint(@conversation)
      return if reason.nil?

      raise Refused, "Not merging, because #{reason}. Do not ask them again here: no yes in this conversation can merge. Tell the " \
                     "person, and that the Merge button in the Zimmer app works."
    end

    def refuse!(unanswered, session)
      report("Live Mode refused a merge the person had said yes to", session, unanswered.code) if unanswered.heard_yes
      raise Refused, "Not merging: #{unanswered.message}"
    end

    # Zimmer is about to hand out a question for a PR the person has already been
    # asked about and has spoken since, without refusing: what "it keeps asking
    # me" looks like from here, whatever the reason turns out to be.
    def report_asked_again(session, asked, yes)
      return if asked.empty? || %i[no takes_back].include?(yes.code) || asked.last.created_at < @now - QUESTION_WINDOW
      return unless spoken.where(role: "user").where("id > ?", start_of(asked)).exists?

      report("Live Mode asked for the same merge more than once", session, :asked_again)
    end

    # Ids only: the words are the person's. The conversation is in the
    # fingerprint because an issue reaches Slack once.
    def report(message, session, code)
      Rails.logger.warn("[LiveConversations::AuthorizeMerge] #{message} live_conversation=#{@conversation.id} session=#{session.id} code=#{code}")
      ErrorReporter.report_message(message, context: { live_conversation_id: @conversation.id, session_id: session.id, code: code.to_s },
                                   fingerprint: [ "live-merge", code.to_s, @conversation.id.to_s ])
    end

    # --- A PR another Zimmer holds ---------------------------------------------

    def remote(session, pr_url, confirming)
      let_an_answer_land(session, pr_url) if confirming
      refuse_tainted!
      asked = questions(session, pr_url)
      yes = asked.any? ? answer_to(asked, pr_url, remote_names(asked.last, pr_url), confirming) : not_asked(session)
      return merge_remote(session, pr_url, yes, confirming) if yes.is_a?(Confirmation)

      remote, target = remote_target!(session, pr_url) unless confirming && yes.code != :not_asked
      # The remote's answer, not this Zimmer's row: it goes stale there once
      # the holding session comes back to rest without merging, so a yes can
      # be given again after a merge that did not happen.
      return already_remote(remote, target, pr_url) if target&.merge_authorized_at
      return refuse!(yes, session) if confirming

      report_asked_again(session, asked, yes)
      prepare_remote(session, pr_url, remote, target)
    end

    def already_remote(remote, target, pr_url)
      "Already authorized: #{remote_label(remote, target)} has told the session holding #{pr_url} to merge it. Tell the person."
    end

    def prepare_remote(session, pr_url, remote, target)
      hold = target.gate_hold_reason&.truncate(GATE_REASON_LIMIT, separator: " ")
      "READ-BACK: #{self.class.remote_read_back(target, held_on: remote_label(remote, target))}\n\n" \
        "PR: #{pr_url}\n" \
        "HEAD: #{target.head_sha}\n" \
        "REMOTE: #{remote.server_name}\n" \
        "#{how_to_ask("session_id #{session.id}, pr_url #{pr_url}")}" \
        "#{"\nWhy the gate held it, only if they ask: #{hold}" if hold}"
    end

    # The repository, and the title as Zimmer quoted it in the question.
    def remote_names(question, pr_url) = [ repo_name(pr_url), question.tool_output.to_s[/\AREAD-BACK: .*?"(.*?)"\?/, 1].to_s ]

    def merge_remote(session, pr_url, yes, confirming)
      prepared = yes.question.tool_output.to_s
      asked_head = head_in(yes.question)
      remote_name = prepared[/^REMOTE: (.+)$/, 1]
      remote = MergeAttestations::Remote.among([ remote_name ] & hierarchy_servers(session)).first
      raise Refused, "Not merging: Zimmer's question did not name a remote it can still reach. Ask again." if asked_head.nil? || remote.nil?

      target = remote_target_from!(remote, pr_url)
      return already_remote(remote, target, pr_url) if target.merge_authorized_at
      unless target.head_sha == asked_head
        return prepare_remote(session, pr_url, remote, target) unless confirming

        raise Refused, "Not merging: pull request #{self.class.pr_number(pr_url)} has a new commit since the person was " \
                       "asked, so their yes does not cover it. Call #{NAME} again without confirm and ask again."
      end

      message = HumanMessageCapture.record_live_mode_merge_approval(
        session: session, conversation: @conversation,
        words: yes.words,
        pr_url: pr_url, read_back: yes.read_back,
        relayed: "Signed merge approval for #{pr_url} at #{asked_head}, delivered to #{remote.server_name}", occurred_at: @now
      )
      raise Refused, "Not merging: Zimmer could not record the person's yes, so it signs nothing. Tell the person." if message.nil?

      token, attestation = MergeAttestations::Issuer.mint!(
        session: session, human_message: message, target: target, remote: remote, read_back: yes.read_back, now: @now
      )
      answer = begin
        remote.submit(token)
      rescue MergeAttestations::Remote::Unreachable => e
        { "accepted" => false, "code" => "unreachable", "message" => e.message }
      end
      label = remote_label(remote, target)
      if answer["accepted"] == true
        attestation.update!(outcome: "delivered", outcome_detail: answer["message"].to_s.truncate(1_000),
                            remote_session_url: answer["session_url"].to_s.presence || attestation.remote_session_url)
        log_remote(session, "Signed merge approval for #{pr_url} at #{asked_head[0, 12]} accepted by #{label}: #{answer['message']}")
        return "Merge authorized on #{label}: the session holding #{pr_url} has been told to merge it. Tell the person, in one short sentence."
      end

      attestation.update!(outcome: "delivery_failed", outcome_detail: "#{answer['code']}: #{answer['message']}".truncate(1_000))
      log_remote(session, "Signed merge approval for #{pr_url} refused by #{label} (#{answer['code']}): #{answer['message']}")
      raise Refused, "Not merged: #{label} refused the approval (#{answer['message'].to_s.truncate(200)}). Tell the person."
    end

    # The remote that holds `pr_url`, and its account of it, from the servers
    # the session's spawn hierarchy carries.
    def remote_target!(session, pr_url)
      raise Refused, "Cannot merge: #{pr_url} is not a GitHub pull request URL. Tell the person." unless MergeAttestations.parse_pr_url(pr_url)
      unless MergeAttestations::SigningKey.configured?
        raise Refused, "Cannot merge #{pr_url}: this Zimmer has no key to sign approvals for another Zimmer with " \
                       "(#{MergeAttestations::SIGNING_KEY_ENV}). Tell the person."
      end
      begin
        MergeAttestations::SigningKey.current
      rescue MergeAttestations::SigningKey::NotConfigured => e
        raise Refused, "Cannot merge #{pr_url}: this Zimmer's signing key is set but unusable (#{e.message}). Tell the person."
      end

      remotes = MergeAttestations::Remote.among(hierarchy_servers(session))
      if remotes.empty?
        raise Refused, "Cannot merge #{pr_url}: session #{session.id} does not drive another Zimmer this one can send " \
                       "approvals to, and #{pr_url} is not its own PR. Find the session that drives the one holding it."
      end

      reasons = []
      remotes.each do |remote|
        target = remote_target_from!(remote, pr_url, raise_blocked: false)
        return [ remote, target ] if target.ok?

        reasons << "#{remote.server_name}: #{target.blocked_reason}"
      rescue Refused => e
        reasons << e.message
      end
      raise Refused, "Cannot merge #{pr_url}. #{reasons.join(' ')} Tell the person."
    end

    def remote_target_from!(remote, pr_url, raise_blocked: true)
      target = remote.target(pr_url)
      blocked = target.blocked_reason
      repo, number = MergeAttestations.parse_pr_url(pr_url)
      blocked ||= "it answered for a different PR" unless target.pr_url == pr_url && target.repo == repo && target.pr_number == number
      blocked ||= "it did not name its head commit" unless target.head_sha.to_s.match?(MergeAttestations::SHA)
      blocked ||= "it calls itself #{target.audience.to_s.truncate(80).inspect}, not #{remote.audience}" unless target.audience == remote.audience
      blocked ||= "it does not trust this Zimmer's signing key yet" unless target.trusts_issuer
      target = target.with(blocked_reason: blocked)
      raise Refused, "Cannot merge #{pr_url} on #{remote.server_name}: #{blocked} Tell the person." if blocked && raise_blocked

      target
    rescue MergeAttestations::Remote::Unreachable => e
      raise Refused, "Cannot merge #{pr_url}: #{e.message}. Tell the person."
    end

    # The catalog servers on this session, its ancestors and its descendants.
    def hierarchy_servers(session)
      chain = []
      node = session
      while node && chain.size < 50
        chain << node
        node = node.parent_session
      end
      frontier = [ session.id ]
      seen = chain.map(&:id).to_set
      while frontier.any? && seen.size < 500
        children = Session.where(parent_session_id: frontier).where.not(id: seen.to_a).limit(500).to_a
        chain.concat(children)
        seen.merge(children.map(&:id))
        frontier = children.map(&:id)
      end
      chain.flat_map { |member| Array(member.mcp_servers) }.map(&:to_s).uniq
    end

    def remote_label(remote, _target)
      URI.parse(remote.audience.to_s).host.presence || remote.server_name
    rescue URI::InvalidURIError
      remote.server_name
    end

    def log_remote(session, content)
      session.logs.create!(level: "info", content: content)
    rescue => e
      Rails.logger.warn("[LiveConversations::AuthorizeMerge] could not log on session #{session.id}: #{e.message}")
    end

    def find_session!(value)
      id = Integer(value.to_s, exception: false)
      session = id && Session.find_by(id: id)
      raise Refused, "No session #{value.inspect}. Find the session that opened the PR with quick_search_sessions." if session.nil?

      session
    end

    # The standing questions for this session and PR, oldest first, or [] when
    # the newest question in the conversation is for anything else: a yes answers
    # the last PR the person was asked about, and no other. A question repeated
    # for the same PR (and, on another Zimmer, the same commit) does not move the
    # start, so a yes to the first still counts, until the person refuses or
    # takes it back in between: the newer question then starts over.
    def questions(session, pr_url)
      run = []
      merge_calls.limit(20).select { |turn| question?(turn) }.each do |turn|
        break unless called_session_id(turn) == session.id && turn.tool_output.to_s.include?("PR: #{pr_url}\n")
        break if run.any? && (turn.created_at < @now - QUESTION_WINDOW || head_in(turn) != head_in(run.first) || undone_between?(turn, run.first, pr_url))

        run.unshift(turn)
      end
      # A merge was sent since: whatever was asked before it is settled.
      settled = last_merged_id
      run.reject { |turn| turn.id < settled }
    end

    def undone_between?(earlier, later, pr_url)
      reader = MergeAnswer.new(number: self.class.pr_number(pr_url))
      readings = spoken.where(role: "user").where(id: (earlier.id + 1)...later.id).reorder(:id).pluck(:content).map { |content| reader.answer(content) }
      readings.any? { |reading| reading.no? || reading.takes_back? } || readings.drop_while { |reading| !reading.yes? }.any?(&:unclear?)
    end

    def question?(turn) = turn.tool_output.to_s.start_with?("READ-BACK: ")

    def head_in(turn) = turn.tool_output.to_s[/^HEAD: ([0-9a-f]{40})$/, 1]

    def called_session_id(turn) = Integer(turn.tool_arguments.to_h["session_id"].to_s, exception: false)

    def truthy?(value) = value == true || value.to_s.strip.casecmp?("true")
  end
end
