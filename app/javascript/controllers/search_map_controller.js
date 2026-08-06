import { Controller } from "@hotwired/stimulus"

const LEAFLET_CSS = "/vendor/leaflet/leaflet.css"
const LEAFLET_JS = "/vendor/leaflet/leaflet.js"
const LEAFLET_CSS_FALLBACK = "https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.css"
const LEAFLET_JS_FALLBACK = "https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.js"
const TRINIDAD_CENTER = [10.6549, -61.5019]
const BASEMAP_STORAGE_KEY = "estate-map-basemap"
const BASEMAPS = {
  streets: {
    label: "Streets",
    layers: [
      {
        url: "https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png",
        attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OSM</a> &copy; <a href="https://carto.com/">CARTO</a>',
        maxZoom: 20
      },
      {
        url: "https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png",
        attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
        maxZoom: 19
      }
    ]
  },
  satellite: {
    label: "Satellite",
    layers: [
      {
        url: "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}",
        attribution: "Tiles &copy; Esri",
        maxZoom: 19
      }
    ]
  },
  terrain: {
    label: "Terrain",
    layers: [
      {
        url: "https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png",
        attribution: '&copy; <a href="https://opentopomap.org">OpenTopoMap</a> (<a href="https://creativecommons.org/licenses/by-sa/3.0/">CC-BY-SA</a>)',
        maxZoom: 17
      }
    ]
  },
  dark: {
    label: "Dark",
    layers: [
      {
        url: "https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png",
        attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OSM</a> &copy; <a href="https://carto.com/">CARTO</a>',
        maxZoom: 20
      }
    ]
  }
}

export default class extends Controller {
  static targets = [
    "map", "listPane", "mapPane", "listTab", "mapTab", "card", "listScroll",
    "form", "north", "south", "east", "west", "areaButton", "spinner", "basemapButton"
  ]
  static values = { listings: Array, boundary: Object, viewport: Object }

  connect() {
    this.markersById = {}
    this.activeId = null
    this.mapMoved = false
    this.userMovedMap = false
    this._destroyed = false
    this._programmaticFrame = false

    this.showSpinner()

    if (this.isMobile()) {
      this.showList()
    }

    this.bootMap()
  }

  async bootMap() {
    try {
      await this.ensureLeaflet()
      if (this._destroyed) return
      this.initMap()
    } catch (error) {
      console.error("Map init failed", error)
      this.teardownMap()
      this.showSpinnerError("Map failed to load. Retrying…")
      try {
        await this.ensureLeaflet({ useFallback: true })
        if (this._destroyed) return
        this.initMap()
      } catch (retryError) {
        console.error("Map retry failed", retryError)
        this.teardownMap()
        this.showSpinnerError("Could not load the map. Refresh the page.")
      }
    }
  }

  teardownMap() {
    this.clearSearchBoundary()
    if (this.map) {
      try { this.map.remove() } catch (_) { /* already gone */ }
      this.map = null
    }
    this.markerLayer = null
  }

  disconnect() {
    this._destroyed = true
    if (this._resizeObserver) {
      this._resizeObserver.disconnect()
      this._resizeObserver = null
    }
    this.teardownMap()
  }

  isMobile() {
    return window.matchMedia("(max-width: 1023px)").matches
  }

  showSpinner() {
    if (!this.hasSpinnerTarget) return
    this.spinnerTarget.classList.remove("hidden")
    this.spinnerTarget.dataset.state = "loading"
    const label = this.spinnerTarget.querySelector("[data-search-map-spinner-label]")
    if (label) label.textContent = "Loading map…"
  }

  showSpinnerError(message) {
    if (!this.hasSpinnerTarget) return
    this.spinnerTarget.classList.remove("hidden")
    this.spinnerTarget.dataset.state = "error"
    const label = this.spinnerTarget.querySelector("[data-search-map-spinner-label]")
    if (label) label.textContent = message
  }

  hideSpinner() {
    if (!this.hasSpinnerTarget) return
    this.spinnerTarget.classList.add("hidden")
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
        existing.addEventListener("load", () => (window.L ? resolve(window.L) : reject(new Error("Leaflet missing after load"))), { once: true })
        existing.addEventListener("error", () => reject(new Error("Leaflet script error")), { once: true })
        window.setTimeout(() => (window.L ? resolve(window.L) : reject(new Error("Leaflet load timeout"))), 8000)
        return
      }

      const script = document.createElement("script")
      script.src = src
      script.async = true
      script.dataset.estateLeaflet = "1"
      script.dataset.estateLeafletSrc = src
      script.onload = () => (window.L ? resolve(window.L) : reject(new Error("Leaflet missing after load")))
      script.onerror = () => reject(new Error(`Leaflet failed to download: ${src}`))
      document.head.appendChild(script)
      window.setTimeout(() => (window.L ? resolve(window.L) : reject(new Error("Leaflet load timeout"))), 10000)
    })
  }

  async ensureLeaflet({ force = false, useFallback = false } = {}) {
    if (window.L && !force) return window.L

    if (useFallback) {
      this.ensureLeafletCss(LEAFLET_CSS_FALLBACK)
      return this.loadScript(LEAFLET_JS_FALLBACK)
    }

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
    if (!this.hasMapTarget || !window.L) {
      throw new Error("Map target or Leaflet unavailable")
    }

    try {
      if (this.map) {
        this.map.remove()
        this.map = null
      }

      // Leaflet default icon paths when CSS is served from /vendor/leaflet/
      if (L.Icon?.Default) {
        L.Icon.Default.mergeOptions({
          iconUrl: "/vendor/leaflet/images/marker-icon.png",
          iconRetinaUrl: "/vendor/leaflet/images/marker-icon-2x.png",
          shadowUrl: "/vendor/leaflet/images/marker-shadow.png"
        })
      }

      this.map = L.map(this.mapTarget, {
        zoomControl: false,
        scrollWheelZoom: true
      })

      L.control.zoom({ position: "bottomright" }).addTo(this.map)

      this.activeBasemap = this.storedBasemap()
      this.setBasemapLayer(this.activeBasemap, { showSpinner: true, layerIndex: 0 })
      this.syncBasemapButtons()

      this.markerLayer = L.layerGroup().addTo(this.map)
      this.renderMarkers()

      this.suppressAreaButton = true
      this.clearSearchBoundary()
      this.applyInitialFrame()

      this.map.on("dragstart", () => {
        if (this._programmaticFrame) return
        this.userMovedMap = true
      })
      this.map.on("zoomstart", () => {
        if (this._programmaticFrame) return
        this.userMovedMap = true
      })

      this.map.on("moveend", () => {
        if (this.userMovedMap && this.hasAreaButtonTarget) {
          this.areaButtonTarget.classList.remove("hidden")
          this.areaButtonTarget.classList.add("is-visible")
        }

        if (this.suppressAreaButton) {
          this.suppressAreaButton = false
        }
      })

      this.watchSize()
      this.scheduleResize({ reframe: true })
    } catch (error) {
      console.error("initMap failed", error)
      this.teardownMap()
      this.showSpinnerError("Could not load the map. Refresh the page.")
      throw error
    }
  }

  applyInitialFrame() {
    if (this.hasExactBoundary()) {
      this.drawExactBoundary()
      this.fitToExactBoundaryAndListings()
      this.initialFrame = "boundary"
    } else if (this.hasViewportBounds()) {
      // Geocoded / autocomplete frame — center on the place, not listing coords
      this.fitToViewportBounds()
      this.initialFrame = "viewport"
    } else if (this.hasUrlBounds()) {
      // Viewport search without location text — never invent an outline
      this.fitToViewportBounds(this.urlBounds())
      this.initialFrame = "url"
    } else {
      this.centerOnTopListing()
      this.initialFrame = "top"
    }
  }

  hasExactBoundary() {
    const boundary = this.boundaryValue
    if (!boundary || typeof boundary !== "object") return false
    const geometry = boundary.geometry || boundary
    return geometry && ["Polygon", "MultiPolygon"].includes(geometry.type)
  }

  drawExactBoundary() {
    if (!this.map || !window.L || !this.hasExactBoundary()) return

    this.clearSearchBoundary()

    this.searchBoundary = L.geoJSON(this.boundaryValue, {
      className: "estate-search-boundary",
      style: {
        color: "#ea7a2f",
        weight: 2.5,
        opacity: 1,
        dashArray: null,
        fill: false,
        fillOpacity: 0
      },
      interactive: false
    }).addTo(this.map)
  }

  fitToExactBoundaryAndListings() {
    if (!this.map || !this.searchBoundary) {
      this.fitToListings()
      return
    }

    const boundaryBounds = this.searchBoundary.getBounds()
    const inside = this.listingsValue.filter((listing) => {
      if (listing.lat == null || listing.lng == null) return false
      return boundaryBounds.contains([listing.lat, listing.lng])
    })

    let fitTarget = boundaryBounds
    if (inside.length >= 1) {
      const points = inside.map((l) => L.latLng(l.lat, l.lng))
      const listingBounds = L.latLngBounds(points)
      fitTarget = boundaryBounds.extend(listingBounds)
    }

    try {
      this.map.fitBounds(fitTarget, {
        padding: [48, 48],
        maxZoom: 14,
        animate: false
      })
    } catch (error) {
      console.warn("fitBounds failed", error)
      this.fitToListings()
    }
  }

  hasViewportBounds() {
    return Boolean(this.normalizedViewport(this.viewportValue))
  }

  normalizedViewport(raw) {
    if (!raw || typeof raw !== "object") return null
    const south = parseFloat(raw.south)
    const west = parseFloat(raw.west)
    const north = parseFloat(raw.north)
    const east = parseFloat(raw.east)
    if ([south, west, north, east].some((n) => Number.isNaN(n))) return null
    if (south >= north || west >= east) return null
    return { south, west, north, east }
  }

  fitToViewportBounds(bounds = this.normalizedViewport(this.viewportValue) || this.urlBounds()) {
    if (!this.map || !bounds) {
      this.fitToListings()
      return
    }

    const span = Math.max(bounds.north - bounds.south, bounds.east - bounds.west)
    const center = this.viewportCenter(bounds)

    // Named / geocoded place: lock dead-center at a close zoom (don't frame huge pads).
    if (center) {
      const zoom = span < 0.04 ? 16 : span < 0.08 ? 15 : span < 0.16 ? 14 : 13
      try {
        this.map.setView([center.lat, center.lng], zoom, { animate: false })
        return
      } catch (error) {
        console.warn("setView viewport failed", error)
      }
    }

    const maxZoom = span < 0.03 ? 16 : span < 0.06 ? 15 : span < 0.12 ? 14 : 13

    try {
      this.map.fitBounds(
        [[bounds.south, bounds.west], [bounds.north, bounds.east]],
        { padding: [28, 28], maxZoom, animate: false }
      )
    } catch (error) {
      console.warn("fitToViewportBounds failed", error)
      this.fitToListings()
    }
  }

  viewportCenter(bounds) {
    const raw = this.viewportValue
    if (raw && typeof raw === "object") {
      const lat = parseFloat(raw.lat)
      const lng = parseFloat(raw.lng)
      if (!Number.isNaN(lat) && !Number.isNaN(lng)) return { lat, lng }
    }
    if (!bounds) return null
    return {
      lat: (bounds.north + bounds.south) / 2,
      lng: (bounds.east + bounds.west) / 2
    }
  }

  hasUrlBounds() {
    if (!this.hasNorthTarget) return false
    return [this.northTarget, this.southTarget, this.eastTarget, this.westTarget]
      .every((field) => field.value && field.value.trim() !== "")
  }

  urlBounds() {
    if (!this.hasUrlBounds()) return null

    const south = parseFloat(this.southTarget.value)
    const west = parseFloat(this.westTarget.value)
    const north = parseFloat(this.northTarget.value)
    const east = parseFloat(this.eastTarget.value)
    if ([south, west, north, east].some((n) => Number.isNaN(n))) return null
    if (south >= north || west >= east) return null

    return { south, west, north, east }
  }

  clearSearchBoundary() {
    if (this.searchBoundary) {
      this.map?.removeLayer(this.searchBoundary)
      this.searchBoundary = null
    }
  }

  storedBasemap() {
    try {
      const saved = window.localStorage?.getItem(BASEMAP_STORAGE_KEY)
      if (saved && BASEMAPS[saved]) return saved
    } catch (_) { /* private mode */ }
    return "streets"
  }

  setBasemap(event) {
    event.preventDefault()
    const id = event.currentTarget.dataset.basemap
    if (!id || !BASEMAPS[id] || id === this.activeBasemap) return
    this.activeBasemap = id
    try {
      window.localStorage?.setItem(BASEMAP_STORAGE_KEY, id)
    } catch (_) { /* private mode */ }
    this.setBasemapLayer(id, { showSpinner: false, layerIndex: 0 })
    this.syncBasemapButtons()
  }

  syncBasemapButtons() {
    if (!this.hasBasemapButtonTarget) return
    this.basemapButtonTargets.forEach((button) => {
      const active = button.dataset.basemap === this.activeBasemap
      button.classList.toggle("is-active", active)
      button.setAttribute("aria-pressed", active ? "true" : "false")
    })
  }

  setBasemapLayer(basemapId, { showSpinner = false, layerIndex = 0 } = {}) {
    if (!this.map || !window.L) return

    const config = BASEMAPS[basemapId] || BASEMAPS.streets
    const layers = config.layers || []
    const layerConfig = layers[layerIndex]
    if (!layerConfig) {
      if (basemapId !== "streets") {
        this.setBasemapLayer("streets", { showSpinner, layerIndex: 0 })
      } else {
        this.hideSpinner()
      }
      return
    }

    if (this.tileLayer) {
      this.map.removeLayer(this.tileLayer)
      this.tileLayer = null
    }

    if (showSpinner) this.showSpinner()

    let settled = false
    const finish = () => {
      if (settled || this._destroyed) return
      settled = true
      this.hideSpinner()
      this.scheduleResize()
    }

    this.tileLayer = L.tileLayer(layerConfig.url, {
      maxZoom: layerConfig.maxZoom || 19,
      attribution: layerConfig.attribution || ""
    })

    this.tileLayer.on("load", finish)
    this.tileLayer.on("tileerror", () => {
      if (settled) return
      if (layerIndex + 1 < layers.length) {
        this.setBasemapLayer(basemapId, { showSpinner, layerIndex: layerIndex + 1 })
      } else if (basemapId !== "streets") {
        this.setBasemapLayer("streets", { showSpinner, layerIndex: 0 })
      } else {
        finish()
      }
    })

    this.tileLayer.addTo(this.map)
    this.tileLayer.bringToBack()

    if (showSpinner) window.setTimeout(finish, 2500)
    else window.setTimeout(finish, 1200)
  }

  watchSize() {
    if (!this.hasMapPaneTarget || typeof ResizeObserver === "undefined") return
    this._resizeObserver?.disconnect()
    this._resizeObserver = new ResizeObserver(() => this.scheduleResize())
    this._resizeObserver.observe(this.mapPaneTarget)
  }

  scheduleResize({ reframe = false } = {}) {
    if (!this.map) return
    requestAnimationFrame(() => {
      this.map?.invalidateSize({ animate: false })
      // Second pass after layout settles (common Leaflet blank-map fix)
      window.setTimeout(() => {
        if (!this.map) return
        this.map.invalidateSize({ animate: false })
        if (reframe && !this.userMovedMap) this.reapplyInitialFrame()
      }, 150)
    })
  }

  reapplyInitialFrame() {
    if (this.initialFrame === "top") {
      this.centerOnTopListing()
    } else if (this.initialFrame === "viewport") {
      this.fitToViewportBounds()
    } else if (this.initialFrame === "url") {
      this.fitToViewportBounds(this.urlBounds())
    } else if (this.initialFrame === "boundary" && this.hasExactBoundary()) {
      this.clearSearchBoundary()
      this.drawExactBoundary()
      this.fitToExactBoundaryAndListings()
    }
  }

  renderMarkers() {
    if (!this.markerLayer) return
    this.markerLayer.clearLayers()
    this.markersById = {}

    this.listingsValue.forEach((listing) => {
      if (listing.lat == null || listing.lng == null) return

      const icon = L.divIcon({
        className: "estate-price-marker",
        html: `<button type="button" class="price-pill" data-id="${listing.id}">${listing.priceLabel}</button>`,
        iconSize: [70, 28],
        iconAnchor: [35, 14]
      })

      const marker = L.marker([listing.lat, listing.lng], { icon, riseOnHover: true })
      marker.listingId = listing.id

      marker.bindPopup(this.popupHtml(listing), {
        className: "estate-map-popup",
        maxWidth: 286,
        minWidth: 286,
        offset: [0, -10],
        autoPanPadding: [24, 24]
      })

      marker.on("click", () => this.activateListing(listing.id, { scroll: true, openPopup: false }))
      marker.on("mouseover", () => this.activateListing(listing.id, { scroll: false, openPopup: false }))

      marker.addTo(this.markerLayer)
      this.markersById[listing.id] = marker
    })
  }

  popupHtml(listing) {
    const image = listing.image
      ? `<img src="${listing.image}" alt="" class="popup-image">`
      : `<div class="popup-image popup-image--empty"></div>`

    const stats = []
    if (listing.beds > 0) {
      stats.push(`<span class="popup-stat"><strong>${listing.beds}</strong> bds</span>`)
    }
    if (listing.baths > 0) {
      stats.push(`<span class="popup-stat"><strong>${listing.baths}</strong> ba</span>`)
    }
    if (listing.sqftLabel) {
      stats.push(`<span class="popup-stat"><strong>${listing.sqftLabel}</strong> sqft</span>`)
    }
    stats.push(`<span class="popup-stat">${listing.statusLabel || listing.tag}</span>`)

    return `
      <a href="${listing.url}"
         class="popup-card"
         data-turbo-frame="property_lightbox"
         data-action="click->property-lightbox#open">
        <div class="popup-media">
          ${image}
          <div class="popup-dots" aria-hidden="true">
            <span class="is-active"></span>
            <span></span>
            <span></span>
            <span></span>
          </div>
        </div>
        <div class="popup-data">
          <div class="popup-price-row">
            <p class="popup-price">${listing.price}</p>
            <span class="popup-more" aria-hidden="true">
              <span></span><span></span><span></span>
            </span>
          </div>
          <p class="popup-stats">${stats.join('<span class="popup-sep" aria-hidden="true"></span>')}</p>
          <p class="popup-address">${listing.address}</p>
        </div>
      </a>
    `
  }

  withProgrammaticFrame(fn) {
    this._programmaticFrame = true
    try {
      fn()
    } finally {
      window.setTimeout(() => { this._programmaticFrame = false }, 0)
    }
  }

  centerOnTopListing({ zoom = 14 } = {}) {
    if (!this.map) return

    const listing = this.listingsValue.find((item) => {
      const lat = Number(item.lat)
      const lng = Number(item.lng)
      return Number.isFinite(lat) && Number.isFinite(lng)
    })
    if (!listing) {
      this.withProgrammaticFrame(() => this.map.setView(TRINIDAD_CENTER, 10))
      return
    }

    const lat = Number(listing.lat)
    const lng = Number(listing.lng)

    try {
      this.withProgrammaticFrame(() => {
        this.map.setView([lat, lng], zoom, { animate: false })
      })
    } catch (error) {
      console.warn("centerOnTopListing failed", error)
      this.fitToListings()
    }
  }

  fitToListings() {
    const points = this.listingsValue
      .filter((l) => l.lat != null && l.lng != null)
      .map((l) => [l.lat, l.lng])

    if (!this.map) return

    if (points.length === 0) {
      this.map.setView(TRINIDAD_CENTER, 10)
      return
    }

    if (points.length === 1) {
      this.map.setView(points[0], 13)
      return
    }

    this.map.fitBounds(points, { padding: [48, 48], maxZoom: 12 })
  }

  syncBoundsFields() {
    if (!this.map) return
    const bounds = this.map.getBounds()
    this.northTarget.value = bounds.getNorth().toFixed(6)
    this.southTarget.value = bounds.getSouth().toFixed(6)
    this.eastTarget.value = bounds.getEast().toFixed(6)
    this.westTarget.value = bounds.getWest().toFixed(6)
  }

  searchArea(event) {
    event.preventDefault()
    this.syncBoundsFields()

    // Bounds become the search — don't also AND with a leftover location string
    const location = this.formTarget.querySelector('[name="location"]')
    if (location) location.value = ""

    if (this.hasAreaButtonTarget) {
      this.areaButtonTarget.textContent = "Searching…"
      this.areaButtonTarget.disabled = true
    }

    this.formTarget.requestSubmit()
  }

  highlightCard(event) {
    const id = event.currentTarget.dataset.listingId
    this.activateListing(id, { scroll: false, openPopup: false })
  }

  unhighlightCard() {
    // keep last active for orientation
  }

  focusCard(event) {
    const id = event.currentTarget.dataset.listingId
    this.activateListing(id, { scroll: false, openPopup: true })
  }

  activateListing(id, { scroll = false, openPopup = false } = {}) {
    const numericId = String(id)
    this.activeId = numericId

    this.cardTargets.forEach((card) => {
      card.classList.toggle("is-active", card.dataset.listingId === numericId)
    })

    Object.entries(this.markersById).forEach(([markerId, marker]) => {
      const el = marker.getElement()
      if (!el) return
      el.classList.toggle("is-active", markerId === numericId)
    })

    const marker = this.markersById[numericId]
    if (marker && this.map) {
      if (openPopup) marker.openPopup()
      if (scroll) {
        this.map.panTo(marker.getLatLng(), { animate: true })
      }
    }

    if (scroll && this.hasListScrollTarget) {
      const card = this.cardTargets.find((c) => c.dataset.listingId === numericId)
      card?.scrollIntoView({ behavior: "smooth", block: "nearest" })
    }
  }

  showList() {
    if (!this.hasListPaneTarget || !this.hasMapPaneTarget) return
    if (!this.isMobile()) return

    this.listPaneTarget.classList.remove("hidden")
    this.mapPaneTarget.classList.add("hidden")
    this.mapPaneTarget.classList.remove("flex")
    this.listTabTarget.classList.add("font-semibold", "text-ink")
    this.listTabTarget.classList.remove("font-medium", "text-ink-3")
    this.mapTabTarget.classList.remove("font-semibold", "text-ink")
    this.mapTabTarget.classList.add("font-medium", "text-ink-3")
  }

  showMap() {
    if (!this.hasMapPaneTarget) return

    if (this.isMobile()) {
      this.listPaneTarget.classList.add("hidden")
      this.mapPaneTarget.classList.remove("hidden")
      this.mapPaneTarget.classList.add("flex")
      this.mapTabTarget.classList.add("font-semibold", "text-ink")
      this.mapTabTarget.classList.remove("font-medium", "text-ink-3")
      this.listTabTarget.classList.remove("font-semibold", "text-ink")
      this.listTabTarget.classList.add("font-medium", "text-ink-3")
    }

    this.scheduleResize()
    this.clearSearchBoundary()
    this.userMovedMap = false
    this.applyInitialFrame()
    this.scheduleResize({ reframe: true })
  }
}
