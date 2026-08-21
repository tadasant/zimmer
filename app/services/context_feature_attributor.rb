# frozen_string_literal: true

# Estimates which context-management feature a request's tokens paid for.
#
# THE PROBLEM THIS IS SOLVING AROUND
#
# The API reports one `usage` object per request: totals for fresh input, cache
# reads, cache writes and output. It does not say what any of those tokens WERE.
# So a per-feature figure cannot be measured; it can only be estimated from the
# content the transcript records, and the estimate has to be built so that it can
# never quietly exceed what actually happened.
#
# THE MODEL: MARGINAL, NOT CUMULATIVE
#
# A conversation's prompt grows. Content added at turn 3 is in the prompt for
# every turn after it, so "the goal block is 3,600 characters" is not an answer to
# "what did the goal cost" — it depends entirely on where those characters sit
# relative to the cache boundary. This walks each transcript in order and keeps
# two buckets per conversation:
#
#   carried — everything already in the prompt before this request. This is what
#             a cache READ is paying for, at a tenth of base input.
#   pending — everything added since the previous request. This is the new suffix,
#             which is what a cache WRITE is paying for, at 1.25x or 2x base input.
#
# `cache_read_tokens` is split across `carried`; `input_tokens + cache_creation_*`
# across `pending`; `output_tokens` across the assistant's own blocks. That is what
# makes the dollar answer differ from the token answer in the right direction: a
# feature re-appended to every turn (the goal block) is cache-WRITTEN on every
# turn at up to 2x, while a feature that lands once in the prefix (a skill body)
# is written once and then read at 0.1x forever after.
#
# HONESTY CONSTRAINTS
#
# 1. Characters are converted to tokens at a fixed ratio, which is an
#    approximation. It is used only to size features RELATIVE to a request's real
#    totals, never as an absolute.
# 2. A feature's share can never push the parts above the whole. When the
#    character estimate exceeds the request's actual tokens, every share is scaled
#    down by the same factor rather than any one being trusted.
# 3. Whatever the transcript does not account for is left UNATTRIBUTED rather than
#    spread across the features. Most of that gap is the system prompt and the
#    tool schemas, which never appear in a transcript at all, and pretending
#    otherwise would inflate every feature by the same invisible constant.
class ContextFeatureAttributor
  # Characters per token.
  #
  # Measured, not guessed. Between two consecutive requests in one conversation
  # the fixed prompt prefix cancels, so the change in billed input tokens divided
  # by the change in transcript characters is a direct reading of the ratio on
  # this deployment's own traffic. Over 2,782 such pairs the median is 3.57 and
  # the mean 3.93 — English prose runs higher, the JSON and source code that
  # dominate a tool-heavy transcript lower. 3.7 sits between them.
  #
  # Re-run that measurement with `rake token_usage:attribution_report` if the
  # workload changes shape. The scaling rule above means a wrong ratio moves the
  # residual rather than reordering the features against each other.
  CHARS_PER_TOKEN = 3.7

  # Columns a feature row carries. Named to match `session_token_usages` so
  # TokenPricing prices both tables with one expression.
  PREFIX_COLUMNS = %i[cache_read_tokens].freeze
  SUFFIX_COLUMNS = %i[
    input_tokens cache_creation_tokens cache_creation_5m_tokens cache_creation_1h_tokens
  ].freeze
  OUTPUT_COLUMNS = %i[output_tokens].freeze

  # One conversation's running context. A transcript file can hold several: the
  # main thread, each subagent sidechain, and a replayed history after a resume.
  # They are told apart by walking `parentUuid` back to a root, so two subagents
  # running at once do not pool their contexts into one another's estimate.
  Chain = Struct.new(:carried, :carried_occurrences, :pending, :pending_occurrences) do
    def self.blank
      new(Hash.new(0), Hash.new(0), Hash.new(0), Hash.new(0))
    end

    def promote!
      pending.each { |k, v| carried[k] += v }
      pending_occurrences.each { |k, v| carried_occurrences[k] += v }
      self.pending = Hash.new(0)
      self.pending_occurrences = Hash.new(0)
    end
  end

  def initialize
    @chains = {}
    @chain_of_uuid = {}
    @last_chain_in_lane = {}
    @tool_names = {}
    @open = nil
    @rows = []
  end

  # Feed every line of a transcript, in file order.
  def observe(entry)
    return unless entry.is_a?(Hash)

    type = entry["type"]
    return unless type == "user" || type == "assistant"

    chain = chain_for(entry)
    blocks = content_blocks(entry, type)

    if type == "user"
      classify_into(blocks, chain.pending, chain.pending_occurrences) if blocks.any?
      return
    end

    # The request is opened BEFORE the empty-content check. A line can carry a
    # `usage` object and no content blocks — a refusal, a stop, a malformed line —
    # and its prefix was still billed. Bailing early would drop that request's
    # attribution entirely rather than attributing what it can see.
    request_id = entry["requestId"].presence
    start_request(entry, chain, request_id) if request_id && request_id != @open&.[](:request_id)
    return if blocks.empty?

    if @open
      # An assistant block is billed twice over its life: once as output now, and
      # again as prompt content on every later turn. Both are recorded.
      classify_into(blocks, @open[:output], @open[:output_occurrences])
      classify_into(blocks, @open[:carry_forward], @open[:carry_forward_occurrences])
    else
      classify_into(blocks, chain.pending, chain.pending_occurrences)
    end
  end

  # Every attributed row for the file. Call once, after the last line.
  def rows
    close_request
    @rows
  end

  private

  # Which conversation this line belongs to.
  #
  # A transcript file interleaves several: the main thread, each subagent
  # sidechain, and a replayed history after a resume. Following `parentUuid` back
  # to a root separates them, so two subagents running at once do not pool their
  # contexts into one another's estimate.
  #
  # Only a USER line with no parent starts a new chain. A conversation always
  # begins with a user turn, so an assistant line that arrives without a parent is
  # a gap in the record rather than the start of something — treating it as a new
  # conversation would throw away everything already carried and report the whole
  # prompt as unattributed. It joins the most recent chain in its lane instead.
  def chain_for(entry)
    uuid = entry["uuid"]
    parent = entry["parentUuid"]
    lane = "#{entry["sessionId"]}/#{entry["isSidechain"] ? "side" : "main"}"

    chain_id = parent && @chain_of_uuid[parent]
    chain_id ||= "#{lane}/#{@chains.size}" if parent.nil? && entry["type"] == "user"
    chain_id ||= @last_chain_in_lane[lane]
    chain_id ||= "#{lane}/#{@chains.size}"

    @chain_of_uuid[uuid] = chain_id if uuid
    @last_chain_in_lane[lane] = chain_id
    @chains[chain_id] ||= Chain.blank
  end

  def content_blocks(entry, role)
    message = entry["message"]
    return [] unless message.is_a?(Hash)

    content = message["content"]
    raw = case content
    when String then [ { "type" => "text", "text" => content } ]
    when Array then content
    else []
    end

    raw.filter_map do |block|
      next unless block.is_a?(Hash)

      # A `tool_result` names only the id of the call it answers, so the id-to-name
      # map built here is what lets a detector ask "did an MCP server send this".
      @tool_names[block["id"]] = block["name"] if block["type"] == "tool_use" && block["id"]

      ContextFeatureRegistry::Block.new(
        role: role,
        type: block["type"],
        text: block_text(block),
        tool_name: block["name"] || @tool_names[block["tool_use_id"]]
      )
    end
  end

  # What a block costs in the prompt is its rendered size, so a structured block
  # is measured as its JSON rather than as the text it happens to contain.
  #
  # A `thinking` block is measured whole rather than by its `thinking` field
  # because that field is EMPTY in every persisted transcript — the harness writes
  # the cryptographic signature and drops the reasoning text. Measured against 955
  # thinking blocks across this deployment's recent corpus, not one retained its
  # text. So extended thinking is systematically under-attributed here: its
  # signature is counted, its reasoning is not, and the difference lands in the
  # unattributed residual. No detector can fix that; only the harness retaining the
  # text could.
  def block_text(block)
    case block["type"]
    when "text" then block["text"].to_s
    when "tool_use" then JSON.generate(block["input"])
    when "tool_result" then block["content"].is_a?(String) ? block["content"] : JSON.generate(block["content"])
    else JSON.generate(block)
    end
  rescue JSON::GeneratorError, ArgumentError
    ""
  end


  def classify_into(blocks, chars, occurrences)
    blocks.each do |block|
      ContextFeatureRegistry.classify(block).each do |key, count|
        next if count.zero?
        chars[key] += count
        occurrences[key] += 1
      end
    end
  end

  def start_request(entry, chain, request_id)
    close_request

    @open = {
      request_id: request_id,
      chain: chain,
      prefix: chain.carried.dup,
      suffix: chain.pending.dup,
      suffix_occurrences: chain.pending_occurrences.dup,
      usage: entry["message"].is_a?(Hash) ? entry["message"]["usage"] : nil,
      output: Hash.new(0),
      output_occurrences: Hash.new(0),
      carry_forward: Hash.new(0),
      carry_forward_occurrences: Hash.new(0)
    }

    chain.promote!
  end

  def close_request
    open = @open
    @open = nil
    return unless open

    # The assistant's own output becomes prompt content for the next request.
    open[:carry_forward].each { |k, v| open[:chain].pending[k] += v }
    open[:carry_forward_occurrences].each { |k, v| open[:chain].pending_occurrences[k] += v }

    usage = open[:usage]
    return unless usage.is_a?(Hash)

    prefix_shares = shares(open[:prefix], usage["cache_read_input_tokens"].to_i)
    suffix_shares = shares(open[:suffix], usage["input_tokens"].to_i + usage["cache_creation_input_tokens"].to_i)
    output_shares = shares(open[:output], usage["output_tokens"].to_i)

    volumes = volumes_from(usage)

    (prefix_shares.keys | suffix_shares.keys | output_shares.keys).each do |key|
      row = {
        feature: key,
        request_id: open[:request_id],
        # Chars are the NEW bytes this feature contributed to this request, so a
        # sum across a session is the feature's real footprint rather than the
        # same prefix counted once per turn. Its ongoing cost shows up in the
        # cache-read tokens instead.
        chars: open[:suffix].fetch(key, 0) + open[:output].fetch(key, 0),
        occurrences: open[:suffix_occurrences].fetch(key, 0) + open[:output_occurrences].fetch(key, 0)
      }

      PREFIX_COLUMNS.each { |c| row[c] = (volumes[c] * prefix_shares.fetch(key, 0.0)).round }
      SUFFIX_COLUMNS.each { |c| row[c] = (volumes[c] * suffix_shares.fetch(key, 0.0)).round }
      OUTPUT_COLUMNS.each { |c| row[c] = (volumes[c] * output_shares.fetch(key, 0.0)).round }

      next if (PREFIX_COLUMNS + SUFFIX_COLUMNS + OUTPUT_COLUMNS).all? { |c| row[c].zero? } && row[:chars].zero?

      @rows << row
    end
  end

  def volumes_from(usage)
    creation = usage["cache_creation"]
    creation = {} unless creation.is_a?(Hash)

    {
      input_tokens: usage["input_tokens"].to_i,
      output_tokens: usage["output_tokens"].to_i,
      cache_read_tokens: usage["cache_read_input_tokens"].to_i,
      cache_creation_tokens: usage["cache_creation_input_tokens"].to_i,
      cache_creation_5m_tokens: creation["ephemeral_5m_input_tokens"].to_i,
      cache_creation_1h_tokens: creation["ephemeral_1h_input_tokens"].to_i
    }
  end

  # Fraction of an actual token pool each feature gets.
  #
  # Dividing by `max(estimated, actual)` is the whole honesty rule in one line.
  # When the estimate is smaller than what was really billed, each feature keeps
  # its own estimate and the difference stays unattributed. When the estimate
  # overshoots — a badly wrong characters-per-token guess, or content the model
  # never actually saw — every share is scaled down together, so the parts still
  # cannot exceed the whole and no single feature is trusted over the others.
  def shares(chars, actual)
    return {} if actual.zero? || chars.empty?

    estimated = chars.values.sum / CHARS_PER_TOKEN
    return {} if estimated.zero?

    denominator = [ estimated, actual.to_f ].max
    chars.transform_values { |c| (c / CHARS_PER_TOKEN) / denominator }
  end
end
