import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "preview", "placeholder", "overlay", "meta", "dropzone", "clearButton", "removeField"]
  static values = { existingUrl: String }

  connect() {
    this.refresh(this.existingUrlValue || null)
  }

  open(event) {
    event.preventDefault()
    event.stopPropagation()
    this.inputTarget.click()
  }

  changed() {
    const file = this.inputTarget.files?.[0]
    if (!file) return
    this.showFile(file)
    this.setRemove(false)
  }

  dragover(event) {
    event.preventDefault()
    this.dropzoneTarget.classList.add("border-trinidad", "bg-stone-light/40")
  }

  dragleave(event) {
    event.preventDefault()
    this.dropzoneTarget.classList.remove("border-trinidad", "bg-stone-light/40")
  }

  drop(event) {
    event.preventDefault()
    this.dropzoneTarget.classList.remove("border-trinidad", "bg-stone-light/40")

    const file = event.dataTransfer?.files?.[0]
    if (!file || !file.type.startsWith("image/")) return

    const transfer = new DataTransfer()
    transfer.items.add(file)
    this.inputTarget.files = transfer.files
    this.showFile(file)
    this.setRemove(false)
  }

  clear(event) {
    event.preventDefault()
    event.stopPropagation()
    this.inputTarget.value = ""
    this.refresh(null)
    this.setRemove(true)
  }

  showFile(file) {
    const url = URL.createObjectURL(file)
    this.refresh(url, `${file.name} · ${this.humanSize(file.size)}`)
  }

  refresh(url, metaText = null) {
    if (url) {
      this.previewTarget.src = url
      this.previewTarget.hidden = false
      this.previewTarget.classList.remove("hidden")
      this.placeholderTarget.classList.add("hidden")
      this.overlayTarget.classList.remove("hidden")
      if (this.hasClearButtonTarget) this.clearButtonTarget.classList.remove("hidden")
    } else {
      this.previewTarget.removeAttribute("src")
      this.previewTarget.hidden = true
      this.previewTarget.classList.add("hidden")
      this.placeholderTarget.classList.remove("hidden")
      this.overlayTarget.classList.add("hidden")
      if (this.hasClearButtonTarget) this.clearButtonTarget.classList.add("hidden")
    }

    if (this.hasMetaTarget && metaText !== null) {
      this.metaTarget.textContent = metaText || "JPEG, PNG, or WebP · max 10MB"
    }
  }

  setRemove(value) {
    if (this.hasRemoveFieldTarget) this.removeFieldTarget.value = value ? "1" : "0"
  }

  humanSize(bytes) {
    if (bytes < 1024) return `${bytes} B`
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
  }
}
