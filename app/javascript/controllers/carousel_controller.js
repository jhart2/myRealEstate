import { Controller } from "@hotwired/stimulus"

// Horizontal listing carousel (Airbnb-style regional rows).
export default class extends Controller {
  static targets = ["track", "prev", "next"]

  connect() {
    this.onScroll = () => this.updateButtons()
    this.trackTarget.addEventListener("scroll", this.onScroll, { passive: true })
    this.updateButtons()
    requestAnimationFrame(() => this.updateButtons())
  }

  disconnect() {
    this.trackTarget.removeEventListener("scroll", this.onScroll)
  }

  prev() {
    this.scrollBy(-this.scrollStep())
  }

  next() {
    this.scrollBy(this.scrollStep())
  }

  scrollBy(delta) {
    this.trackTarget.scrollBy({ left: delta, behavior: "smooth" })
  }

  scrollStep() {
    const track = this.trackTarget
    const card = track.querySelector("[data-carousel-card]")
    if (!card) return track.clientWidth * 0.8

    const style = getComputedStyle(track)
    const gap = parseFloat(style.columnGap || style.gap || "16") || 16
    return (card.getBoundingClientRect().width + gap) * Math.max(1, Math.floor(track.clientWidth / (card.getBoundingClientRect().width + gap)))
  }

  updateButtons() {
    const track = this.trackTarget
    const max = track.scrollWidth - track.clientWidth
    const atStart = track.scrollLeft <= 4
    const atEnd = track.scrollLeft >= max - 4 || max <= 4

    if (this.hasPrevTarget) {
      this.prevTarget.disabled = atStart
      this.prevTarget.setAttribute("aria-disabled", atStart ? "true" : "false")
    }
    if (this.hasNextTarget) {
      this.nextTarget.disabled = atEnd
      this.nextTarget.setAttribute("aria-disabled", atEnd ? "true" : "false")
    }
  }
}
