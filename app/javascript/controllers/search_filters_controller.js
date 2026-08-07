import { Controller } from "@hotwired/stimulus"

// Zillow-style exposed filter chips → dropdown panels.
// Also persists listing filters (not location/map bounds) in localStorage so
// changing area keeps intent, price, beds, etc.
const FILTER_STORAGE_KEY = "tt-realty-search-filters"
const SCALAR_FILTER_KEYS = [
  "intent", "budget", "price_min", "price_max", "beds", "baths",
  "sort", "sqft_min", "sqft_max", "acres_min", "days_max", "featured", "property_type"
]
const ARRAY_FILTER_KEYS = ["property_types[]"]

export default class extends Controller {
  static targets = ["panel", "chip", "locationInput", "clearBtn", "currencyLabel", "intentLabel"]

  connect() {
    this.onDocClick = this.onDocClick.bind(this)
    this.onSubmit = this.onSubmit.bind(this)
    document.addEventListener("click", this.onDocClick)

    this.form = this.element.querySelector('form[action*="properties"]') || this.element.querySelector("form")
    this.form?.addEventListener("submit", this.onSubmit)

    if (this.restoreStoredFiltersIfNeeded()) return

    this.persistFiltersFromUrl()
    this.syncClearBtn()
  }

  disconnect() {
    document.removeEventListener("click", this.onDocClick)
    this.form?.removeEventListener("submit", this.onSubmit)
  }

  toggle(event) {
    event.preventDefault()
    event.stopPropagation()
    const name = event.currentTarget.dataset.panel
    if (!name) return

    const alreadyOpen = event.currentTarget.classList.contains("is-open")
    this.closeAll()
    if (alreadyOpen) return

    event.currentTarget.classList.add("is-open")
    event.currentTarget.setAttribute("aria-expanded", "true")
    this.panelTargets.forEach((panel) => {
      panel.classList.toggle("hidden", panel.dataset.panel !== name)
    })
  }

  closeAll(event) {
    if (event) event.stopPropagation?.()
    this.chipTargets.forEach((chip) => {
      chip.classList.remove("is-open")
      chip.setAttribute("aria-expanded", "false")
    })
    this.panelTargets.forEach((panel) => panel.classList.add("hidden"))
  }

  onDocClick(event) {
    if (this.element.contains(event.target)) return
    this.closeAll()
  }

  applyAndClose(event) {
    const form = event.currentTarget.form || this.form
    this.closeAll()
    form?.requestSubmit()
  }

  resetAll(event) {
    event.preventDefault()
    event.stopPropagation()

    const form = this.form
    if (!form) return

    this.clearStoredFilters()

    const params = new URLSearchParams()
    const location = form.querySelector('[name="location"]')?.value?.trim()
    if (location) params.set("location", location)

    ;["north", "south", "east", "west"].forEach((key) => {
      const value = form.querySelector(`[name="${key}"]`)?.value?.trim()
      if (value) params.set(key, value)
    })

    const query = params.toString()
    window.location.assign(query ? `${form.action}?${query}` : form.action)
  }

  onLocationInput() {
    this.syncClearBtn()
  }

  syncClearBtn() {
    if (!this.hasClearBtnTarget || !this.hasLocationInputTarget) return
    this.clearBtnTarget.classList.toggle("is-visible", this.locationInputTarget.value.trim().length > 0)
  }

  clearLocation(event) {
    event.preventDefault()
    if (!this.hasLocationInputTarget) return

    this.locationInputTarget.value = ""
    this.clearAreaBounds()
    this.syncClearBtn()

    // Re-run search island-wide (keeps intent/price/etc. from the form).
    const form = this.form || this.locationInputTarget.form
    form?.requestSubmit()
  }

  clearAreaBounds() {
    const form = this.form || this.element.querySelector("form")
    if (!form) return

    ;["north", "south", "east", "west", "region"].forEach((key) => {
      const field = form.querySelector(`[name="${key}"]`)
      if (field) field.value = ""
    })
  }

  onSubmit(event) {
    const form = event.target
    if (!(form instanceof HTMLFormElement)) return
    this.saveFiltersFromForm(form)
  }

  // —— localStorage persistence ——————————————————————————————

  restoreStoredFiltersIfNeeded() {
    if (typeof window === "undefined" || !window.localStorage) return false

    const url = new URL(window.location.href)
    if (!/^\/properties\/?$/.test(url.pathname)) return false

    // Bare /properties is a blank slate (e.g. Clear search) — don't resurrect filters.
    if (![...url.searchParams.keys()].length) return false

    const stored = this.readStoredFilters()
    if (!stored || !Object.keys(stored).length) return false

    let changed = false

    SCALAR_FILTER_KEYS.forEach((key) => {
      const value = stored[key]
      if (value == null || value === "") return
      if (url.searchParams.has(key)) return
      url.searchParams.set(key, String(value))
      changed = true
    })

    ARRAY_FILTER_KEYS.forEach((key) => {
      const values = stored[key]
      if (!Array.isArray(values) || !values.length) return
      if (url.searchParams.has(key) || url.searchParams.has("property_types")) return
      values.forEach((value) => url.searchParams.append(key, value))
      changed = true
    })

    if (!changed) return false

    window.location.replace(url.toString())
    return true
  }

  persistFiltersFromUrl() {
    if (typeof window === "undefined" || !window.localStorage) return

    const url = new URL(window.location.href)
    if (!/^\/properties\/?$/.test(url.pathname)) return

    const stored = this.readStoredFilters() || {}
    let touched = false

    SCALAR_FILTER_KEYS.forEach((key) => {
      if (!url.searchParams.has(key)) return
      stored[key] = url.searchParams.get(key)
      touched = true
    })

    ARRAY_FILTER_KEYS.forEach((key) => {
      if (!url.searchParams.has(key) && !url.searchParams.has("property_types")) return
      const values = [
        ...url.searchParams.getAll(key),
        ...url.searchParams.getAll("property_types")
      ].filter(Boolean)
      stored[key] = values
      touched = true
    })

    // URL listed filters with empty / absent pairs after an explicit submit:
    // mirror removals when the request clearly carried filter state (has filter keys
    // or area-only after we already saved on submit — submit path replaces wholesale).
    if (touched) this.writeStoredFilters(this.pruneEmpty(stored))
  }

  saveFiltersFromForm(form) {
    const data = new FormData(form)
    const stored = {}

    SCALAR_FILTER_KEYS.forEach((key) => {
      const value = data.get(key)
      if (value == null) return
      const text = String(value).trim()
      if (text === "") return
      stored[key] = text
    })

    const types = data.getAll("property_types[]").map(String).filter(Boolean)
    if (types.length) stored["property_types[]"] = types

    this.writeStoredFilters(stored)
  }

  readStoredFilters() {
    try {
      const raw = window.localStorage.getItem(FILTER_STORAGE_KEY)
      if (!raw) return null
      const parsed = JSON.parse(raw)
      if (!parsed || typeof parsed !== "object") return null
      return parsed
    } catch (_) {
      return null
    }
  }

  writeStoredFilters(filters) {
    try {
      window.localStorage.setItem(FILTER_STORAGE_KEY, JSON.stringify(filters))
    } catch (_) { /* quota / private mode */ }
  }

  clearStoredFilters() {
    try {
      window.localStorage.removeItem(FILTER_STORAGE_KEY)
    } catch (_) { /* ignore */ }
  }

  pruneEmpty(filters) {
    const next = {}
    Object.entries(filters).forEach(([key, value]) => {
      if (Array.isArray(value)) {
        if (value.length) next[key] = value
        return
      }
      if (value != null && String(value) !== "") next[key] = value
    })
    return next
  }

  async setCurrency(event) {
    event.preventDefault()
    event.stopPropagation()
    const currency = event.currentTarget.dataset.currency
    if (!currency) return

    const currencyCtrl = this.application.getControllerForElementAndIdentifier(
      document.body,
      "currency"
    )
    if (currencyCtrl) {
      await currencyCtrl.setCurrency(currency)
    } else {
      const token = document.querySelector('meta[name="csrf-token"]')?.content
      try {
        await fetch("/currency", {
          method: "PATCH",
          headers: {
            "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8",
            "X-CSRF-Token": token || "",
            Accept: "application/json"
          },
          body: new URLSearchParams({ currency }),
          credentials: "same-origin"
        })
      } catch (_) { /* ignore */ }
      document.dispatchEvent(new CustomEvent("currency:changed", {
        detail: { currency },
        bubbles: true
      }))
    }

    this.syncCurrencyUi(currency)
    this.closeAll()
  }

  syncCurrencyUi(currency) {
    if (this.hasCurrencyLabelTarget) {
      this.currencyLabelTarget.textContent = currency
    }

    this.chipTargets.forEach((chip) => {
      if (chip.dataset.panel !== "currency") return
      chip.setAttribute("aria-label", `Display currency ${currency}`)
      const defaultCode = document.body.dataset.currencyDefaultCodeValue || "TTD"
      chip.classList.toggle("is-active", currency !== defaultCode)
    })

    this.element.querySelectorAll('[data-panel="currency"] [data-currency]').forEach((btn) => {
      const selected = btn.dataset.currency === currency
      btn.classList.toggle("is-selected", selected)
      btn.setAttribute("aria-checked", selected ? "true" : "false")
    })
  }
}
