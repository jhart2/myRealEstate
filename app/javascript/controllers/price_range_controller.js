import { Controller } from "@hotwired/stimulus"

// Dual price range with listing-density histogram (list price ↔ monthly payment estimate).
const LIST_STEPS = [
  0, 50000, 75000, 100000, 125000, 150000, 175000, 200000, 225000, 250000,
  275000, 300000, 325000, 350000, 375000, 400000, 425000, 450000, 475000, 500000,
  550000, 600000, 650000, 700000, 750000, 800000, 850000, 900000, 950000, 1000000,
  1100000, 1200000, 1300000, 1400000, 1500000, 1600000, 1700000, 1800000, 1900000, 2000000,
  2250000, 2500000, 2750000, 3000000, 3500000, 4000000, 4500000, 5000000,
  6000000, 7000000, 8000000, 9000000, 10000000
]

// Approximate monthly PI steps (20% down, 30y, 5.5%) — end = open-ended
const PAY_STEPS = [
  0, 200, 400, 600, 800, 1000, 1200, 1400, 1600, 1800, 2000,
  2200, 2400, 2600, 2800, 3000, 3500, 4000, 4500, 5000,
  5500, 6000, 6500, 7000, 7500, 8000, 9000, 10000, 12000, 14000, 16000, 18000, 20000, 25000, 30000
]

// Rough inverse of MortgageEstimate defaults for converting monthly → list dollars
const MONTHLY_RATE = 0.055 / 12
const TERM = 30 * 12
const DOWN = 0.2
const FACTOR = Math.pow(1 + MONTHLY_RATE, TERM)

export default class extends Controller {
  static targets = [
    "minRange", "maxRange", "fill", "minDisplay", "maxDisplay",
    "minHidden", "maxHidden", "listTab", "payTab", "hint", "histogram"
  ]

  static values = {
    min: { type: Number, default: 0 },
    max: { type: Number, default: -1 }, // -1 => open (10M+)
    buckets: { type: Number, default: 40 },
    maxDollars: { type: Number, default: 10_000_000 }
  }

  connect() {
    this.mode = "list"
    this.steps = LIST_STEPS
    this.minIndex = this.indexForList(this.minValue)
    this.maxIndex = this.maxValue < 0 ? this.steps.length - 1 : this.indexForList(this.maxValue)
    this.syncControls()
    this.fetchHistogram()
  }

  disconnect() {
    this._histogramAbort?.abort()
  }

  showList(event) {
    event.preventDefault()
    if (this.mode === "list") return
    this.mode = "list"
    this.steps = LIST_STEPS
    this.minIndex = this.indexForList(this.listMinDollars())
    this.maxIndex = this.isOpenMax() ? this.steps.length - 1 : this.indexForList(this.listMaxDollars())
    this.syncTab()
    this.syncControls()
  }

  showPayment(event) {
    event.preventDefault()
    if (this.mode === "payment") return
    const listMin = this.listMinDollars()
    const open = this.isOpenMax()
    const listMax = open ? null : this.listMaxDollars()
    this.mode = "payment"
    this.steps = PAY_STEPS
    this.minIndex = this.indexForPay(this.monthlyFromList(listMin))
    this.maxIndex = open ? this.steps.length - 1 : this.indexForPay(this.monthlyFromList(listMax))
    this.syncTab()
    this.syncControls()
  }

  onMinSlide() {
    this.minIndex = Math.min(Number(this.minRangeTarget.value), this.maxIndex)
    this.syncControls()
  }

  onMaxSlide() {
    this.maxIndex = Math.max(Number(this.maxRangeTarget.value), this.minIndex)
    this.syncControls()
  }

  onMinInput() {
    const parsed = this.parseDisplay(this.minDisplayTarget.value)
    if (parsed == null) return
    if (this.mode === "list") {
      this.minIndex = this.indexForList(parsed)
    } else {
      this.minIndex = this.indexForPay(parsed)
    }
    if (this.minIndex > this.maxIndex) this.maxIndex = this.minIndex
    this.syncControls()
  }

  onMaxInput() {
    const raw = this.maxDisplayTarget.value.trim().toLowerCase()
    if (raw.includes("+") || raw === "") {
      this.maxIndex = this.steps.length - 1
      this.syncControls()
      return
    }
    const parsed = this.parseDisplay(raw)
    if (parsed == null) return
    if (this.mode === "list") {
      this.maxIndex = this.indexForList(parsed)
    } else {
      this.maxIndex = this.indexForPay(parsed)
    }
    if (this.maxIndex < this.minIndex) this.minIndex = this.maxIndex
    this.syncControls()
  }

  syncTab() {
    this.listTabTarget.classList.toggle("is-active", this.mode === "list")
    this.payTabTarget.classList.toggle("is-active", this.mode === "payment")
    this.listTabTarget.setAttribute("aria-selected", this.mode === "list" ? "true" : "false")
    this.payTabTarget.setAttribute("aria-selected", this.mode === "payment" ? "true" : "false")
    if (this.hasHintTarget) {
      this.hintTarget.hidden = this.mode === "list"
    }
  }

  syncControls() {
    const last = this.steps.length - 1
    this.minIndex = Math.max(0, Math.min(this.minIndex, last))
    this.maxIndex = Math.max(0, Math.min(this.maxIndex, last))
    if (this.minIndex > this.maxIndex) this.minIndex = this.maxIndex

    this.minRangeTarget.max = last
    this.maxRangeTarget.max = last
    this.minRangeTarget.value = this.minIndex
    this.maxRangeTarget.value = this.maxIndex

    const openMax = this.maxIndex >= last
    const minVal = this.steps[this.minIndex]
    const maxVal = this.steps[this.maxIndex]

    this.minDisplayTarget.value = this.formatDisplay(minVal, false)
    this.maxDisplayTarget.value = openMax ? this.formatDisplay(maxVal, true) : this.formatDisplay(maxVal, false)

    // Always submit list-price dollars
    const listMin = this.mode === "list" ? minVal : this.listFromMonthly(minVal)
    const listMax = openMax ? "" : (this.mode === "list" ? maxVal : this.listFromMonthly(maxVal))
    this.minHiddenTarget.value = listMin > 0 ? String(listMin) : ""
    this.maxHiddenTarget.value = listMax === "" ? "" : String(listMax)

    this.minRangeTarget.setAttribute("aria-valuetext", this.minDisplayTarget.value)
    this.maxRangeTarget.setAttribute("aria-valuetext", this.maxDisplayTarget.value)

    const span = last || 1
    const left = (this.minIndex / span) * 100
    const right = (this.maxIndex / span) * 100
    this.fillTarget.style.left = `${left}%`
    this.fillTarget.style.width = `${Math.max(right - left, 0)}%`

    this.syncHistogram(listMin, openMax ? null : Number(listMax))
  }

  syncHistogram(listMin, listMax) {
    if (!this.hasHistogramTarget) return

    const buckets = Math.max(1, this.bucketsValue || this.histogramTarget.children.length)
    const maxDollars = this.maxDollarsValue || 10_000_000
    const width = maxDollars / buckets
    const selectedMin = Number(listMin) || 0
    const openMax = listMax == null
    const selectedMax = openMax ? maxDollars : Number(listMax)

    Array.from(this.histogramTarget.children).forEach((bar, index) => {
      const bucketStart = index * width
      const bucketEnd = (index + 1) * width
      const inRange = bucketEnd > selectedMin && (openMax || bucketStart <= selectedMax)
      bar.classList.toggle("is-in-range", inRange)
    })
  }

  async fetchHistogram() {
    if (!this.hasHistogramTarget) return

    this._histogramAbort?.abort()
    this._histogramAbort = new AbortController()
    const { signal } = this._histogramAbort

    try {
      const response = await fetch(this.histogramUrl(), {
        headers: { Accept: "application/json" },
        credentials: "same-origin",
        signal
      })
      if (!response.ok) throw new Error(`price_histogram HTTP ${response.status}`)
      const data = await response.json()
      if (signal.aborted) return

      const buckets = Array.isArray(data.buckets) ? data.buckets : []
      if (Number.isFinite(data.bucketCount)) this.bucketsValue = Number(data.bucketCount)
      if (Number.isFinite(data.maxDollars)) this.maxDollarsValue = Number(data.maxDollars)
      this.renderHistogramBars(buckets)
      this.syncHistogram(this.listMinDollars(), this.isOpenMax() ? null : this.listMaxDollars())
    } catch (error) {
      if (error?.name === "AbortError") return
      console.error("Price histogram failed", error)
      this.histogramTarget.classList.remove("is-loading")
    }
  }

  histogramUrl() {
    const params = new URLSearchParams()
    const form = this.element.closest("form")
    if (form) {
      const formData = new FormData(form)
      for (const [key, value] of formData.entries()) {
        if (value == null || String(value).trim() === "") continue
        // Server ignores price filters; skip noisy extras that change with the slider.
        if (key === "price_min" || key === "price_max" || key === "budget") continue
        params.append(key, value)
      }
    }
    const query = params.toString()
    return query ? `/properties/price_histogram?${query}` : "/properties/price_histogram"
  }

  renderHistogramBars(counts) {
    if (!this.hasHistogramTarget) return

    const buckets = Math.max(counts.length, this.bucketsValue || 1)
    const values = Array.from({ length: buckets }, (_, i) => Number(counts[i]) || 0)
    const maxCount = Math.max(...values, 1)

    this.histogramTarget.innerHTML = values.map((count, index) => {
      const height = Math.round((count / maxCount) * 1000) / 10
      const barHeight = Math.max(height, count > 0 ? 6 : 0)
      const label = `${count} listing${count === 1 ? "" : "s"}`
      return `<span class="price-range-bar" style="--bar-height: ${barHeight}%" data-bucket-index="${index}" title="${label}"></span>`
    }).join("")

    this.histogramTarget.classList.remove("is-loading")
  }

  listMinDollars() {
    return Number(this.minHiddenTarget.value || 0)
  }

  listMaxDollars() {
    return Number(this.maxHiddenTarget.value || 0)
  }

  isOpenMax() {
    return !this.maxHiddenTarget.value
  }

  monthlyFromList(dollars) {
    const price = Number(dollars) || 0
    if (price <= 0) return 0
    const loan = price * (1 - DOWN)
    const payment = loan * MONTHLY_RATE * FACTOR / (FACTOR - 1)
    return Math.round(payment)
  }

  listFromMonthly(monthly) {
    const payment = Number(monthly) || 0
    if (payment <= 0) return 0
    const loan = payment * (FACTOR - 1) / (MONTHLY_RATE * FACTOR)
    return Math.round(loan / (1 - DOWN))
  }

  indexForList(dollars) {
    return this.nearestIndex(LIST_STEPS, Number(dollars) || 0)
  }

  indexForPay(monthly) {
    return this.nearestIndex(PAY_STEPS, Number(monthly) || 0)
  }

  nearestIndex(steps, value) {
    let best = 0
    let bestDiff = Infinity
    steps.forEach((step, i) => {
      const diff = Math.abs(step - value)
      if (diff < bestDiff) {
        bestDiff = diff
        best = i
      }
    })
    return best
  }

  parseDisplay(text) {
    const cleaned = String(text).replace(/[$,\s]/g, "").toLowerCase()
    if (!cleaned || cleaned === "any") return 0
    const body = cleaned.replace(/\+$/, "")
    let n
    if (body.endsWith("m")) n = parseFloat(body) * 1_000_000
    else if (body.endsWith("k")) n = parseFloat(body) * 1_000
    else n = parseFloat(body)
    if (Number.isNaN(n)) return null
    return n
  }

  formatDisplay(value, openEnded) {
    if (this.mode === "payment") {
      if (openEnded) return `$${this.group(value)}+/mo`
      if (value <= 0) return "$0/mo"
      return `$${this.group(value)}/mo`
    }
    if (openEnded) return this.shortMoney(value) + "+"
    if (value <= 0) return "$0"
    return this.shortMoney(value)
  }

  shortMoney(n) {
    if (n >= 1_000_000) {
      const v = n / 1_000_000
      return `$${(v % 1 === 0 ? v.toFixed(0) : v.toFixed(1))}M`
    }
    if (n >= 1_000) return `$${Math.round(n / 1000)}K`
    return `$${this.group(n)}`
  }

  group(n) {
    return Math.round(n).toLocaleString("en-US")
  }
}
