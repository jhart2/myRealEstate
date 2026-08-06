import { Controller } from "@hotwired/stimulus"

// Commute destination → drive-time estimate for a property listing.
export default class extends Controller {
  static targets = [
    "compose", "result", "resultLabel", "resultTime", "input", "status", "clearBtn"
  ]
  static values = {
    lat: Number,
    lng: Number,
    estimateUrl: { type: String, default: "/travel/estimate" }
  }

  connect() {
    this.destination = null
    this.showCompose()
  }

  async destinationSelected(event) {
    const result = event.detail
    if (!result || result.lat == null || result.lng == null) return
    if (!this.hasOrigin()) {
      this.setStatus("Listing location unavailable")
      return
    }

    this.destination = {
      name: result.label || result.name || "Destination",
      lat: Number(result.lat),
      lng: Number(result.lng)
    }

    this.setStatus("Checking travel time…")
    await this.fetchEstimate()
  }

  edit(event) {
    event.preventDefault()
    this.showCompose()
    if (this.hasInputTarget) {
      this.inputTarget.value = this.destination?.name || ""
      this.inputTarget.focus()
      this.inputTarget.select()
    }
  }

  clear(event) {
    event?.preventDefault?.()
    this.destination = null
    if (this.hasInputTarget) this.inputTarget.value = ""
    this.setStatus("")
    this.showCompose()
  }

  async fetchEstimate() {
    if (!this.destination || !this.hasOrigin()) return

    const url = new URL(this.estimateUrlValue, window.location.origin)
    url.searchParams.set("from_lat", this.latValue)
    url.searchParams.set("from_lng", this.lngValue)
    url.searchParams.set("to_lat", this.destination.lat)
    url.searchParams.set("to_lng", this.destination.lng)

    try {
      const response = await fetch(url, { headers: { Accept: "application/json" } })
      const data = await response.json()
      if (!response.ok || data.error) throw new Error(data.error || "estimate_failed")

      this.renderResult(data)
    } catch (_) {
      this.setStatus("Couldn’t estimate travel time. Try another place.")
      this.showCompose()
    }
  }

  renderResult(data) {
    if (this.hasResultLabelTarget) {
      this.resultLabelTarget.textContent = `To ${this.destination.name}`
    }
    if (this.hasResultTimeTarget) {
      this.resultTimeTarget.textContent = this.formatMinutes(data.duration_minutes)
    }
    this.setStatus("")
    this.showResult()
  }

  formatMinutes(minutes) {
    const mins = Math.max(1, Math.round(Number(minutes) || 0))
    if (mins < 60) return `${mins} min${mins === 1 ? "" : "s"}`
    const hours = Math.floor(mins / 60)
    const rem = mins % 60
    if (rem === 0) return `${hours} hr${hours === 1 ? "" : "s"}`
    return `${hours} hr ${rem} min`
  }

  hasOrigin() {
    return Number.isFinite(this.latValue) && Number.isFinite(this.lngValue)
  }

  showCompose() {
    this.composeTarget?.classList.remove("hidden")
    this.resultTarget?.classList.add("hidden")
  }

  showResult() {
    this.composeTarget?.classList.add("hidden")
    this.resultTarget?.classList.remove("hidden")
  }

  setStatus(message) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = message || ""
    this.statusTarget.classList.toggle("hidden", !message)
  }
}
