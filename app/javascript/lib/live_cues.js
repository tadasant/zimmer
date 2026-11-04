// The sounds a Live Mode voice call makes besides Zimmer's voice. The same cues,
// numbers and rules as the phone and the car (`LiveCue` and `LiveCueDirector` in
// ios/Sources/ZimmerKit/Live/LiveCues.swift, which holds the event-to-cue table):
// keep the two together.
const RATE = 24000
const TAIL = 0.08

const note = (frequency, length, peak) => {
  const count = Math.floor(length * RATE)
  const attack = 0.005 * RATE
  return Array.from({ length: count }, (_, index) => {
    const t = index / RATE
    const rise = Math.min(1, index / attack)
    const fade = Math.exp(-t / (length / 3.2))
    const tone = Math.sin(2 * Math.PI * frequency * t) + 0.25 * Math.sin(4 * Math.PI * frequency * t)
    return (tone / 1.25) * rise * fade * peak
  })
}

const tap = (frequency, length, peak) => {
  const count = Math.floor(length * RATE)
  return Array.from({ length: count }, (_, index) => {
    const t = index / RATE
    const envelope = 0.5 - 0.5 * Math.cos((2 * Math.PI * index) / count)
    return Math.sin(2 * Math.PI * frequency * t) * envelope * peak
  })
}

const SOUNDS = {
  connected: () => [...note(659.25, 0.11, 0.22), ...note(987.77, 0.16, 0.22)],
  heard: () => note(659.25, 0.1, 0.12),
  disconnected: () => [...note(987.77, 0.11, 0.2), ...note(659.25, 0.18, 0.2)],
  thinking: () => tap(520, 0.045, 0.07),
  working: () => [...tap(329.63, 0.09, 0.08), ...tap(392, 0.09, 0.08)],
  failed: () => [...note(349.23, 0.14, 0.18), ...note(293.66, 0.24, 0.18)],
  ended: () => note(329.63, 0.22, 0.14)
}

export const HEARD_LEAD = 0.35
export const LOOPS = {
  thinking: { period: 1, lead: 1, ceiling: 45 },
  working: { period: 2.5, lead: 0.35, ceiling: 600 }
}

export const cueSamples = (cue) => SOUNDS[cue]()

export class LiveCueDirector {
  constructor() {
    this.greeted = false
    this.state = "idle"
    this.tools = 0
    this.talking = false
    this.failureSounded = false
    this.failureHeld = false
    this.loop = null
  }

  transition(state) {
    this.state = state
    const actions = []
    if (state === "listening" && !this.greeted) {
      this.greeted = true
      actions.push({ play: "connected" })
    } else if (state === "speaking") {
      this.failureSounded = false
      this.loop = null
      return [{ stopCues: true }]
    }
    return [...this.settle(), ...actions]
  }

  personTalking() {
    this.talking = true
    this.failureSounded = false
    this.loop = null
    return [{ stopCues: true }]
  }

  personStopped() {
    this.talking = false
    const held = this.failureHeld ? this.actionFailed() : []
    this.failureHeld = false
    return [...this.settle(), ...held]
  }

  heardPerson() {
    return this.state === "speaking" || this.talking ? [] : [{ play: "heard", after: HEARD_LEAD }]
  }

  toolsRunning(count) {
    this.tools = count
    return this.settle()
  }

  actionFailed() {
    // Never while the person talks: it would close the microphone on them.
    if (this.talking) {
      this.failureHeld = true
      return []
    }
    if (this.failureSounded) return []
    this.failureSounded = true
    return [{ play: "failed" }]
  }

  // An error ended whatever was going on: a stray one while the call waits for
  // the person means nothing to them.
  noAnswerComing() {
    return this.loop ? this.actionFailed() : []
  }

  loopTimedOut() {
    if (!this.loop) return []
    this.loop = null
    return [{ stopLoop: true }, ...this.actionFailed()]
  }

  dropped() {
    return this.farewell("disconnected")
  }

  hungUp() {
    return this.farewell("ended")
  }

  farewell(cue) {
    const quiet = this.greeted || this.loop ? [{ stopCues: true }] : []
    const goodbye = this.greeted ? [{ play: cue }] : []
    this.loop = null
    this.state = "idle"
    this.greeted = false
    return [...quiet, ...goodbye]
  }

  get wanted() {
    if (this.talking) return null
    if (this.state === "thinking" || this.state === "working") return this.tools > 0 ? "working" : "thinking"
    if (this.state === "listening" && this.tools > 0) return "working"
    return null
  }

  settle() {
    const wanted = this.wanted
    if (wanted === this.loop) return []
    const stopping = this.loop ? [{ stopLoop: true }] : []
    this.loop = wanted
    return [...stopping, ...(wanted ? [{ startLoop: wanted }] : [])]
  }
}

// Plays the cues, and closes the microphone (`onMicGate(true)`) while one
// sounds, so turn detection never takes a cue for speech: the browser's echo
// canceller is not guaranteed to have Web Audio as its reference. The loops run
// on timers rather than a looping source, so each repeat closes the gate itself.
export class LiveCuePlayer {
  constructor({ onMicGate, onLoopTimeout }) {
    this.onMicGate = onMicGate
    this.onLoopTimeout = onLoopTimeout
    this.buffers = new Map()
    this.oneShots = new Set()
    this.loopSounds = new Set()
    this.closures = 0
  }

  // A browser lets audio start from a user gesture, or once the page is
  // capturing the microphone, so this is called at both. A call with no cues is
  // still a call, so a browser that refuses just goes without.
  unlock() {
    try {
      this.context = this.context || new AudioContext()
      this.context.resume().catch(() => {})
    } catch (_error) {
      this.context = null
    }
  }

  perform(actions) {
    actions.forEach((action) => {
      if (action.play) this.sound(action.play, action.after || 0, this.oneShots)
      if (action.stopLoop) this.stopLoop()
      if (action.stopCues) this.stopCues()
      if (action.startLoop) this.startLoop(action.startLoop)
    })
  }

  startLoop(cue) {
    const { period, lead, ceiling } = LOOPS[cue]
    const repeat = () => {
      this.sound(cue, 0, this.loopSounds)
      this.loopTimer = setTimeout(repeat, period * 1000)
    }
    this.loopTimer = setTimeout(repeat, lead * 1000)
    this.ceilingTimer = setTimeout(() => this.onLoopTimeout(), ceiling * 1000)
  }

  stopLoop() {
    clearTimeout(this.loopTimer)
    clearTimeout(this.ceilingTimer)
    this.cancel(this.loopSounds)
  }

  stopCues() {
    this.stopLoop()
    this.cancel(this.oneShots)
  }

  sound(cue, delay, bag) {
    // Suspended, a cue would close the microphone and make no sound.
    if (this.context?.state !== "running") return
    const source = this.context.createBufferSource()
    source.buffer = this.buffer(cue)
    source.connect(this.context.destination)
    source.start(this.context.currentTime + delay)
    const closedFor = source.buffer.duration + TAIL + (this.context.outputLatency || this.context.baseLatency || 0)
    const entry = { source, closed: false }
    entry.closing = setTimeout(() => this.closeMic(entry), delay * 1000)
    entry.opening = setTimeout(() => { this.openMic(entry); bag.delete(entry) }, (delay + closedFor) * 1000)
    bag.add(entry)
  }

  buffer(cue) {
    if (!this.buffers.has(cue)) {
      const samples = cueSamples(cue)
      const buffer = this.context.createBuffer(1, samples.length, RATE)
      buffer.copyToChannel(Float32Array.from(samples), 0)
      this.buffers.set(cue, buffer)
    }
    return this.buffers.get(cue)
  }

  cancel(bag) {
    bag.forEach((entry) => {
      clearTimeout(entry.closing)
      clearTimeout(entry.opening)
      entry.source.stop()
      this.openMic(entry)
    })
    bag.clear()
  }

  closeMic(entry) {
    entry.closed = true
    this.closures += 1
    if (this.closures === 1) this.onMicGate(true)
  }

  openMic(entry) {
    if (!entry.closed) return
    entry.closed = false
    this.closures -= 1
    if (this.closures === 0) this.onMicGate(false)
  }
}
