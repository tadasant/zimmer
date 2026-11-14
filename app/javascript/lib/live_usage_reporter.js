import { csrfHeaders } from "lib/csrf"

// What a Live voice call cost and how fast it answered, reported to Zimmer's
// voice-engine ledger (POST /live_conversations/:id/usage). The browser sends
// volumes — tokens, seconds, milliseconds — never money: Zimmer prices them.
// Each event carries a key unique to the call, so a batch sent twice counts once.
//
// Batched: events wait up to FLUSH_MS, and whatever is left goes when the call
// ends or the tab closes (the dock flushes on `pagehide`, with keepalive, so the
// request outlives the page).
const FLUSH_MS = 5000
const MAX_BATCH = 50

export class LiveUsageReporter {
  // `model`: the Realtime model the call runs on, from its mint, so its tokens
  // are priced on that model even if the conversation's own changes meanwhile.
  constructor(url, engine, { model } = {}) {
    this.url = url
    this.engine = engine
    this.model = model
    this.queue = []
    this.callKey = `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 8)}`
    this.seq = 0
  }

  add(operation, fields = {}) {
    this.seq += 1
    this.queue.push({ engine: this.engine, operation, key: `${this.callKey}.${this.seq}`, ...fields })
    if (this.queue.length >= MAX_BATCH) return this.flush()
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.flush(), FLUSH_MS)
  }

  // A turn's timings: from the end of the person's line to the first sound of
  // the answer, as this browser saw it.
  latency(firstAudioMs, fields = {}) {
    if (!Number.isFinite(firstAudioMs) || firstAudioMs < 0) return
    this.add("turn_latency", { first_audio_ms: Math.round(firstAudioMs), ...fields })
  }

  flush({ keepalive = false } = {}) {
    clearTimeout(this.timer)
    if (!this.queue.length || !this.url) return
    const events = this.queue.splice(0, MAX_BATCH)
    fetch(this.url, {
      method: "POST",
      credentials: "same-origin",
      keepalive,
      headers: csrfHeaders({ Accept: "application/json" }),
      body: JSON.stringify({ events, model: this.model })
    }).catch(() => {})
    if (this.queue.length) this.flush({ keepalive })
  }
}

// A Realtime `response.done`'s usage, split the way the price table is: text and
// audio tokens, with the cached ones counted once, as cached.
export function realtimeUsage(usage) {
  if (!usage) return null
  const input = usage.input_token_details || {}
  const cached = input.cached_tokens_details || {}
  const output = usage.output_token_details || {}
  const cachedText = cached.text_tokens || 0
  const cachedAudio = cached.audio_tokens || 0
  return {
    input_tokens: Math.max((input.text_tokens || 0) - cachedText, 0),
    audio_input_tokens: Math.max((input.audio_tokens || 0) - cachedAudio, 0),
    cache_read_tokens: input.cached_tokens || cachedText + cachedAudio,
    output_tokens: output.text_tokens || 0,
    audio_output_tokens: output.audio_tokens || 0
  }
}
