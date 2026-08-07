import { Controller } from "@hotwired/stimulus"
import MoneyDisplay from "money_display"

// Persists display currency and reformats [data-money] nodes in place (no reload).
export default class extends Controller {
  static values = {
    code: String,
    rates: Object,
    defaultCode: { type: String, default: "TTD" }
  }

  connect() {
    MoneyDisplay.configure(this.ratesValue)
    this.applyDom(this.codeValue)
  }

  async setCurrency(code) {
    const next = MoneyDisplay.normalize(code)
    if (!next || next === this.codeValue) {
      this.applyDom(next)
      return next
    }

    const token = document.querySelector('meta[name="csrf-token"]')?.content
    try {
      await fetch("/currency", {
        method: "PATCH",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8",
          "X-CSRF-Token": token || "",
          Accept: "application/json"
        },
        body: new URLSearchParams({ currency: next }),
        credentials: "same-origin"
      })
    } catch (_) {
      // Cookie may still have been set; keep applying the chosen currency locally.
    }

    this.codeValue = next
    this.applyDom(next)
    document.dispatchEvent(new CustomEvent("currency:changed", {
      detail: { currency: next },
      bubbles: true
    }))
    return next
  }

  applyDom(code) {
    const currency = MoneyDisplay.normalize(code)
    document.querySelectorAll("[data-money]").forEach((el) => {
      el.textContent = MoneyDisplay.renderFromDataset(el.dataset, currency)
    })
  }
}
