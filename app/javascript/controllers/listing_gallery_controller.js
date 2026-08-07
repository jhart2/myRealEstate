import { Controller } from "@hotwired/stimulus"

// Desktop mosaic preview + mobile full-bleed slideshow + full photo viewer.
// Mobile track wraps (last ↔ first) via edge clones when there are 2+ photos.
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
    this._scrollRaf = null
    this._scrollEndTimer = null
    this._loopReady = false
    this._jumping = false
    this._onScrollEnd = () => this.correctLoopEdge()

    this.setupMobileLoop()
  }

  disconnect() {
    document.removeEventListener("keydown", this._onDocKey)
    if (this._scrollRaf) cancelAnimationFrame(this._scrollRaf)
    if (this._scrollEndTimer) clearTimeout(this._scrollEndTimer)
    if (this.hasTrackTarget && this._onScrollEnd) {
      this.trackTarget.removeEventListener("scrollend", this._onScrollEnd)
    }
    this.unlockScroll()
  }

  setupMobileLoop() {
    if (!this.hasTrackTarget) return
    const slides = this.slideTargets
    if (slides.length < 2) return
    if (this.trackTarget.querySelector("[data-loop-clone]")) {
      this._loopReady = true
      return
    }

    const track = this.trackTarget
    const first = slides[0]
    const last = slides[slides.length - 1]

    const head = last.cloneNode(true)
    const tail = first.cloneNode(true)
    ;[head, tail].forEach((clone) => {
      clone.removeAttribute("data-listing-gallery-target")
      clone.classList.remove("is-active")
      clone.setAttribute("aria-hidden", "true")
      clone.tabIndex = -1
    })
    head.dataset.loopClone = "head"
    head.dataset.index = String(slides.length - 1)
    tail.dataset.loopClone = "tail"
    tail.dataset.index = "0"

    track.insertBefore(head, first)
    track.appendChild(tail)
    this._loopReady = true

    track.addEventListener("scrollend", this._onScrollEnd)

    // Start on the real first slide (offset 1 after the leading clone).
    window.requestAnimationFrame(() => {
      this.jumpToLoopOffset(1)
      this.syncMobileChrome(0)
    })
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
    if (this._jumping) return
    if (this._scrollRaf) cancelAnimationFrame(this._scrollRaf)
    this._scrollRaf = requestAnimationFrame(() => {
      this._scrollRaf = null
      const index = this.currentMobileIndex()
      this.indexValue = index
      this.syncMobileChrome(index)
    })

    // Fallback when scrollend is unavailable.
    if (this._scrollEndTimer) clearTimeout(this._scrollEndTimer)
    this._scrollEndTimer = window.setTimeout(() => this.correctLoopEdge(), 90)
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

    const raw = Math.round(track.scrollLeft / width)
    if (!this._loopReady) return raw

    const n = this.total()
    if (raw <= 0) return n - 1
    if (raw >= n + 1) return 0
    return raw - 1
  }

  scrollToSlide(index, smooth) {
    if (!this.hasTrackTarget) return
    const track = this.trackTarget
    const width = track.clientWidth
    if (!width) return

    const offset = this._loopReady ? index + 1 : index
    const left = offset * width
    if (Math.abs(track.scrollLeft - left) < 2) return
    track.scrollTo({ left, behavior: smooth ? "smooth" : "auto" })
  }

  correctLoopEdge() {
    if (!this._loopReady || this._jumping || !this.hasTrackTarget) return

    const track = this.trackTarget
    const width = track.clientWidth
    if (!width) return

    const raw = Math.round(track.scrollLeft / width)
    const n = this.total()
    if (raw <= 0) {
      this.jumpToLoopOffset(n)
    } else if (raw >= n + 1) {
      this.jumpToLoopOffset(1)
    }
  }

  jumpToLoopOffset(offset) {
    if (!this.hasTrackTarget) return
    const track = this.trackTarget
    const width = track.clientWidth
    if (!width) return

    this._jumping = true
    track.scrollTo({ left: offset * width, behavior: "auto" })

    const n = this.total()
    const index = offset <= 0 ? n - 1 : offset >= n + 1 ? 0 : offset - 1
    this.indexValue = index
    this.syncMobileChrome(index)

    window.requestAnimationFrame(() => {
      this._jumping = false
    })
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
