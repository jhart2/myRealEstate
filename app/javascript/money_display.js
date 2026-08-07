// Client-side mirror of MoneyDisplay / FxRate for in-place currency updates.
const SYMBOLS = { TTD: "TT$", USD: "$", CAD: "C$" }

let config = {
  base: "TTD",
  default: "TTD",
  ratesToTtd: { TTD: 1, USD: 6.75, CAD: 5 }
}

export function configure(payload = {}) {
  if (!payload || typeof payload !== "object") return
  config = {
    base: String(payload.base || "TTD").toUpperCase(),
    default: String(payload.default || "TTD").toUpperCase(),
    ratesToTtd: { ...config.ratesToTtd, ...(payload.ratesToTtd || {}) }
  }
}

export function normalize(code) {
  const up = String(code || "").toUpperCase()
  return Object.prototype.hasOwnProperty.call(SYMBOLS, up) ? up : config.default
}

export function rateToTtd(currency) {
  const code = normalize(currency)
  const raw = config.ratesToTtd[code]
  const n = Number(raw)
  return Number.isFinite(n) && n > 0 ? n : 1
}

export function convertCents(cents, { to, from = config.base } = {}) {
  const fromCode = normalize(from)
  const toCode = normalize(to)
  const amount = Number(cents) || 0
  if (fromCode === toCode) return Math.round(amount)

  return Math.round((amount * rateToTtd(fromCode)) / rateToTtd(toCode))
}

export function symbol(currency) {
  return SYMBOLS[normalize(currency)] || "$"
}

function delimited(n) {
  return Math.trunc(n).toLocaleString("en-US")
}

export function format(cents, { currency = config.default, rent = false } = {}) {
  const converted = convertCents(cents, { to: currency })
  const body = `${symbol(currency)}${delimited(converted / 100)}`
  return rent ? `${body} / mo` : body
}

export function compact(cents, { currency = config.default, rent = false } = {}) {
  const converted = convertCents(cents, { to: currency })
  const dollars = converted / 100
  const sym = symbol(currency)

  if (rent) {
    return dollars >= 1000 ? `${sym}${(dollars / 1000).toFixed(1)}K` : `${sym}${Math.trunc(dollars)}`
  }
  if (dollars >= 1_000_000) {
    return `${sym}${(dollars / 1_000_000).toFixed(1)}M`
  }
  if (dollars >= 1000) {
    return `${sym}${Math.round(dollars / 1000)}K`
  }
  return `${sym}${Math.trunc(dollars)}`
}

export function perSqft(cents, sqft, { currency = config.default } = {}) {
  const area = Number(sqft) || 0
  const amount = Number(cents) || 0
  if (area <= 0 || amount <= 0) return ""

  const converted = convertCents(amount, { to: currency })
  const per = Math.round(converted / 100 / area)
  return `${symbol(currency)}${delimited(per)} price/sqft`
}

export function renderFromDataset(dataset, currency) {
  const cents = Number(dataset.moneyCents) || 0
  const formatName = dataset.moneyFormat || "full"
  const rent = dataset.moneyRent === "true" || dataset.moneyRent === "1"
  const sqft = dataset.moneySqft

  if (formatName === "compact") return compact(cents, { currency, rent })
  if (formatName === "per_sqft") return perSqft(cents, sqft, { currency })
  return format(cents, { currency, rent })
}

const MoneyDisplay = {
  configure,
  normalize,
  rateToTtd,
  convertCents,
  symbol,
  format,
  compact,
  perSqft,
  renderFromDataset
}

export default MoneyDisplay
