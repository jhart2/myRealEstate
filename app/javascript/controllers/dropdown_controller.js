import { Controller } from "@hotwired/stimulus"

// Simple actions menu (three-dot → Edit / Delete).
export default class extends Controller {
  static targets = ["menu", "button"]

  connect() {
    this.boundClose = this.closeOnOutside.bind(this)
    this.boundKey = this.closeOnEscape.bind(this)
  }

  disconnect() {
    this.#unbind()
  }

  toggle(event) {
    event.preventDefault()
    event.stopPropagation()
    if (this.menuTarget.hidden) {
      this.open()
    } else {
      this.close()
    }
  }

  open() {
    this.menuTarget.hidden = false
    this.buttonTarget.setAttribute("aria-expanded", "true")
    this.#bind()
  }

  close() {
    if (!this.hasMenuTarget) return
    this.menuTarget.hidden = true
    if (this.hasButtonTarget) this.buttonTarget.setAttribute("aria-expanded", "false")
    this.#unbind()
  }

  closeOnOutside(event) {
    if (!this.element.contains(event.target)) this.close()
  }

  closeOnEscape(event) {
    if (event.key === "Escape") this.close()
  }

  #bind() {
    document.addEventListener("click", this.boundClose)
    document.addEventListener("keydown", this.boundKey)
  }

  #unbind() {
    document.removeEventListener("click", this.boundClose)
    document.removeEventListener("keydown", this.boundKey)
  }
}
