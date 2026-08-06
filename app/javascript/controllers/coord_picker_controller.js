import { Controller } from "@hotwired/stimulus"

const LEAFLET_CSS = "/vendor/leaflet/leaflet.css"
const LEAFLET_JS = "/vendor/leaflet/leaflet.js"
const LEAFLET_CSS_FALLBACK = "https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.css"
const LEAFLET_JS_FALLBACK = "https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.js"
const TRINIDAD_CENTER = [10.6549, -61.5019]
const DEFAULT_ZOOM = 11
const PIN_ZOOM = 15

export default class extends Controller {
  static targets = ["map", "lat", "lng"]

  connect() {
    this._destroyed = false
    this._syncing = false
    this.boot()
  }

  disconnect() {
    this._destroyed = true
    if (this.map) {
      this.map.remove()
      this.map = null
    }
  }

  latChanged() {
    this.applyInputsToMarker()
  }

  lngChanged() {
    this.applyInputsToMarker()
  }

  async boot() {
    try {
      await this.ensureLeaflet()
      if (this._destroyed) return
      this.initMap()
    } catch (error) {
      console.error("Coord picker map failed", error)
    }
  }

  ensureLeafletCss(href = LEAFLET_CSS) {
    const marker = href.includes("jsdelivr") ? "cdn" : "local"
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
        if (window.L) return resolve(window.L)
        existing.addEventListener("load", () => (window.L ? resolve(window.L) : reject(new Error("Leaflet missing"))), { once: true })
        existing.addEventListener("error", () => reject(new Error("Leaflet script error")), { once: true })
        return
      }

      const script = document.createElement("script")
      script.src = src
      script.async = true
      script.dataset.estateLeaflet = "1"
      script.dataset.estateLeafletSrc = src
      script.onload = () => (window.L ? resolve(window.L) : reject(new Error("Leaflet missing")))
      script.onerror = () => reject(new Error(`Leaflet failed: ${src}`))
      document.head.appendChild(script)
    })
  }

  async ensureLeaflet() {
    if (window.L) return window.L
    this.ensureLeafletCss(LEAFLET_CSS)
    try {
      return await this.loadScript(LEAFLET_JS)
    } catch (error) {
      console.warn("Local Leaflet failed, trying CDN", error)
      this.ensureLeafletCss(LEAFLET_CSS_FALLBACK)
      return this.loadScript(LEAFLET_JS_FALLBACK)
    }
  }

  initMap() {
    if (!this.hasMapTarget || !window.L) return

    const start = this.#parsedCoords() || TRINIDAD_CENTER
    const zoom = this.#parsedCoords() ? PIN_ZOOM : DEFAULT_ZOOM

    this.map = L.map(this.mapTarget, {
      zoomControl: false,
      scrollWheelZoom: true
    }).setView(start, zoom)

    L.control.zoom({ position: "bottomright" }).addTo(this.map)

    L.tileLayer("https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png", {
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OSM</a> &copy; <a href="https://carto.com/">CARTO</a>',
      maxZoom: 20
    }).addTo(this.map)

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

    this.marker = L.marker(start, { icon: homeIcon, draggable: true, autoPan: true }).addTo(this.map)

    this.marker.on("dragend", () => {
      const { lat, lng } = this.marker.getLatLng()
      this.#writeInputs(lat, lng)
    })

    this.map.on("click", (event) => {
      this.marker.setLatLng(event.latlng)
      this.#writeInputs(event.latlng.lat, event.latlng.lng)
    })

    // Inputs may already have values — keep pin in sync / clear write if empty.
    if (this.#parsedCoords()) {
      this.#writeInputs(start[0], start[1])
    }

    requestAnimationFrame(() => this.map?.invalidateSize())
    window.setTimeout(() => this.map?.invalidateSize(), 200)
  }

  applyInputsToMarker() {
    if (!this.marker || this._syncing) return
    const coords = this.#parsedCoords()
    if (!coords) return
    this.marker.setLatLng(coords)
    this.map.setView(coords, Math.max(this.map.getZoom(), PIN_ZOOM))
  }

  #parsedCoords() {
    if (!this.hasLatTarget || !this.hasLngTarget) return null
    const lat = Number.parseFloat(this.latTarget.value)
    const lng = Number.parseFloat(this.lngTarget.value)
    if (!Number.isFinite(lat) || !Number.isFinite(lng)) return null
    if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return null
    return [lat, lng]
  }

  #writeInputs(lat, lng) {
    if (!this.hasLatTarget || !this.hasLngTarget) return
    this._syncing = true
    this.latTarget.value = Number(lat).toFixed(6).replace(/\.?0+$/, "")
    this.lngTarget.value = Number(lng).toFixed(6).replace(/\.?0+$/, "")
    this.latTarget.dispatchEvent(new Event("input", { bubbles: true }))
    this.lngTarget.dispatchEvent(new Event("input", { bubbles: true }))
    this._syncing = false
  }
}
