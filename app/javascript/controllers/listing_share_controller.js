import { Controller } from "@hotwired/stimulus"

// Favorite heart + share icon strip used on listing show and lightbox media.
export default class extends Controller {
  static targets = ["note"]

  async share(event) {
    event.preventDefault()
    const url = event.currentTarget.dataset.shareUrl || window.location.href
    const title = event.currentTarget.dataset.shareTitle || "Property listing"

    try {
      if (navigator.share) {
        await navigator.share({ title, url })
        return
      }
      await navigator.clipboard.writeText(url)
      this.flashShare("Link copied")
    } catch (_) {
      this.flashShare("Couldn’t share")
    }
  }

  promptSignIn(event) {
    event.preventDefault()
    document.dispatchEvent(
      new CustomEvent("auth-modal:open", { detail: { mode: "login", intent: "save" } })
    )
  }

  flashShare(message) {
    if (!this.hasNoteTarget) return
    this.noteTarget.textContent = message
    this.noteTarget.classList.remove("hidden")
    window.clearTimeout(this._shareTimer)
    this._shareTimer = window.setTimeout(() => this.noteTarget.classList.add("hidden"), 1800)
  }
}
