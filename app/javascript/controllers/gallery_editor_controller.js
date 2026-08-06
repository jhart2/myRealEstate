import { Controller } from "@hotwired/stimulus"

// Admin property gallery: reorder, remove, set cover (no URL entry).
export default class extends Controller {
  static targets = ["list", "item", "coverField", "empty"]

  connect() {
    this.sync()
  }

  remove(event) {
    event.preventDefault()
    event.currentTarget.closest("[data-gallery-editor-target='item']")?.remove()
    const urls = this.#urls()
    if (urls.length && !this.#cover()) this.#setCover(urls[0])
    this.sync()
  }

  setCover(event) {
    event.preventDefault()
    const item = event.currentTarget.closest("[data-gallery-editor-target='item']")
    const url = item?.dataset.url
    if (!url) return
    this.#setCover(url)
    this.sync()
  }

  moveLeft(event) {
    event.preventDefault()
    const item = event.currentTarget.closest("[data-gallery-editor-target='item']")
    const prev = item?.previousElementSibling
    if (item && prev) {
      this.listTarget.insertBefore(item, prev)
      this.sync()
    }
  }

  moveRight(event) {
    event.preventDefault()
    const item = event.currentTarget.closest("[data-gallery-editor-target='item']")
    const next = item?.nextElementSibling
    if (item && next) {
      this.listTarget.insertBefore(next, item)
      this.sync()
    }
  }

  sync() {
    const cover = this.#cover()
    if (this.hasCoverFieldTarget) this.coverFieldTarget.value = cover || ""

    this.itemTargets.forEach((item, index) => {
      const url = item.dataset.url
      const isCover = url === cover
      item.querySelector("[data-role='cover-badge']")?.classList.toggle("hidden", !isCover)
      item.querySelector("[data-role='set-cover']")?.classList.toggle("hidden", isCover)
      const urlField = item.querySelector("[data-role='url-field']")
      if (urlField) urlField.value = url
      item.querySelector("[data-role='move-left']")?.toggleAttribute("disabled", index === 0)
      item.querySelector("[data-role='move-right']")?.toggleAttribute("disabled", index === this.itemTargets.length - 1)
    })

    if (this.hasEmptyTarget) {
      this.emptyTarget.classList.toggle("hidden", this.itemTargets.length > 0)
    }
  }

  #urls() {
    return this.itemTargets.map((el) => el.dataset.url).filter(Boolean)
  }

  #cover() {
    const marked = this.itemTargets.find((item) => item.dataset.cover === "true")
    return marked?.dataset.url || this.#urls()[0] || ""
  }

  #setCover(url) {
    this.itemTargets.forEach((item) => {
      item.dataset.cover = item.dataset.url === url ? "true" : "false"
    })
  }
}
