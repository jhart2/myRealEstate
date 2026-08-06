import { Controller } from "@hotwired/stimulus"

// Search-page property detail lightbox (Zillow-style overlay).
export default class extends Controller {
  static targets = ["overlay", "frame", "shareNote"]
  static values = {
    open: { type: Boolean, default: false }
  }

  connect() {
    this.onKeydown = this.onKeydown.bind(this)
    this.onFrameLoad = this.onFrameLoad.bind(this)
    this.frameTarget?.addEventListener("turbo:frame-load", this.onFrameLoad)
    document.addEventListener("keydown", this.onKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
    this.frameTarget?.removeEventListener("turbo:frame-load", this.onFrameLoad)
    this.unlockScroll()
  }

  open(event) {
    // Let Turbo fill the frame; reveal overlay immediately for feedback
    this.showOverlay()
  }

  onFrameLoad() {
    if (!this.frameHasContent()) {
      this.close()
      return
    }
    this.showOverlay()
    this.initDetailMap()
  }

  showOverlay() {
    if (!this.hasOverlayTarget) return
    this.openValue = true
    this.overlayTarget.classList.remove("hidden")
    this.overlayTarget.setAttribute("aria-hidden", "false")
    this.lockScroll()
    window.requestAnimationFrame(() => {
      this.overlayTarget.classList.add("is-open")
    })
  }

  close(event) {
    event?.preventDefault?.()
    if (!this.hasOverlayTarget) return

    this.openValue = false
    this.overlayTarget.classList.remove("is-open")
    this.overlayTarget.setAttribute("aria-hidden", "true")

    window.setTimeout(() => {
      this.overlayTarget.classList.add("hidden")
      if (this.hasFrameTarget) this.frameTarget.innerHTML = ""
      this.unlockScroll()
    }, 180)
  }

  stop(event) {
    event.stopPropagation()
  }

  closeOnBackdrop(event) {
    if (event.target === this.overlayTarget) this.close(event)
  }

  onKeydown(event) {
    if (event.key === "Escape" && this.openValue) this.close()
  }

  frameHasContent() {
    return this.hasFrameTarget && this.frameTarget.childElementCount > 0
  }

  lockScroll() {
    document.documentElement.classList.add("lightbox-open")
  }

  unlockScroll() {
    document.documentElement.classList.remove("lightbox-open")
  }

  showMedia(event) {
    event.preventDefault()
    const panel = event.currentTarget.closest("[data-property-lightbox-detail]")
    if (!panel) return
    const mode = event.currentTarget.dataset.media
    panel.querySelectorAll("[data-media-panel]").forEach((el) => {
      el.classList.toggle("hidden", el.dataset.mediaPanel !== mode)
    })
    panel.querySelectorAll("[data-media-tab]").forEach((el) => {
      el.classList.toggle("is-active", el.dataset.media === mode)
    })
    if (mode === "map") {
      window.setTimeout(() => this.initDetailMap(panel), 40)
    }
  }

  async share(event) {
    event.preventDefault()
    const url = event.currentTarget.dataset.shareUrl || window.location.href
    const title = event.currentTarget.dataset.shareTitle || "Property listing"

    try {
      if (navigator.share) {
        await navigator.share({ title, url })
        return
      }
      await navigator.clipboard.writeText(url)
      this.flashShare("Link copied")
    } catch (_) {
      this.flashShare("Couldn’t share")
    }
  }

  flashShare(message) {
    const note = this.overlayTarget.querySelector("[data-share-note]")
    if (!note) return
    note.textContent = message
    note.classList.remove("hidden")
    window.clearTimeout(this._shareTimer)
    this._shareTimer = window.setTimeout(() => note.classList.add("hidden"), 1800)
  }

  initDetailMap(root = this.overlayTarget) {
    if (!window.L || !root) return
    const mapEl = root.querySelector("[data-detail-map]")
    if (!mapEl || mapEl.dataset.ready === "1") {
      if (mapEl?._leaflet_map) {
        mapEl._leaflet_map.invalidateSize()
      }
      return
    }

    const lat = parseFloat(mapEl.dataset.lat)
    const lng = parseFloat(mapEl.dataset.lng)
    if (Number.isNaN(lat) || Number.isNaN(lng)) return

    const map = L.map(mapEl, {
      zoomControl: false,
      attributionControl: false,
      scrollWheelZoom: false
    }).setView([lat, lng], 15)

    L.tileLayer("https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png", {
      maxZoom: 19
    }).addTo(map)

    L.circleMarker([lat, lng], {
      radius: 9,
      color: "#fff",
      weight: 2,
      fillColor: "#c23b3b",
      fillOpacity: 1
    }).addTo(map)

    mapEl.dataset.ready = "1"
    mapEl._leaflet_map = map
    window.setTimeout(() => map.invalidateSize(), 80)
  }
}
