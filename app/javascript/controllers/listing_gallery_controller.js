import { Controller } from "@hotwired/stimulus"

// Desktop mosaic preview + mobile full-bleed slideshow + full photo viewer.
export default class extends Controller {
  static targets = [
    "hero",
    "thumb",
    "counter",
    "viewer",
    "tile",
    "track",
    "slide",
    "dot",
    "mobileCounter"
  ]
  static values = {
    index: { type: Number, default: 0 },
    count: { type: Number, default: 0 }
  }

  connect() {
    this._onDocKey = this.onKeydown.bind(this)
    this._pointerX = 0
    this._swipeStartIndex = 0
    this._scrollRaf = null
    this._wrapping = false
  }

  disconnect() {
    document.removeEventListener("keydown", this._onDocKey)
    if (this._scrollRaf) cancelAnimationFrame(this._scrollRaf)
    this.unlockScroll()
  }

  openViewer(event) {
    event.preventDefault()
    const index = Number(event.currentTarget.dataset.index || 0)
    this.openAt(Number.isNaN(index) ? 0 : index)
  }

  openAllPhotos(event) {
    event.preventDefault()
    this.openAt(this.currentMobileIndex())
  }

  onSlidePointerDown(event) {
    this._pointerX = event.clientX
    this._swipeStartIndex = this.currentMobileIndex()
  }

  onSlidePointerUp(event) {
    this.maybeWrapMobileSwipe(event.clientX)
  }

  onSlideClick(event) {
    // Ignore tap-to-open when the gesture was a horizontal swipe.
    if (Math.abs(event.clientX - this._pointerX) > 10) {
      event.preventDefault()
      return
    }
    this.openViewer(event)
  }

  openAt(index) {
    this.show(index)
    if (!this.hasViewerTarget) return

    this.viewerTarget.classList.remove("hidden")
    this.viewerTarget.setAttribute("aria-hidden", "false")
    document.addEventListener("keydown", this._onDocKey)
    this.lockScroll()
    window.requestAnimationFrame(() => {
      this.viewerTarget.classList.add("is-open")
    })
  }

  closeViewer(event) {
    event?.preventDefault?.()
    if (!this.hasViewerTarget) return

    this.viewerTarget.classList.remove("is-open")
    this.viewerTarget.setAttribute("aria-hidden", "true")
    document.removeEventListener("keydown", this._onDocKey)
    window.setTimeout(() => {
      this.viewerTarget.classList.add("hidden")
      this.unlockScroll()
    }, 160)
  }

  closeOnBackdrop(event) {
    if (event.target === this.viewerTarget) this.closeViewer(event)
  }

  stop(event) {
    event.stopPropagation()
  }

  onKeydown(event) {
    if (!this.hasViewerTarget || this.viewerTarget.classList.contains("hidden")) return
    if (event.key === "Escape") this.closeViewer(event)
    if (event.key === "ArrowRight") this.next(event)
    if (event.key === "ArrowLeft") this.prev(event)
  }

  select(event) {
    event.preventDefault()
    const index = Number(event.currentTarget.dataset.index)
    if (Number.isNaN(index)) return
    this.show(index)
  }

  next(event) {
    event?.preventDefault?.()
    const total = this.total()
    if (total < 2) return
    this.show((this.indexValue + 1) % total)
  }

  prev(event) {
    event?.preventDefault?.()
    const total = this.total()
    if (total < 2) return
    this.show((this.indexValue - 1 + total) % total)
  }

  onTrackScroll() {
    if (this._wrapping) return
    if (this._scrollRaf) cancelAnimationFrame(this._scrollRaf)
    this._scrollRaf = requestAnimationFrame(() => {
      this._scrollRaf = null
      const index = this.currentMobileIndex()
      this.indexValue = index
      this.syncMobileChrome(index)
    })
  }

  // At either end of the mobile banner, continue the swipe to wrap around.
  maybeWrapMobileSwipe(clientX) {
    const total = this.total()
    if (total < 2 || this._wrapping) return

    const dx = clientX - this._pointerX
    if (Math.abs(dx) < 40) return

    const start = this._swipeStartIndex
    const current = this.currentMobileIndex()
    const swipedNext = dx < 0
    const swipedPrev = dx > 0

    if (swipedNext && start >= total - 1 && current >= total - 1) {
      this.wrapMobileTo(0)
    } else if (swipedPrev && start <= 0 && current <= 0) {
      this.wrapMobileTo(total - 1)
    }
  }

  wrapMobileTo(index) {
    this._wrapping = true
    // Jump instantly so wrap doesn't animate through every intermediate slide.
    this.scrollToSlide(index, false)
    this.syncMobileChrome(index)
    this.indexValue = index
    window.setTimeout(() => {
      this._wrapping = false
    }, 50)
  }

  goToSlide(event) {
    event.preventDefault()
    const index = Number(event.currentTarget.dataset.index)
    if (Number.isNaN(index)) return
    this.scrollToSlide(index, true)
    this.syncMobileChrome(index)
    this.indexValue = index
  }

  show(index) {
    const thumbs = this.thumbTargets
    const total = this.total()
    if (total < 1) return

    const safe = ((index % total) + total) % total
    this.indexValue = safe

    const src =
      thumbs[safe]?.dataset?.src ||
      thumbs[safe]?.querySelector?.("img")?.src ||
      this.slideTargets[safe]?.dataset?.src ||
      this.tileTargets[safe]?.dataset?.src

    if (this.hasHeroTarget && src) {
      this.heroTarget.src = src
    }

    thumbs.forEach((el, i) => {
      el.classList.toggle("is-active", i === safe)
      el.setAttribute("aria-current", i === safe ? "true" : "false")
    })

    if (this.hasCounterTarget) {
      this.counterTarget.textContent = `${safe + 1} / ${total}`
    }

    const activeThumb = thumbs[safe]
    activeThumb?.scrollIntoView?.({ behavior: "smooth", inline: "center", block: "nearest" })

    this.scrollToSlide(safe, false)
    this.syncMobileChrome(safe)
  }

  currentMobileIndex() {
    if (!this.hasTrackTarget) return this.indexValue
    const track = this.trackTarget
    const width = track.clientWidth
    if (!width) return this.indexValue
    return Math.round(track.scrollLeft / width)
  }

  scrollToSlide(index, smooth) {
    if (!this.hasTrackTarget) return
    const track = this.trackTarget
    const width = track.clientWidth
    if (!width) return
    const left = index * width
    if (Math.abs(track.scrollLeft - left) < 2) return
    track.scrollTo({ left, behavior: smooth ? "smooth" : "auto" })
  }

  syncMobileChrome(index) {
    const total = this.total()
    const safe = total < 1 ? 0 : ((index % total) + total) % total

    this.dotTargets.forEach((el, i) => {
      const active = i === safe
      el.classList.toggle("is-active", active)
      el.setAttribute("aria-selected", active ? "true" : "false")
    })

    this.slideTargets.forEach((el, i) => {
      el.classList.toggle("is-active", i === safe)
    })

    if (this.hasMobileCounterTarget) {
      this.mobileCounterTarget.textContent = `${safe + 1} / ${total}`
    }
  }

  total() {
    return this.countValue || this.thumbTargets.length || this.slideTargets.length || this.tileTargets.length
  }

  lockScroll() {
    document.documentElement.classList.add("gallery-viewer-open")
  }

  unlockScroll() {
    document.documentElement.classList.remove("gallery-viewer-open")
  }
}
