import { Controller } from "@hotwired/stimulus"

// Location autocomplete via /locations/autocomplete (Photon / OSM).
export default class extends Controller {
  static targets = ["input", "menu"]
  static values = {
    url: { type: String, default: "/locations/autocomplete" },
    autoSubmit: { type: Boolean, default: false }
  }

  connect() {
    this.activeIndex = -1
    this.results = []
    this.abortController = null
    this.hideMenu()
  }

  disconnect() {
    this.abortController?.abort()
    clearTimeout(this.debounceTimer)
  }

  onInput() {
    const query = this.inputTarget.value.trim()
    clearTimeout(this.debounceTimer)
    this.clearBounds()

    if (query.length < 2) {
      this.results = []
      this.hideMenu()
      return
    }

    this.debounceTimer = setTimeout(() => this.fetchResults(query), 220)
  }

  clearBounds() {
    const form = this.element.closest("form")
    if (!form) return

    ;["north", "south", "east", "west"].forEach((key) => {
      const field = form.querySelector(`[name="${key}"]`)
      if (field) field.value = ""
    })
  }

  onFocus() {
    if (this.results.length) this.showMenu()
  }

  onBlur() {
    window.setTimeout(() => this.hideMenu(), 150)
  }

  onKeydown(event) {
    if (!this.menuOpen()) return

    if (event.key === "ArrowDown") {
      event.preventDefault()
      this.moveActive(1)
    } else if (event.key === "ArrowUp") {
      event.preventDefault()
      this.moveActive(-1)
    } else if (event.key === "Enter" && this.activeIndex >= 0) {
      event.preventDefault()
      this.selectIndex(this.activeIndex)
    } else if (event.key === "Escape") {
      this.hideMenu()
    }
  }

  async fetchResults(query) {
    this.abortController?.abort()
    this.abortController = new AbortController()

    try {
      const url = new URL(this.urlValue, window.location.origin)
      url.searchParams.set("q", query)

      const response = await fetch(url, {
        headers: { Accept: "application/json" },
        signal: this.abortController.signal
      })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)

      const data = await response.json()
      this.results = Array.isArray(data.results) ? data.results : []
      this.activeIndex = this.results.length ? 0 : -1
      this.renderMenu()
    } catch (error) {
      if (error.name === "AbortError") return
      this.results = []
      this.hideMenu()
    }
  }

  renderMenu() {
    if (!this.hasMenuTarget) return

    if (!this.results.length) {
      this.hideMenu()
      return
    }

    this.menuTarget.innerHTML = `
      <div class="location-ac-list" role="listbox">
        ${this.results.map((result, index) => this.itemHtml(result, index)).join("")}
      </div>
      <p class="location-ac-foot">Locations via OpenStreetMap</p>
    `

    this.showMenu()
  }

  itemHtml(result, index) {
    const active = index === this.activeIndex ? "is-active" : ""
    const name = this.escape(result.name || result.label || "")
    const secondary = this.secondaryLabel(result)
    const type = this.prettyType(result.type)

    return `
      <button
        type="button"
        role="option"
        aria-selected="${index === this.activeIndex}"
        class="location-ac-item ${active}"
        data-index="${index}"
        data-action="mousedown->location-autocomplete#pick"
      >
        <span class="location-ac-pin" aria-hidden="true">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true">
            <path d="M12 21s7-5.2 7-11a7 7 0 1 0-14 0c0 5.8 7 11 7 11Z"/>
            <circle cx="12" cy="10" r="2.25"/>
          </svg>
        </span>
        <span class="location-ac-copy">
          <span class="location-ac-name">${name}</span>
          ${secondary ? `<span class="location-ac-sub">${this.escape(secondary)}</span>` : ""}
        </span>
        <span class="location-ac-type">${this.escape(type)}</span>
      </button>
    `
  }

  secondaryLabel(result) {
    const label = (result.label || "").trim()
    const name = (result.name || "").trim()
    if (!label || !name) return label === name ? "" : label
    if (label.toLowerCase().startsWith(name.toLowerCase())) {
      return label.slice(name.length).replace(/^,\s*/, "").trim()
    }
    return label
  }

  prettyType(type) {
    const raw = (type || "place").toString().replaceAll("_", " ")
    return raw.charAt(0).toUpperCase() + raw.slice(1)
  }

  pick(event) {
    event.preventDefault()
    const index = Number(event.currentTarget.dataset.index)
    this.selectIndex(index)
  }

  selectIndex(index) {
    const result = this.results[index]
    if (!result) return

    this.inputTarget.value = result.name || result.label || ""
    this.writeBounds(result)
    this.hideMenu()
    this.dispatch("selected", { detail: result })

    if (this.autoSubmitValue) {
      const form = this.element.closest("form")
      form?.requestSubmit()
    }
  }

  writeBounds(result) {
    const form = this.element.closest("form")
    if (!form) return

    ;["north", "south", "east", "west"].forEach((key) => {
      const field = form.querySelector(`[name="${key}"]`)
      if (field && result[key] != null) field.value = result[key]
    })
  }

  moveActive(delta) {
    if (!this.results.length) return
    this.activeIndex = (this.activeIndex + delta + this.results.length) % this.results.length
    this.renderMenu()
  }

  showMenu() {
    if (!this.hasMenuTarget) return
    this.menuTarget.hidden = false
    this.menuTarget.classList.remove("hidden")
    this.menuTarget.setAttribute("data-open", "true")
  }

  hideMenu() {
    if (!this.hasMenuTarget) return
    this.menuTarget.hidden = true
    this.menuTarget.classList.add("hidden")
    this.menuTarget.removeAttribute("data-open")
    this.activeIndex = -1
  }

  menuOpen() {
    return this.hasMenuTarget && this.menuTarget.getAttribute("data-open") === "true"
  }

  escape(value) {
    return String(value)
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
  }
}
