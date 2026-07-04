import { Controller } from "@hotwired/stimulus"

// Push notification subscription controller
//
// Handles:
// - Service worker registration
// - Notification permission requests
// - Push subscription management
// - Communication with server API
//
// Usage:
//   <div data-controller="push-subscription">
//     <button data-action="push-subscription#subscribe">Enable Notifications</button>
//   </div>
export default class extends Controller {
  static targets = ["button", "status", "toggle", "toggleOnIcon", "toggleOffIcon", "blockedMessage", "notSupportedMessage"]
  static values = {
    subscriptionId: Number
  }

  connect() {
    this.updateUI()
  }

  async subscribe() {
    if (!this.isPushSupported()) {
      this.showStatus("Push notifications are not supported in this browser", "error")
      return
    }

    try {
      // Register service worker first
      const registration = await this.registerServiceWorker()
      if (!registration) return

      // Request notification permission
      const permission = await this.requestPermission()
      if (permission !== "granted") {
        this.showStatus("Notification permission denied", "error")
        this.updateUI()
        return
      }

      // Subscribe to push notifications
      const subscription = await this.subscribeToPush(registration)
      if (!subscription) return

      // Save subscription to server
      await this.saveSubscription(subscription)

      this.showStatus("Notifications enabled successfully!", "success")
      this.updateUI()
    } catch (error) {
      console.error("Failed to subscribe to push notifications:", error)
      this.showStatus(`Failed to enable notifications: ${error.message}`, "error")
    }
  }

  async unsubscribe() {
    try {
      const registration = await navigator.serviceWorker.ready
      const subscription = await registration.pushManager.getSubscription()

      if (subscription) {
        await subscription.unsubscribe()
      }

      // Delete from server if we have the ID
      if (this.hasSubscriptionIdValue && this.subscriptionIdValue) {
        await this.deleteSubscription(this.subscriptionIdValue)
      }

      this.subscriptionIdValue = null
      this.showStatus("Notifications disabled", "success")
      this.updateUI()
    } catch (error) {
      console.error("Failed to unsubscribe:", error)
      this.showStatus(`Failed to disable notifications: ${error.message}`, "error")
    }
  }

  // Handle toggle switch click - determines whether to subscribe or unsubscribe
  async handleToggle() {
    if (!this.hasToggleTarget) return

    const isCurrentlyOn = this.toggleTarget.getAttribute("aria-checked") === "true"

    if (isCurrentlyOn) {
      await this.unsubscribe()
    } else {
      await this.subscribe()
    }
  }

  // Private methods

  isPushSupported() {
    return "serviceWorker" in navigator && "PushManager" in window
  }

  async registerServiceWorker() {
    try {
      const registration = await navigator.serviceWorker.register("/service-worker.js")
      console.log("Service Worker registered with scope:", registration.scope)
      return registration
    } catch (error) {
      console.error("Service Worker registration failed:", error)
      this.showStatus("Failed to register service worker", "error")
      return null
    }
  }

  async requestPermission() {
    if (Notification.permission === "granted") {
      return "granted"
    }

    if (Notification.permission === "denied") {
      return "denied"
    }

    return await Notification.requestPermission()
  }

  async subscribeToPush(registration) {
    const vapidPublicKey = this.getVapidPublicKey()
    if (!vapidPublicKey) {
      this.showStatus("Push notifications are not configured on this server", "error")
      return null
    }

    try {
      // Wait for the service worker to be ready
      await navigator.serviceWorker.ready

      const subscription = await registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: this.urlBase64ToUint8Array(vapidPublicKey)
      })

      return subscription
    } catch (error) {
      console.error("Failed to subscribe to push manager:", error)
      throw error
    }
  }

  async saveSubscription(subscription) {
    const response = await fetch("/push_subscriptions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        endpoint: subscription.endpoint,
        p256dh_key: this.arrayBufferToBase64(subscription.getKey("p256dh")),
        auth_key: this.arrayBufferToBase64(subscription.getKey("auth")),
        user_agent: navigator.userAgent
      })
    })

    if (!response.ok) {
      const data = await response.json()
      throw new Error(data.error || "Failed to save subscription")
    }

    const data = await response.json()
    this.subscriptionIdValue = data.id
    return data
  }

  async deleteSubscription(id) {
    const response = await fetch(`/push_subscriptions/${id}`, {
      method: "DELETE",
      headers: {
        "Content-Type": "application/json"
      }
    })

    if (!response.ok && response.status !== 404) {
      throw new Error("Failed to delete subscription")
    }
  }

  getVapidPublicKey() {
    const metaTag = document.querySelector('meta[name="vapid-public-key"]')
    return metaTag?.content
  }

  // Convert VAPID key from base64url to Uint8Array for applicationServerKey
  urlBase64ToUint8Array(base64String) {
    const padding = "=".repeat((4 - (base64String.length % 4)) % 4)
    const base64 = (base64String + padding)
      .replace(/-/g, "+")
      .replace(/_/g, "/")

    const rawData = window.atob(base64)
    const outputArray = new Uint8Array(rawData.length)

    for (let i = 0; i < rawData.length; ++i) {
      outputArray[i] = rawData.charCodeAt(i)
    }
    return outputArray
  }

  // Convert ArrayBuffer to base64 for sending to server
  arrayBufferToBase64(buffer) {
    const bytes = new Uint8Array(buffer)
    let binary = ""
    for (let i = 0; i < bytes.byteLength; i++) {
      binary += String.fromCharCode(bytes[i])
    }
    return window.btoa(binary)
  }

  async updateUI() {
    // Update button UI if present
    if (this.hasButtonTarget) {
      await this.updateButtonUI()
    }

    // Update toggle UI if present
    if (this.hasToggleTarget) {
      await this.updateToggleUI()
    }
  }

  async updateButtonUI() {
    if (!this.isPushSupported()) {
      this.buttonTarget.textContent = "Notifications not supported"
      this.buttonTarget.disabled = true
      return
    }

    const permission = Notification.permission
    const registration = await navigator.serviceWorker.getRegistration()
    const subscription = registration ? await registration.pushManager?.getSubscription() : null

    if (permission === "denied") {
      this.buttonTarget.textContent = "Notifications blocked"
      this.buttonTarget.disabled = true
      this.buttonTarget.classList.add("opacity-50", "cursor-not-allowed")
    } else if (subscription) {
      this.buttonTarget.textContent = "Disable Notifications"
      this.buttonTarget.disabled = false
      this.buttonTarget.dataset.action = "push-subscription#unsubscribe"
      this.buttonTarget.classList.remove("opacity-50", "cursor-not-allowed")
    } else {
      this.buttonTarget.textContent = "Enable Notifications"
      this.buttonTarget.disabled = false
      this.buttonTarget.dataset.action = "push-subscription#subscribe"
      this.buttonTarget.classList.remove("opacity-50", "cursor-not-allowed")
    }
  }

  async updateToggleUI() {
    // Show not supported message if push isn't available
    if (!this.isPushSupported()) {
      this.toggleTarget.disabled = true
      this.toggleTarget.classList.add("opacity-50", "cursor-not-allowed")
      if (this.hasNotSupportedMessageTarget) {
        this.notSupportedMessageTarget.classList.remove("hidden")
      }
      return
    }

    const permission = Notification.permission
    const registration = await navigator.serviceWorker.getRegistration()
    const subscription = registration ? await registration.pushManager?.getSubscription() : null

    // Handle blocked state
    if (permission === "denied") {
      this.setToggleState(false)
      this.toggleTarget.disabled = true
      this.toggleTarget.classList.add("opacity-50", "cursor-not-allowed")
      if (this.hasBlockedMessageTarget) {
        this.blockedMessageTarget.classList.remove("hidden")
      }
      return
    }

    // Hide blocked message if not blocked
    if (this.hasBlockedMessageTarget) {
      this.blockedMessageTarget.classList.add("hidden")
    }

    // Set toggle state based on subscription
    this.toggleTarget.disabled = false
    this.toggleTarget.classList.remove("opacity-50", "cursor-not-allowed")
    this.setToggleState(!!subscription)
  }

  setToggleState(isOn) {
    if (!this.hasToggleTarget) return

    const toggle = this.toggleTarget
    const knob = toggle.querySelector("span")

    toggle.setAttribute("aria-checked", isOn ? "true" : "false")

    if (isOn) {
      toggle.classList.remove("bg-gray-200")
      toggle.classList.add("bg-indigo-600")
      if (knob) {
        knob.classList.remove("translate-x-0")
        knob.classList.add("translate-x-5")
      }
      if (this.hasToggleOnIconTarget && this.hasToggleOffIconTarget) {
        this.toggleOnIconTarget.classList.remove("opacity-0")
        this.toggleOnIconTarget.classList.add("opacity-100")
        this.toggleOffIconTarget.classList.remove("opacity-100")
        this.toggleOffIconTarget.classList.add("opacity-0")
      }
    } else {
      toggle.classList.remove("bg-indigo-600")
      toggle.classList.add("bg-gray-200")
      if (knob) {
        knob.classList.remove("translate-x-5")
        knob.classList.add("translate-x-0")
      }
      if (this.hasToggleOnIconTarget && this.hasToggleOffIconTarget) {
        this.toggleOnIconTarget.classList.remove("opacity-100")
        this.toggleOnIconTarget.classList.add("opacity-0")
        this.toggleOffIconTarget.classList.remove("opacity-0")
        this.toggleOffIconTarget.classList.add("opacity-100")
      }
    }
  }

  showStatus(message, type) {
    if (!this.hasStatusTarget) {
      console.log(`[${type}] ${message}`)
      return
    }

    this.statusTarget.textContent = message
    this.statusTarget.classList.remove("text-green-600", "text-red-600", "text-gray-600")

    if (type === "success") {
      this.statusTarget.classList.add("text-green-600")
    } else if (type === "error") {
      this.statusTarget.classList.add("text-red-600")
    } else {
      this.statusTarget.classList.add("text-gray-600")
    }

    // Clear status after a delay
    setTimeout(() => {
      if (this.hasStatusTarget) {
        this.statusTarget.textContent = ""
      }
    }, 5000)
  }
}
