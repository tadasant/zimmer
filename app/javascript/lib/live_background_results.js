// What came back from the background while a voice call is up: work the person
// started earlier that finished, failed or needs them. Zimmer says how many are
// waiting on the poll the call already makes (/live/current.json); this claims
// them, hands each one to the call as context the model does not speak yet, so it
// is known before the person's next turn, and tells Zimmer it has
// (LiveConversations::BackgroundResults).
//
// A claim is this call's id and a number. One whose answer was lost is made again
// unchanged, whatever the count says, and gets the same results; `seen` drops any
// that were handed over already. Until Zimmer has heard a result was handed over,
// it is said on every look, and a call that ends first leaves it for the next one.
export class LiveBackgroundResults {
  // `post(url, body)`: the caller's fetch. `ready()`: nothing is running or being
  // answered. `deliver(text)`: hand one to the voice model; false if it could not.
  constructor({ conversationId, post, ready, deliver, call = LiveBackgroundResults.newCall() }) {
    this.url = `/live_conversations/${conversationId}/background_results`
    this.post = post
    this.ready = ready
    this.deliver = deliver
    this.call = call
    this.number = 1
    this.seen = new Set()
    this.undelivered = []
    this.unreported = []
  }

  static newCall() {
    return crypto.randomUUID()
  }

  // `waiting`: the poll's count.
  async check(waiting) {
    if (this.asking) return
    this.asking = true
    try {
      if (this.undelivered.length === 0 && this.ready() && (waiting > 0 || this.claiming)) await this.claim()
      this.handOver()
      if (this.unreported.length > 0) await this.report()
    } catch (_error) {
      // Zimmer could not be reached: the same again on the next poll.
    } finally {
      this.asking = false
    }
  }

  async claim() {
    this.claiming = true
    const response = await this.post(this.url, { claim: `${this.call}:${this.number}` })
    if (!response.ok) return
    const { results } = await response.json()
    this.claiming = false
    this.number += 1
    for (const result of results || []) {
      if (this.seen.has(result.id)) continue
      this.seen.add(result.id)
      this.undelivered.push(result)
    }
  }

  // Not in the middle of a delegation or a reply: one that began while Zimmer
  // was answering leaves these for the next poll.
  handOver() {
    while (this.undelivered.length > 0 && this.ready()) {
      if (!this.deliver(this.undelivered[0].text)) return
      this.unreported.push(this.undelivered.shift().id)
    }
  }

  async report() {
    const ids = [...this.unreported]
    const response = await this.post(this.url, { claim: `${this.call}:${this.number}`, delivered: ids })
    if (response.ok) this.unreported = this.unreported.filter((id) => !ids.includes(id))
  }
}
