import { Controller } from "@hotwired/stimulus"
import MoneyDisplay from "money_display"

const LEAFLET_CSS = "/vendor/leaflet/leaflet.css"
const LEAFLET_JS = "/vendor/leaflet/leaflet.js"
const LEAFLET_CSS_FALLBACK = "https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.css"
const LEAFLET_JS_FALLBACK = "https://cdn.jsdelivr.net/npm/leaflet@1.9.4/dist/leaflet.js"
/** Port of Spain — default Buy-page camera. */
const PORT_OF_SPAIN = [10.6549, -61.5019]
const DEFAULT_ZOOM = 11
const MIN_ZOOM = 8
/**
 * Trinidad & Tobago region (matches NominatimGeocoder / PhotonGeocoder).
 * A small pad is applied for maxBounds so edge listings aren't stuck against a hard wall.
 */
const TT_REGION = { south: 10.0, north: 11.45, west: -61.95, east: -60.4 }
const TT_MAX_BOUNDS = {
  south: TT_REGION.south - 0.35,
  north: TT_REGION.north + 0.35,
  west: TT_REGION.west - 0.35,
  east: TT_REGION.east + 0.35
}
const BASEMAP_STORAGE_KEY = "estate-map-basemap"
/** Vertical gap (px) between pills that share identical lat/lng. */
const PIN_STACK_PX = 30
/** At this zoom and above, overlapping pins fan into a vertical stack. */
const PIN_STACK_MIN_ZOOM = 17
/** Ora "dots" frames — terminal-style spinner. */
const ORA_DOTS = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
/** Short techy real-estate compiler lines — flash rapidly while the map boots. */
const MAP_BOOT_MESSAGES = [
  "Compiling listings…",
  "Resolving parcel graph…",
  "Indexing Trinidad coords…",
  "Linking price vectors…",
  "Hydrating map tiles…",
  "Bundling neighbourhoods…",
  "Warming Port of Spain cache…",
  "Sorting MLS payloads…",
  "Stencilizing lot boundaries…",
  "Provisioning pin layer…",
  "Diffing market inventory…",
  "Emitting search index…"
]
const BOOT_MESSAGE_START_MS = 200
const BOOT_MESSAGE_END_MS = 80
const BOOT_FADE_MS = 40
/** Extra hold after basemap + pins are ready so compiler chrome can flash. */
const BOOT_EXTRA_HOLD_MS = 500
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
    "form", "north", "south", "east", "west", "areaButton", "spinner", "reloadSpinner",
    "basemapControls", "basemapButton", "resultsCount", "resultsList", "listEmpty",
    "listSentinel", "listLoading"
  ]
  static values = { listings: Array, boundary: Object, viewport: Object }

  connect() {
    this.markersById = {}
    this.activeId = null
    this.mapMoved = false
    this.userMovedMap = false
    this._destroyed = false
    this._programmaticFrame = false
    this._viewportReloadTimer = null
    this._viewportAbort = null
    this._listAbort = null
    this._loadingMore = false
    this._suppressViewportReload = true
    this._skipViewportReloadOnce = false
    this._basemapReady = false
    this._pinsReady = false
    this._pinLoadId = 0

    this.onCurrencyChanged = this.onCurrencyChanged.bind(this)
    document.addEventListener("currency:changed", this.onCurrencyChanged)

    this.showSpinner()

    if (this.isMobile()) {
      this.showList()
    }

    this.setupInfiniteScroll()
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
    this.stopBootChrome()
    document.removeEventListener("currency:changed", this.onCurrencyChanged)
    if (this._resizeObserver) {
      this._resizeObserver.disconnect()
      this._resizeObserver = null
    }
    if (this._listObserver) {
      this._listObserver.disconnect()
      this._listObserver = null
    }
    if (this._viewportReloadTimer) {
      window.clearTimeout(this._viewportReloadTimer)
      this._viewportReloadTimer = null
    }
    this._viewportAbort?.abort()
    this._listAbort?.abort()
    this.teardownMap()
  }

  onCurrencyChanged(event) {
    const currency = event.detail?.currency
    if (!currency) return

    const ratesCtrl = this.application.getControllerForElementAndIdentifier(document.body, "currency")
    if (ratesCtrl?.ratesValue) MoneyDisplay.configure(ratesCtrl.ratesValue)

    const activeId = this.activeId
    const listings = this.listingsValue.map((listing) => {
      const cents = listing.priceCents
      if (cents == null) return listing
      return {
        ...listing,
        price: MoneyDisplay.format(cents, { currency, rent: !!listing.rent }),
        priceLabel: MoneyDisplay.compact(cents, { currency, rent: !!listing.rent })
      }
    })
    this.listingsValue = listings
    this.renderMarkers()
    if (activeId) this.activateListing(activeId, { scroll: false, openPopup: false })
  }

  isMobile() {
    return window.matchMedia("(max-width: 1023px)").matches
  }

  showSpinner() {
    if (!this.hasSpinnerTarget) return
    this.spinnerTarget.classList.remove("hidden")
    this.spinnerTarget.dataset.state = "loading"
    this.startBootChrome()
  }

  showSpinnerError(message) {
    if (!this.hasSpinnerTarget) return
    this.stopBootChrome()
    this.spinnerTarget.classList.remove("hidden")
    this.spinnerTarget.dataset.state = "error"
    const label = this.spinnerTarget.querySelector("[data-search-map-spinner-label]")
    if (label) {
      label.style.opacity = "1"
      label.textContent = message
    }
  }

  hideSpinner() {
    if (!this.hasSpinnerTarget) return
    this.stopBootChrome()
    this.spinnerTarget.classList.add("hidden")
    this.showBasemapControls()
  }

  showBasemapControls() {
    if (!this.hasBasemapControlsTarget) return
    this.basemapControlsTarget.classList.remove("hidden")
    this.basemapControlsTarget.setAttribute("aria-hidden", "false")
  }

  startBootChrome() {
    this.stopBootChrome()

    const ora = this.spinnerTarget.querySelector("[data-search-map-spinner-ora]")
    const label = this.spinnerTarget.querySelector("[data-search-map-spinner-label]")
    let frame = 0
    let messageIndex = 0
    const lastIndex = Math.max(MAP_BOOT_MESSAGES.length - 1, 1)

    if (ora) ora.textContent = ORA_DOTS[0]
    if (label) {
      label.style.opacity = "1"
      label.style.transition = `opacity ${BOOT_FADE_MS}ms ease`
      label.textContent = MAP_BOOT_MESSAGES[0]
    }

    this._oraTimer = window.setInterval(() => {
      frame = (frame + 1) % ORA_DOTS.length
      if (ora) ora.textContent = ORA_DOTS[frame]
    }, 80)

    const advanceMessage = () => {
      if (!label || this._destroyed) return
      messageIndex = (messageIndex + 1) % MAP_BOOT_MESSAGES.length
      label.style.opacity = "0"
      if (this._bootFadeTimer) window.clearTimeout(this._bootFadeTimer)
      this._bootFadeTimer = window.setTimeout(() => {
        if (!label || this._destroyed) return
        label.textContent = MAP_BOOT_MESSAGES[messageIndex]
        label.style.opacity = "1"
      }, BOOT_FADE_MS)

      // Start fast, ramp toward blitz by the last unique line (then stay at end pace).
      const progress = Math.min(1, messageIndex / lastIndex)
      const delay = BOOT_MESSAGE_START_MS +
        (BOOT_MESSAGE_END_MS - BOOT_MESSAGE_START_MS) * progress
      this._bootMessageTimer = window.setTimeout(advanceMessage, delay)
    }

    this._bootMessageTimer = window.setTimeout(advanceMessage, BOOT_MESSAGE_START_MS)
  }

  stopBootChrome() {
    if (this._oraTimer) {
      window.clearInterval(this._oraTimer)
      this._oraTimer = null
    }
    if (this._bootMessageTimer) {
      window.clearInterval(this._bootMessageTimer)
      this._bootMessageTimer = null
    }
    if (this._bootFadeTimer) {
      window.clearTimeout(this._bootFadeTimer)
      this._bootFadeTimer = null
    }
    if (this._bootHoldTimer) {
      window.clearTimeout(this._bootHoldTimer)
      this._bootHoldTimer = null
    }
  }

  // Initial overlay stays up until basemap tiles AND pins have both settled.
  // (SSR ships listings-value="[]"; pins always arrive via async fetch.)
  markBasemapReady() {
    this._basemapReady = true
    this.tryDismissInitialSpinner()
  }

  markPinsReady() {
    this._pinsReady = true
    this.tryDismissInitialSpinner()
  }

  tryDismissInitialSpinner() {
    if (!this._basemapReady || !this._pinsReady) return
    if (this._bootHoldTimer) return

    this._bootHoldTimer = window.setTimeout(() => {
      this._bootHoldTimer = null
      if (this._destroyed) return
      this.hideSpinner()
    }, BOOT_EXTRA_HOLD_MS)
  }

  showReloadSpinner() {
    if (!this.hasReloadSpinnerTarget) return
    this.reloadSpinnerTarget.classList.remove("hidden")
    this.reloadSpinnerTarget.classList.add("flex")
    this.reloadSpinnerTarget.setAttribute("aria-hidden", "false")
  }

  hideReloadSpinner() {
    if (!this.hasReloadSpinnerTarget) return
    this.reloadSpinnerTarget.classList.add("hidden")
    this.reloadSpinnerTarget.classList.remove("flex")
    this.reloadSpinnerTarget.setAttribute("aria-hidden", "true")
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
        scrollWheelZoom: true,
        minZoom: MIN_ZOOM,
        maxBounds: [
          [TT_MAX_BOUNDS.south, TT_MAX_BOUNDS.west],
          [TT_MAX_BOUNDS.north, TT_MAX_BOUNDS.east]
        ],
        maxBoundsViscosity: 1.0
      }).setView(PORT_OF_SPAIN, DEFAULT_ZOOM)

      L.control.zoom({ position: "bottomright" }).addTo(this.map)

      this.activeBasemap = this.storedBasemap()
      this.setBasemapLayer(this.activeBasemap, { showSpinner: true, layerIndex: 0 })
      this.syncBasemapButtons()

      this.markerLayer = L.layerGroup().addTo(this.map)
      this.renderMarkers()
      // Prefer SSR pins when present; otherwise first moveend/fetch marks ready.
      if (this.listingsValue?.length) {
        this.markPinsReady()
      } else {
        // Don't leave the overlay hung if moveend/bounds never kick off a fetch.
        window.setTimeout(() => {
          if (!this._destroyed && !this._pinsReady) this.markPinsReady()
        }, 10000)
      }

      this.suppressAreaButton = true
      this._suppressViewportReload = true
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
      this.map.on("zoomend", () => this.applyPinStackMode())

      // Leaflet autoPan after opening a pin card must not count as a user search-pan.
      this.map.on("autopanstart", () => {
        this._skipViewportReloadOnce = true
        this._programmaticFrame = true
        window.setTimeout(() => { this._programmaticFrame = false }, 450)
      })

      this.map.on("moveend", () => {
        if (this.suppressAreaButton) {
          this.suppressAreaButton = false
        }

        // Listing selection pan — do not reload markers (would close an open popup).
        if (this._skipViewportReloadOnce) {
          this._skipViewportReloadOnce = false
          return
        }

        if (this._suppressViewportReload) {
          this._suppressViewportReload = false
          // Only clamp the list to the map when this visit already came with an area.
          // Island-wide / filter-only loads must keep SSR results — forcing a reload from a
          // zero-size (mobile list-first) or zoom-14 pin frame was wiping counts to 0.
          if (this.startedWithAreaSearch()) {
            this.scheduleViewportReload({ force: true })
          } else if (!this.listingsValue?.length) {
            this.reloadMarkersForFilters().catch((error) => console.error("Marker load failed", error))
          }
          return
        }

        if (this._programmaticFrame) return
        // Resize/invalidateSize fires moveend too — only clamp when the user panned/zoomed.
        if (!this.userMovedMap) return
        // Inspecting a pin card: let the user nudge the map without wiping selection.
        if (this.hasOpenListingPopup()) return
        this.showReloadSpinner()
        this.scheduleViewportReload()
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
    } else if (this.urlBounds()) {
      // Viewport search without location text — never invent an outline
      this.fitToViewportBounds(this.urlBounds())
      this.initialFrame = "url"
    } else {
      // Drop stale / out-of-region N/S/E/W so Buy doesn't reload the world.
      this.clearBoundsFields()
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
      if (!this.inTtRegion(listing.lat, listing.lng)) return false
      return boundaryBounds.contains([listing.lat, listing.lng])
    })

    let fitTarget = boundaryBounds
    if (inside.length >= 1) {
      const points = inside.map((l) => L.latLng(l.lat, l.lng))
      const listingBounds = L.latLngBounds(points)
      fitTarget = boundaryBounds.extend(listingBounds)
    }

    // Boundary itself must land inside TT; otherwise snap to POS.
    const south = fitTarget.getSouth()
    const north = fitTarget.getNorth()
    const west = fitTarget.getWest()
    const east = fitTarget.getEast()
    if (!this.boundsOverlapTt({ south, north, west, east })) {
      this.focusPortOfSpain()
      return
    }

    try {
      this.map.fitBounds(fitTarget, {
        padding: [48, 48],
        maxZoom: 14,
        animate: false
      })
    } catch (error) {
      console.warn("fitBounds failed", error)
      this.focusPortOfSpain()
    }
  }

  hasViewportBounds() {
    return Boolean(this.normalizedViewport(this.viewportValue))
  }

  // Reject frames that sit mostly outside Trinidad & Tobago.
  inTtRegion(lat, lng) {
    const y = Number(lat)
    const x = Number(lng)
    if (!Number.isFinite(y) || !Number.isFinite(x)) return false
    return y >= TT_REGION.south && y <= TT_REGION.north &&
      x >= TT_REGION.west && x <= TT_REGION.east
  }

  boundsOverlapTt(bounds) {
    if (!bounds) return false
    return bounds.south < TT_REGION.north &&
      bounds.north > TT_REGION.south &&
      bounds.west < TT_REGION.east &&
      bounds.east > TT_REGION.west
  }

  clampBoundsToTt(bounds) {
    if (!bounds) return null
    if (!this.boundsOverlapTt(bounds)) return null
    return {
      south: Math.max(bounds.south, TT_REGION.south),
      north: Math.min(bounds.north, TT_REGION.north),
      west: Math.max(bounds.west, TT_REGION.west),
      east: Math.min(bounds.east, TT_REGION.east)
    }
  }

  listingPointsInTt() {
    return this.listingsValue
      .filter((item) => this.inTtRegion(item.lat, item.lng))
      .map((item) => [Number(item.lat), Number(item.lng)])
  }

  focusPortOfSpain({ zoom = DEFAULT_ZOOM } = {}) {
    if (!this.map) return
    this.withProgrammaticFrame(() => {
      this.map.setView(PORT_OF_SPAIN, zoom, { animate: false })
    })
  }

  normalizedViewport(raw) {
    if (!raw || typeof raw !== "object") return null
    const south = parseFloat(raw.south)
    const west = parseFloat(raw.west)
    const north = parseFloat(raw.north)
    const east = parseFloat(raw.east)
    if ([south, west, north, east].some((n) => Number.isNaN(n))) return null
    if (south >= north || west >= east) return null
    return this.clampBoundsToTt({ south, west, north, east })
  }

  fitToViewportBounds(bounds = this.normalizedViewport(this.viewportValue) || this.urlBounds()) {
    if (!this.map || !bounds) {
      this.focusPortOfSpain()
      return
    }

    const clamped = this.clampBoundsToTt(bounds)
    if (!clamped) {
      this.focusPortOfSpain()
      return
    }
    bounds = clamped

    const span = Math.max(bounds.north - bounds.south, bounds.east - bounds.west)
    const center = this.viewportCenter(bounds)

    // Named / geocoded place: lock dead-center at a close zoom (don't frame huge pads).
    if (center && this.inTtRegion(center.lat, center.lng)) {
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
      this.focusPortOfSpain()
    }
  }

  viewportCenter(bounds) {
    const raw = this.viewportValue
    if (raw && typeof raw === "object") {
      const lat = parseFloat(raw.lat)
      const lng = parseFloat(raw.lng)
      if (!Number.isNaN(lat) && !Number.isNaN(lng) && this.inTtRegion(lat, lng)) {
        return { lat, lng }
      }
    }
    if (!bounds) return null
    return {
      lat: (bounds.north + bounds.south) / 2,
      lng: (bounds.east + bounds.west) / 2
    }
  }

  hasUrlBounds() {
    return Boolean(this.urlBounds())
  }

  urlBounds() {
    if (!this.hasNorthTarget) return null
    const fields = [this.northTarget, this.southTarget, this.eastTarget, this.westTarget]
    if (!fields.every((field) => field.value && field.value.trim() !== "")) return null

    const south = parseFloat(this.southTarget.value)
    const west = parseFloat(this.westTarget.value)
    const north = parseFloat(this.northTarget.value)
    const east = parseFloat(this.eastTarget.value)
    if ([south, west, north, east].some((n) => Number.isNaN(n))) return null
    if (south >= north || west >= east) return null

    return this.clampBoundsToTt({ south, west, north, east })
  }

  clearBoundsFields() {
    if (this.hasNorthTarget) this.northTarget.value = ""
    if (this.hasSouthTarget) this.southTarget.value = ""
    if (this.hasEastTarget) this.eastTarget.value = ""
    if (this.hasWestTarget) this.westTarget.value = ""
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
        this.markBasemapReady()
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
      // Never dismiss the initial overlay on tiles alone — wait for pins too.
      this.markBasemapReady()
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
    this.pinGroupsByPoint = this.buildPinGroups()

    this.listingsValue.forEach((listing) => {
      // Out-of-region pins are ignored so framing / maxBounds stay in TT.
      if (!this.inTtRegion(listing.lat, listing.lng)) return

      const icon = L.divIcon({
        className: "estate-price-marker",
        html: `<button type="button" class="price-pill" data-id="${listing.id}">${listing.priceLabel}</button>`,
        iconSize: [0, 0],
        iconAnchor: [0, 0]
      })

      const marker = L.marker([listing.lat, listing.lng], {
        icon,
        riseOnHover: true,
        zIndexOffset: 0
      })
      marker.listingId = listing.id
      marker.pointKey = `${listing.lat},${listing.lng}`

      marker.bindPopup(this.popupHtml(listing), {
        className: "estate-map-popup",
        maxWidth: 286,
        minWidth: 286,
        offset: [0, -10],
        autoPan: true,
        autoPanPadding: [56, 56]
      })

      // Click selects + opens the bound popup. Leaflet autoPan keeps the card on-screen
      // without treating the pan as a viewport search reload.
      marker.on("click", () => this.activateListing(listing.id, { scroll: true, panMap: false, openPopup: false }))

      marker.addTo(this.markerLayer)
      this.markersById[listing.id] = marker
    })

    this.applyPinStackMode()
  }

  // Exact-same coords share a point. listingsValue order = search relevance (first wins when collapsed).
  buildPinGroups() {
    const groups = {}
    this.listingsValue.forEach((listing) => {
      if (!this.inTtRegion(listing.lat, listing.lng)) return
      const key = `${listing.lat},${listing.lng}`
      ;(groups[key] ||= []).push(listing)
    })
    return groups
  }

  stackPinsAtCurrentZoom() {
    if (!this.map) return false
    return this.map.getZoom() >= PIN_STACK_MIN_ZOOM
  }

  // Close zoom: fan identical coords upward. Farther out: keep most-relevant pill only.
  applyPinStackMode() {
    if (!this.map || !this.pinGroupsByPoint) return

    const stacking = this.stackPinsAtCurrentZoom()
    const activeId = this.activeId != null ? String(this.activeId) : null

    Object.values(this.pinGroupsByPoint).forEach((group) => {
      let visibleId = group[0] ? String(group[0].id) : null
      if (!stacking && activeId && group.some((listing) => String(listing.id) === activeId)) {
        visibleId = activeId
      }

      group.forEach((listing, index) => {
        const marker = this.markersById[listing.id]
        if (!marker) return

        const show = stacking || String(listing.id) === visibleId
        const stackPx = stacking ? index * PIN_STACK_PX : 0
        const layoutKey = `${show}:${stackPx}`

        // Skip setIcon when layout is unchanged — rebuilding the icon closes an open popup.
        if (marker._pinLayoutKey !== layoutKey) {
          marker._pinLayoutKey = layoutKey
          marker.setIcon(L.divIcon({
            className: "estate-price-marker",
            html: `<button type="button" class="price-pill" data-id="${listing.id}">${listing.priceLabel}</button>`,
            iconSize: [0, 0],
            iconAnchor: [0, stackPx]
          }))
          marker.setZIndexOffset(stackPx + (show ? 0 : -1000))
          marker.setOpacity(show ? 1 : 0)
          const el = marker.getElement()
          if (el) el.style.pointerEvents = show ? "" : "none"
          const popup = marker.getPopup()
          if (popup) popup.options.offset = [0, -10 - stackPx]
        }

        const el = marker.getElement()
        el?.querySelector(".price-pill")?.classList.toggle("is-active", activeId === String(listing.id))
      })
    })
  }

  pinNeedsReveal(id) {
    if (this.stackPinsAtCurrentZoom() || !this.pinGroupsByPoint) return false
    const marker = this.markersById[String(id)]
    if (!marker?.pointKey) return false
    const group = this.pinGroupsByPoint[marker.pointKey]
    if (!group || group.length < 2) return false
    return String(group[0].id) !== String(id)
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
         data-listing-id="${listing.id}"
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

  withProgrammaticFrame(fn, { holdMs = 0 } = {}) {
    this._programmaticFrame = true
    try {
      fn()
    } finally {
      window.setTimeout(() => { this._programmaticFrame = false }, holdMs)
    }
  }

  centerOnTopListing({ zoom = DEFAULT_ZOOM } = {}) {
    if (!this.map) return

    // Buy page default: Port of Spain — don't fitBounds island-wide inventory
    // (or bad out-of-region pins), which previously zoomed out to near-world views.
    this.focusPortOfSpain({ zoom })
  }

  fitToListings() {
    if (!this.map) return

    const points = this.listingPointsInTt()

    if (points.length === 0) {
      this.focusPortOfSpain()
      return
    }

    if (points.length === 1) {
      this.withProgrammaticFrame(() => this.map.setView(points[0], 13))
      return
    }

    this.withProgrammaticFrame(() => {
      this.map.fitBounds(points, { padding: [48, 48], maxZoom: 12, animate: false })
    })
  }

  syncBoundsFields() {
    if (!this.map) return false
    const size = this.map.getSize?.()
    if (!size || size.x < 40 || size.y < 40) return false

    const bounds = this.map.getBounds()
    const north = bounds.getNorth()
    const south = bounds.getSouth()
    const east = bounds.getEast()
    const west = bounds.getWest()
    if (![north, south, east, west].every(Number.isFinite)) return false
    if (south >= north || west >= east) return false
    if ((north - south) < 1e-8 || (east - west) < 1e-8) return false
    if ([north, south, east, west].every((value) => Math.abs(value) < 1e-9)) return false

    this.northTarget.value = north.toFixed(6)
    this.southTarget.value = south.toFixed(6)
    this.eastTarget.value = east.toFixed(6)
    this.westTarget.value = west.toFixed(6)
    return true
  }

  startedWithAreaSearch() {
    return ["boundary", "viewport", "url"].includes(this.initialFrame)
  }

  searchArea(event) {
    event.preventDefault()
    if (!this.syncBoundsFields()) return

    const location = this.formTarget.querySelector('[name="location"]')
    if (location) location.value = ""

    if (this.hasAreaButtonTarget) {
      this.areaButtonTarget.textContent = "Searching…"
      this.areaButtonTarget.disabled = true
    }

    this.showReloadSpinner()
    this.reloadForViewport()
      .catch((error) => console.error("Search this area failed", error))
      .finally(() => {
        if (!this.hasAreaButtonTarget) return
        this.areaButtonTarget.textContent = "Search this area"
        this.areaButtonTarget.disabled = false
        this.areaButtonTarget.classList.add("hidden")
      })
  }

  setupInfiniteScroll() {
    if (!this.hasListSentinelTarget || !this.hasListScrollTarget) return
    if (typeof IntersectionObserver === "undefined") return

    this._listObserver = new IntersectionObserver(
      (entries) => {
        if (!entries.some((entry) => entry.isIntersecting)) return
        this.loadNextPage()
      },
      { root: this.listScrollTarget, rootMargin: "120px", threshold: 0 }
    )
    this._listObserver.observe(this.listSentinelTarget)
  }

  scheduleViewportReload({ force = false } = {}) {
    if (this._destroyed) return
    if (this._viewportReloadTimer) window.clearTimeout(this._viewportReloadTimer)
    const delay = force ? 40 : 320
    this._viewportReloadTimer = window.setTimeout(() => {
      this._viewportReloadTimer = null
      this.reloadForViewport().catch((error) => console.error("Viewport reload failed", error))
    }, delay)
  }

  queryParamsFromForm({ page = null, clearLocation = false } = {}) {
    if (!this.hasFormTarget) return new URLSearchParams()

    const formData = new FormData(this.formTarget)
    if (clearLocation) formData.delete("location")
    formData.delete("page")
    if (page != null) formData.set("page", String(page))

    const params = new URLSearchParams()
    for (const [key, value] of formData.entries()) {
      if (value == null || String(value).trim() === "") continue
      params.append(key, value)
    }
    return params
  }

  async reloadMarkersForFilters() {
    if (this._destroyed || !this.hasFormTarget) return

    const loadId = ++this._pinLoadId
    this._viewportAbort?.abort()
    this._viewportAbort = new AbortController()
    const { signal } = this._viewportAbort

    try {
      const params = this.queryParamsFromForm({ page: 1 })
      ;["north", "south", "east", "west"].forEach((key) => params.delete(key))

      const markersRes = await fetch(`/properties/map_markers?${params.toString()}`, {
        headers: { Accept: "application/json" },
        signal,
        credentials: "same-origin"
      })
      if (!markersRes.ok) throw new Error(`map_markers HTTP ${markersRes.status}`)
      const listings = await markersRes.json()
      if (this._destroyed) return

      this.listingsValue = Array.isArray(listings) ? listings : []
      this.renderMarkers()
      if (this.initialFrame === "top" && !this.userMovedMap) {
        this.centerOnTopListing()
      }
    } finally {
      // Only the latest in-flight load may dismiss the initial spinner.
      if (loadId === this._pinLoadId && !this._destroyed) this.markPinsReady()
    }
  }

  async reloadForViewport() {
    if (!this.map || this._destroyed) {
      this.hideReloadSpinner()
      return
    }
    if (!this.syncBoundsFields()) {
      this.hideReloadSpinner()
      return
    }

    const loadId = ++this._pinLoadId
    const location = this.formTarget?.querySelector?.('[name="location"]')
    if (location) location.value = ""

    const params = this.queryParamsFromForm({ page: 1, clearLocation: true })
    this.replaceListUrl(params)

    this._viewportAbort?.abort()
    this._viewportAbort = new AbortController()
    const { signal } = this._viewportAbort

    try {
      const markersUrl = `/properties/map_markers?${params.toString()}`
      const resultsUrl = `/properties/results?${params.toString()}`

      const [markersRes, resultsRes] = await Promise.all([
        fetch(markersUrl, { headers: { Accept: "application/json" }, signal, credentials: "same-origin" }),
        fetch(resultsUrl, { headers: { Accept: "application/json" }, signal, credentials: "same-origin" })
      ])

      if (!markersRes.ok) throw new Error(`map_markers HTTP ${markersRes.status}`)
      if (!resultsRes.ok) throw new Error(`results HTTP ${resultsRes.status}`)

      const listings = await markersRes.json()
      const results = await resultsRes.json()
      if (this._destroyed) return

      const keepId = this.activeId
      const keepPopupOpen = this.hasOpenListingPopup()
      this.listingsValue = Array.isArray(listings) ? listings : []
      this.renderMarkers()
      this.replaceResultsList(results)
      if (keepId && this.markersById[keepId]) {
        this.activateListing(keepId, { scroll: false, panMap: false, openPopup: keepPopupOpen })
      }
    } finally {
      if (loadId === this._pinLoadId && !this._destroyed) {
        this.markPinsReady()
        this.hideReloadSpinner()
      }
    }
  }

  replaceResultsList(results) {
    if (!this.hasResultsListTarget) return

    const total = Number(results.totalCount) || 0
    const page = Number(results.page) || 1
    const totalPages = Number(results.totalPages) || 1
    const html = results.html || ""

    if (this.hasResultsCountTarget) {
      this.resultsCountTarget.textContent = `${total.toLocaleString()} ${total === 1 ? "result" : "results"}`
    }

    this.resultsListTarget.innerHTML = html
    this.resultsListTarget.dataset.page = String(page)
    this.resultsListTarget.dataset.totalPages = String(totalPages)
    this.resultsListTarget.classList.toggle("hidden", total === 0 || !html.trim())

    if (this.hasListEmptyTarget) {
      this.listEmptyTarget.classList.toggle("hidden", total > 0)
    }

    if (this.hasListSentinelTarget) {
      this.listSentinelTarget.classList.toggle("hidden", page >= totalPages)
    }

    if (this.hasListScrollTarget) {
      this.listScrollTarget.scrollTop = 0
    }

    this._loadingMore = false
  }

  async loadNextPage() {
    if (this._loadingMore || this._destroyed || !this.hasResultsListTarget) return

    const page = Number(this.resultsListTarget.dataset.page || 1)
    const totalPages = Number(this.resultsListTarget.dataset.totalPages || 1)
    if (page >= totalPages) return

    this._loadingMore = true
    if (this.hasListLoadingTarget) this.listLoadingTarget.hidden = false

    this._listAbort?.abort()
    this._listAbort = new AbortController()

    try {
      const nextPage = page + 1
      const params = this.queryParamsFromForm({ page: nextPage, clearLocation: true })
      const response = await fetch(`/properties/results?${params.toString()}`, {
        headers: { Accept: "application/json" },
        signal: this._listAbort.signal,
        credentials: "same-origin"
      })
      if (!response.ok) throw new Error(`results HTTP ${response.status}`)
      const results = await response.json()
      if (this._destroyed) return

      this.resultsListTarget.insertAdjacentHTML("beforeend", results.html || "")
      this.resultsListTarget.dataset.page = String(results.page || nextPage)
      this.resultsListTarget.dataset.totalPages = String(results.totalPages || totalPages)

      if (this.hasListSentinelTarget) {
        const done = Number(results.page || nextPage) >= Number(results.totalPages || totalPages)
        this.listSentinelTarget.classList.toggle("hidden", done)
      }
    } catch (error) {
      if (error?.name !== "AbortError") console.error("Load more failed", error)
    } finally {
      this._loadingMore = false
      if (this.hasListLoadingTarget) this.listLoadingTarget.hidden = true
    }
  }

  replaceListUrl(params) {
    try {
      const url = `${window.location.pathname}?${params.toString()}`
      window.history.replaceState(window.history.state, "", url)
    } catch (_) {
      /* ignore */
    }
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

  hasOpenListingPopup() {
    if (!this.activeId) return false
    const marker = this.markersById[this.activeId]
    const popup = marker?.getPopup?.()
    return Boolean(popup?.isOpen?.())
  }

  activateListing(id, { scroll = false, panMap = scroll, openPopup = false } = {}) {
    const numericId = String(id)
    this.activeId = numericId

    this.cardTargets.forEach((card) => {
      card.classList.toggle("is-active", card.dataset.listingId === numericId)
    })

    // Only rebuild pin layout when a collapsed stack must reveal this listing.
    // Always-rewriting icons via setIcon closes Leaflet popups mid-open.
    if (this.pinNeedsReveal(numericId)) {
      this.applyPinStackMode()
    } else {
      Object.entries(this.markersById).forEach(([markerId, marker]) => {
        marker.getElement()?.querySelector(".price-pill")?.classList.toggle("is-active", markerId === numericId)
      })
    }

    const marker = this.markersById[numericId]
    if (marker && this.map) {
      if (openPopup) marker.openPopup()
      if (panMap) {
        // Keep moveend from treating this pan as a "search this area" reload.
        this._skipViewportReloadOnce = true
        this.withProgrammaticFrame(() => {
          this.map.panTo(marker.getLatLng(), { animate: true })
        }, { holdMs: 400 })
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
