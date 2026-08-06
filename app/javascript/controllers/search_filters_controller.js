import { Controller } from "@hotwired/stimulus"

// Zillow-style exposed filter chips → dropdown panels.
export default class extends Controller {
  static targets = ["panel", "chip", "locationInput", "clearBtn"]

  connect() {
    this.onDocClick = this.onDocClick.bind(this)
    document.addEventListener("click", this.onDocClick)
    this.syncClearBtn()
  }

  disconnect() {
    document.removeEventListener("click", this.onDocClick)
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
    const form = event.currentTarget.form || this.element.querySelector("form")
    this.closeAll()
    form?.requestSubmit()
  }

  resetAll(event) {
    event.preventDefault()
    event.stopPropagation()

    const form = this.element.querySelector("form")
    if (!form) return

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
    this.syncClearBtn()
    this.locationInputTarget.focus()
  }

  async setCurrency(event) {
    event.preventDefault()
    event.stopPropagation()
    const currency = event.currentTarget.dataset.currency
    if (!currency) return

    const token = document.querySelector('meta[name="csrf-token"]')?.content
    try {
      await fetch("/currency", {
        method: "PATCH",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8",
          "X-CSRF-Token": token || "",
          Accept: "application/json, text/html"
        },
        body: new URLSearchParams({ currency }),
        credentials: "same-origin"
      })
    } catch (_) {
      // Still reload — cookie may have been set on a partial response.
    }

    this.closeAll()
    if (window.Turbo) {
      window.Turbo.visit(window.location.href, { action: "replace" })
    } else {
      window.location.reload()
    }
  }
}
