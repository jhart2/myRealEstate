import { Controller } from "@hotwired/stimulus"

const LEAFLET_CSS = "/vendor/leaflet/leaflet.css"
const LEAFLET_JS = "/vendor/leaflet/leaflet.js"
const LEAFLET_CSS_FALLBACK = "https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.css"
const LEAFLET_JS_FALLBACK = "https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.js"

// Photo ↔ map toggle for the single-property hero banner (mirrors lightbox media tabs).
export default class extends Controller {
  connect() {
    this.ensureLeaflet().catch(() => {})
  }

  disconnect() {
    const mapEl = this.element.querySelector("[data-detail-map]")
    if (mapEl?._leaflet_map) {
      try { mapEl._leaflet_map.remove() } catch (_) { /* ignore */ }
      mapEl._leaflet_map = null
      mapEl._leaflet_marker = null
      mapEl.dataset.ready = "0"
    }
  }

  toggleMedia(event) {
    event.preventDefault()
    const mapPanel = this.element.querySelector('[data-media-panel="map"]')
    const showingMap = mapPanel && !mapPanel.classList.contains("hidden")
    this.#setMediaMode(showingMap ? "photos" : "map")
  }

  #setMediaMode(mode) {
    this.element.querySelectorAll("[data-media-panel]").forEach((el) => {
      el.classList.toggle("hidden", el.dataset.mediaPanel !== mode)
    })

    const tab = this.element.querySelector("[data-media-tab]")
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
      window.requestAnimationFrame(() => this.initDetailMap())
      window.setTimeout(() => this.initDetailMap(), 40)
    }
  }

  async initDetailMap() {
    await this.ensureLeaflet()
    if (!window.L) return

    const mapEl = this.element.querySelector("[data-detail-map]")
    if (!mapEl) return

    const mapPanel = mapEl.closest('[data-media-panel="map"]')
    if (mapPanel?.classList.contains("hidden")) return

    const lat = parseFloat(mapEl.dataset.lat)
    const lng = parseFloat(mapEl.dataset.lng)
    if (Number.isNaN(lat) || Number.isNaN(lng)) return

    if (mapEl.dataset.ready === "1" && mapEl._leaflet_map) {
      this.#syncDetailMap(mapEl._leaflet_map, mapEl._leaflet_marker, lat, lng)
      return
    }

    if (mapEl._leaflet_id) {
      try { mapEl._leaflet_map?.remove?.() } catch (_) { /* ignore */ }
      mapEl._leaflet_id = undefined
      mapEl.innerHTML = ""
    }

    const map = L.map(mapEl, {
      zoomControl: false,
      attributionControl: false,
      scrollWheelZoom: false
    })

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

    const marker = L.marker([lat, lng], { icon: homeIcon, interactive: false }).addTo(map)
    mapEl.dataset.ready = "1"
    mapEl._leaflet_map = map
    mapEl._leaflet_marker = marker
    this.#syncDetailMap(map, marker, lat, lng)
  }

  #syncDetailMap(map, marker, lat, lng) {
    if (!map) return
    const center = [lat, lng]
    if (marker?.setLatLng) marker.setLatLng(center)

    const apply = () => {
      map.invalidateSize({ animate: false })
      map.setView(center, 15, { animate: false })
    }

    apply()
    window.requestAnimationFrame(apply)
    window.setTimeout(apply, 80)
  }

  async ensureLeaflet() {
    if (window.L) return
    this.injectStylesheet(LEAFLET_CSS, "primary")
    try {
      await this.loadScript(LEAFLET_JS)
    } catch (_) {
      this.injectStylesheet(LEAFLET_CSS_FALLBACK, "fallback")
      await this.loadScript(LEAFLET_JS_FALLBACK)
    }
  }

  injectStylesheet(href, marker) {
    if (document.querySelector(`link[data-estate-leaflet-css="${marker}"]`)) return
    const link = document.createElement("link")
    link.rel = "stylesheet"
    link.href = href
    link.dataset.estateLeafletCss = marker
    document.head.appendChild(link)
  }

  loadScript(src) {
    return new Promise((resolve, reject) => {
      const existing = document.querySelector(`script[data-estate-leaflet-src="${src}"]`)
      if (existing) {
        if (window.L) return resolve()
        existing.addEventListener("load", () => resolve(), { once: true })
        existing.addEventListener("error", () => reject(new Error("Leaflet load failed")), { once: true })
        return
      }
      const script = document.createElement("script")
      script.src = src
      script.async = true
      script.dataset.estateLeafletSrc = src
      script.onload = () => resolve()
      script.onerror = () => reject(new Error("Leaflet load failed"))
      document.head.appendChild(script)
    })
  }
}
