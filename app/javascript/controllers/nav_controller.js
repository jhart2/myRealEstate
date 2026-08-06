import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["menu", "bar", "toggle"]

  toggle() {
    this.menuTarget.classList.toggle("hidden")
    if (this.hasToggleTarget) {
      const open = !this.menuTarget.classList.contains("hidden")
      this.toggleTarget.setAttribute("aria-expanded", open ? "true" : "false")
    }
  }
}
