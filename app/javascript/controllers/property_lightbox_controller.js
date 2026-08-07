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
    this.onFrameMissing = this.onFrameMissing.bind(this)

    // Delegate on the controller root so listeners survive Turbo replacing the frame element.
    this.element.addEventListener("turbo:frame-load", this.onFrameLoad)
    this.element.addEventListener("turbo:frame-missing", this.onFrameMissing)
    document.addEventListener("keydown", this.onKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
    this.element.removeEventListener("turbo:frame-load", this.onFrameLoad)
    this.element.removeEventListener("turbo:frame-missing", this.onFrameMissing)
    this.unlockScroll()
  }

  open(event) {
    // Cmd/Ctrl/Shift/middle-click → let the browser open the full property page.
    if (!this.#isPrimaryActivation(event)) return

    const url = event.currentTarget.getAttribute("href")
    if (!url || !this.hasFrameTarget) return

    // Intercept before Turbo Drive can fall through to a full-page visit when the
    // frame redirector fails to claim the click (missing FrameElement upgrade, etc.).
    event.preventDefault()

    this.showOverlay()
    this.#loadIntoFrame(url)
  }

  onFrameLoad(event) {
    if (!this.hasFrameTarget || event.target !== this.frameTarget) return

    if (!this.frameHasContent()) {
      this.close()
      return
    }

    this.showOverlay()
    this.initDetailMap()
  }

  onFrameMissing(event) {
    if (!this.hasFrameTarget || event.target !== this.frameTarget) return

    // Never let a missing-frame response navigate away from search.
    event.preventDefault()
    this.close()
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
      if (this.hasFrameTarget) {
        this.frameTarget.removeAttribute("src")
        this.frameTarget.innerHTML = ""
      }
      this.unlockScroll()
    }, 180)
  }

  stop(event) {
    event.stopPropagation()
  }

  closeOnBackdrop(event) {
    if (event.target === this.overlayTarget) this.close(event)
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
    this.#setMediaMode(panel, mode)
  }

  toggleMedia(event) {
    event.preventDefault()
    const panel = event.currentTarget.closest("[data-property-lightbox-detail]")
    if (!panel) return
    const mapPanel = panel.querySelector('[data-media-panel="map"]')
    const showingMap = mapPanel && !mapPanel.classList.contains("hidden")
    this.#setMediaMode(panel, showingMap ? "photos" : "map")
  }

  #setMediaMode(panel, mode) {
    panel.querySelectorAll("[data-media-panel]").forEach((el) => {
      el.classList.toggle("hidden", el.dataset.mediaPanel !== mode)
    })

    const tab = panel.querySelector("[data-media-tab]")
    if (tab) {
      const mapIcon = tab.querySelector('[data-icon="map"]')
      const photosIcon = tab.querySelector('[data-icon="photos"]')
      const showingMap = mode === "map"
      mapIcon?.classList.toggle("hidden", showingMap)
      photosIcon?.classList.toggle("hidden", !showingMap)
      tab.classList.toggle("is-active", showingMap)
      tab.setAttribute("aria-selected", showingMap ? "true" : "false")
      tab.setAttribute("aria-label", showingMap ? "Show photos" : "Show map")
    }

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

  promptSignIn(event) {
    event.preventDefault()
    document.dispatchEvent(new CustomEvent("auth-modal:open", { detail: { mode: "login", intent: "save" } }))
  }

  onKeydown(event) {
    if (event.key !== "Escape" || !this.openValue) return
    // Auth modal (higher overlay) owns Escape while open.
    if (document.documentElement.classList.contains("auth-modal-open")) return
    this.close()
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

    const homeIcon = L.divIcon({
      className: "listing-home-marker",
      iconSize: [36, 44],
      iconAnchor: [18, 42],
      html: `
        <span class="listing-home-marker-pin" aria-hidden="true">
          <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <path d="M3 10.5 12 3l9 7.5"/>
            <path d="M5 10.5V20a1 1 0 0 0 1 1h4v-6h4v6h4a1 1 0 0 0 1-1v-9.5"/>
          </svg>
        </span>
      `
    })

    L.marker([lat, lng], { icon: homeIcon, interactive: false }).addTo(map)

    mapEl.dataset.ready = "1"
    mapEl._leaflet_map = map
    window.setTimeout(() => map.invalidateSize(), 80)
  }

  #isPrimaryActivation(event) {
    if (event.defaultPrevented) return false
    if (typeof event.button === "number" && event.button !== 0) return false
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return false
    return true
  }

  #loadIntoFrame(url) {
    if (!this.hasFrameTarget) return

    const frame = this.frameTarget
    const next = new URL(url, window.location.href).href
    const currentAttr = frame.getAttribute("src")
    const current = currentAttr ? new URL(currentAttr, window.location.href).href : ""

    if (current === next) {
      // Re-open the same listing: force a reload so turbo:frame-load fires again.
      if (typeof frame.reload === "function") {
        frame.reload()
      } else {
        frame.removeAttribute("src")
        frame.src = url
      }
      return
    }

    frame.src = url
  }
}
