import { Controller } from "@hotwired/stimulus"

// Desktop mosaic preview + mobile full-bleed slideshow + full photo viewer.
// Mobile track and fullscreen viewer wrap (last ↔ first) via edge clones when 2+ photos.
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
    "mobileCounter",
    "viewerTrack",
    "viewerSlide"
  ]
  static values = {
    index: { type: Number, default: 0 },
    count: { type: Number, default: 0 },
    slug: { type: String, default: "listing" }
  }

  connect() {
    this._onDocKey = this.onKeydown.bind(this)
    this._pointerX = 0
    this._scrollRaf = null
    this._scrollEndTimer = null
    this._viewerScrollRaf = null
    this._viewerScrollEndTimer = null
    this._loopReady = false
    this._viewerLoopReady = false
    this._jumping = false
    this._viewerJumping = false
    this._onScrollEnd = () => this.correctLoopEdge()
    this._onViewerScrollEnd = () => this.correctViewerLoopEdge()

    this.setupMobileLoop()
    this.setupViewerLoop()
  }

  disconnect() {
    document.removeEventListener("keydown", this._onDocKey)
    if (this._scrollRaf) cancelAnimationFrame(this._scrollRaf)
    if (this._scrollEndTimer) clearTimeout(this._scrollEndTimer)
    if (this._viewerScrollRaf) cancelAnimationFrame(this._viewerScrollRaf)
    if (this._viewerScrollEndTimer) clearTimeout(this._viewerScrollEndTimer)
    if (this.hasTrackTarget && this._onScrollEnd) {
      this.trackTarget.removeEventListener("scrollend", this._onScrollEnd)
    }
    if (this.hasViewerTrackTarget && this._onViewerScrollEnd) {
      this.viewerTrackTarget.removeEventListener("scrollend", this._onViewerScrollEnd)
    }
    this.unlockScroll()
  }

  setupMobileLoop() {
    if (!this.hasTrackTarget) return
    this._loopReady = this.#setupLoopClones(this.trackTarget, this.slideTargets, this._onScrollEnd)
    if (!this._loopReady) return

    window.requestAnimationFrame(() => {
      this.jumpToLoopOffset(1)
      this.syncMobileChrome(0)
    })
  }

  setupViewerLoop() {
    if (!this.hasViewerTrackTarget) return
    this._viewerLoopReady = this.#setupLoopClones(
      this.viewerTrackTarget,
      this.viewerSlideTargets,
      this._onViewerScrollEnd
    )
  }

  #setupLoopClones(track, slides, onScrollEnd) {
    if (slides.length < 2) return false
    if (track.querySelector("[data-loop-clone]")) {
      track.addEventListener("scrollend", onScrollEnd)
      return true
    }

    const first = slides[0]
    const last = slides[slides.length - 1]

    const head = last.cloneNode(true)
    const tail = first.cloneNode(true)
    ;[head, tail].forEach((clone) => {
      clone.removeAttribute("data-listing-gallery-target")
      clone.classList.remove("is-active")
      clone.setAttribute("aria-hidden", "true")
      clone.tabIndex = -1
      clone.querySelectorAll("[data-listing-gallery-target]").forEach((el) => {
        el.removeAttribute("data-listing-gallery-target")
      })
    })
    head.dataset.loopClone = "head"
    head.dataset.index = String(slides.length - 1)
    tail.dataset.loopClone = "tail"
    tail.dataset.index = "0"

    track.insertBefore(head, first)
    track.appendChild(tail)
    track.addEventListener("scrollend", onScrollEnd)
    return true
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
    this.show(index, { smooth: false, syncViewer: false })
    if (!this.hasViewerTarget) return

    this.viewerTarget.classList.remove("hidden")
    this.viewerTarget.setAttribute("aria-hidden", "false")
    document.addEventListener("keydown", this._onDocKey)
    this.lockScroll()
    window.requestAnimationFrame(() => {
      this.viewerTarget.classList.add("is-open")
      this.scrollToViewerSlide(this.indexValue, false)
      window.requestAnimationFrame(() => this.scrollToViewerSlide(this.indexValue, false))
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
    this.show(index, { smooth: true })
  }

  next(event) {
    event?.preventDefault?.()
    const total = this.total()
    if (total < 2) return
    this.show((this.indexValue + 1) % total, { smooth: true })
  }

  prev(event) {
    event?.preventDefault?.()
    const total = this.total()
    if (total < 2) return
    this.show((this.indexValue - 1 + total) % total, { smooth: true })
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

    if (this._scrollEndTimer) clearTimeout(this._scrollEndTimer)
    this._scrollEndTimer = window.setTimeout(() => this.correctLoopEdge(), 90)
  }

  onViewerTrackScroll() {
    if (this._viewerJumping) return
    if (this._viewerScrollRaf) cancelAnimationFrame(this._viewerScrollRaf)
    this._viewerScrollRaf = requestAnimationFrame(() => {
      this._viewerScrollRaf = null
      const index = this.currentViewerIndex()
      this.indexValue = index
      this.syncViewerChrome(index)
      this.syncMobileChrome(index)
    })

    if (this._viewerScrollEndTimer) clearTimeout(this._viewerScrollEndTimer)
    this._viewerScrollEndTimer = window.setTimeout(() => this.correctViewerLoopEdge(), 90)
  }

  goToSlide(event) {
    event.preventDefault()
    const index = Number(event.currentTarget.dataset.index)
    if (Number.isNaN(index)) return
    this.scrollToSlide(index, true)
    this.syncMobileChrome(index)
    this.indexValue = index
  }

  show(index, { smooth = false, syncViewer = true } = {}) {
    const thumbs = this.thumbTargets
    const total = this.total()
    if (total < 1) return

    const safe = ((index % total) + total) % total
    this.indexValue = safe

    const src =
      thumbs[safe]?.dataset?.src ||
      thumbs[safe]?.querySelector?.("img")?.src ||
      this.viewerSlideTargets[safe]?.dataset?.src ||
      this.slideTargets[safe]?.dataset?.src ||
      this.tileTargets[safe]?.dataset?.src

    if (this.hasHeroTarget && src && !this.hasViewerSlideTarget) {
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
    if (syncViewer) this.scrollToViewerSlide(safe, smooth)
    this.syncMobileChrome(safe)
    this.syncViewerChrome(safe)
  }

  currentMobileIndex() {
    return this.#indexFromTrack(this.hasTrackTarget ? this.trackTarget : null, this._loopReady)
  }

  currentViewerIndex() {
    return this.#indexFromTrack(
      this.hasViewerTrackTarget ? this.viewerTrackTarget : null,
      this._viewerLoopReady
    )
  }

  #indexFromTrack(track, loopReady) {
    if (!track) return this.indexValue
    const width = track.clientWidth
    if (!width) return this.indexValue

    const raw = Math.round(track.scrollLeft / width)
    if (!loopReady) return raw

    const n = this.total()
    if (raw <= 0) return n - 1
    if (raw >= n + 1) return 0
    return raw - 1
  }

  scrollToSlide(index, smooth) {
    this.#scrollTrackToIndex(
      this.hasTrackTarget ? this.trackTarget : null,
      this._loopReady,
      index,
      smooth
    )
  }

  scrollToViewerSlide(index, smooth) {
    this.#scrollTrackToIndex(
      this.hasViewerTrackTarget ? this.viewerTrackTarget : null,
      this._viewerLoopReady,
      index,
      smooth
    )
  }

  #scrollTrackToIndex(track, loopReady, index, smooth) {
    if (!track) return
    const width = track.clientWidth
    if (!width) return

    const n = this.total()
    const target = loopReady ? index + 1 : index
    let left = target * width

    if (smooth && loopReady && n > 1) {
      const current = Math.round(track.scrollLeft / width)
      // Last → first: advance onto trailing clone, then snap.
      if (current === n && index === 0) {
        left = (n + 1) * width
      // First → last: back onto leading clone, then snap.
      } else if (current === 1 && index === n - 1) {
        left = 0
      }
    }

    if (Math.abs(track.scrollLeft - left) < 2) return
    track.scrollTo({ left, behavior: smooth ? "smooth" : "auto" })
  }

  correctLoopEdge() {
    this.#correctTrackLoopEdge(
      this.hasTrackTarget ? this.trackTarget : null,
      this._loopReady,
      () => this._jumping,
      (v) => { this._jumping = v },
      (offset) => this.jumpToLoopOffset(offset)
    )
  }

  correctViewerLoopEdge() {
    this.#correctTrackLoopEdge(
      this.hasViewerTrackTarget ? this.viewerTrackTarget : null,
      this._viewerLoopReady,
      () => this._viewerJumping,
      (v) => { this._viewerJumping = v },
      (offset) => this.jumpToViewerLoopOffset(offset)
    )
  }

  #correctTrackLoopEdge(track, loopReady, isJumping, setJumping, jump) {
    if (!loopReady || isJumping() || !track) return

    const width = track.clientWidth
    if (!width) return

    const raw = Math.round(track.scrollLeft / width)
    const n = this.total()
    if (raw <= 0) {
      jump(n)
    } else if (raw >= n + 1) {
      jump(1)
    }
  }

  jumpToLoopOffset(offset) {
    this.#jumpTrackToOffset(
      this.hasTrackTarget ? this.trackTarget : null,
      offset,
      (v) => { this._jumping = v },
      (index) => this.syncMobileChrome(index)
    )
  }

  jumpToViewerLoopOffset(offset) {
    this.#jumpTrackToOffset(
      this.hasViewerTrackTarget ? this.viewerTrackTarget : null,
      offset,
      (v) => { this._viewerJumping = v },
      (index) => {
        this.syncViewerChrome(index)
        this.syncMobileChrome(index)
      }
    )
  }

  #jumpTrackToOffset(track, offset, setJumping, syncChrome) {
    if (!track) return
    const width = track.clientWidth
    if (!width) return

    setJumping(true)
    track.scrollTo({ left: offset * width, behavior: "auto" })

    const n = this.total()
    const index = offset <= 0 ? n - 1 : offset >= n + 1 ? 0 : offset - 1
    this.indexValue = index
    syncChrome(index)

    window.requestAnimationFrame(() => {
      setJumping(false)
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

  syncViewerChrome(index) {
    const total = this.total()
    const safe = total < 1 ? 0 : ((index % total) + total) % total

    this.viewerSlideTargets.forEach((el, i) => {
      el.classList.toggle("is-active", i === safe)
    })

    this.thumbTargets.forEach((el, i) => {
      el.classList.toggle("is-active", i === safe)
      el.setAttribute("aria-current", i === safe ? "true" : "false")
    })

    if (this.hasCounterTarget) {
      this.counterTarget.textContent = `${safe + 1} / ${total}`
    }
  }

  total() {
    return this.countValue || this.thumbTargets.length || this.viewerSlideTargets.length || this.slideTargets.length || this.tileTargets.length
  }

  lockScroll() {
    document.documentElement.classList.add("gallery-viewer-open")
  }

  unlockScroll() {
    document.documentElement.classList.remove("gallery-viewer-open")
  }

  async downloadCurrent(event) {
    event?.preventDefault?.()
    const src =
      this.viewerSlideTargets[this.indexValue]?.dataset?.src ||
      this.thumbTargets[this.indexValue]?.dataset?.src ||
      this.slideTargets[this.indexValue]?.dataset?.src
    if (!src) return

    const filename = `${this.slugValue || "listing"}-${this.indexValue + 1}.jpg`

    try {
      const response = await fetch(src, { mode: "cors" })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      const blob = await response.blob()
      const objectUrl = URL.createObjectURL(blob)
      this.#triggerDownload(objectUrl, filename)
      window.setTimeout(() => URL.revokeObjectURL(objectUrl), 2_000)
    } catch (_) {
      // Cross-origin without CORS: open the asset so the user can save it.
      window.open(src, "_blank", "noopener")
    }
  }

  #triggerDownload(href, filename) {
    const link = document.createElement("a")
    link.href = href
    link.download = filename
    link.rel = "noopener"
    document.body.appendChild(link)
    link.click()
    link.remove()
  }
}
