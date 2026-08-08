import { Controller } from "@hotwired/stimulus"

// Keeps the status LED in sync with the select value.
export default class extends Controller {
  static targets = ["led", "select"]
  static values = {
    classes: { type: Object, default: {
      active: "bg-emerald-500 shadow-[0_0_0_3px_rgba(16,185,129,0.22)]",
      pending: "bg-amber-400 shadow-[0_0_0_3px_rgba(251,191,36,0.25)]",
      sold: "bg-ink-3 shadow-[0_0_0_3px_rgba(138,127,120,0.2)]",
      rented: "bg-sky-500 shadow-[0_0_0_3px_rgba(14,165,233,0.2)]",
      disabled: "bg-red-400 shadow-[0_0_0_3px_rgba(248,113,113,0.25)]"
    }}
  }

  connect() {
    this.sync()
  }

  sync() {
    if (!this.hasLedTarget || !this.hasSelectTarget) return
    const status = this.selectTarget.value
    const next = this.classesValue[status] || "bg-ink-3"
    this.ledTarget.className = `inline-block h-2 w-2 shrink-0 rounded-full ${next}`
  }
}
