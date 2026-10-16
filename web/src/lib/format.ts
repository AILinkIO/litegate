// 展示格式化
export function fmtTime(ms: number | null | undefined) {
  if (!ms) return '—'
  return new Date(ms).toLocaleString('zh-CN', { hour12: false })
}

export function fmtInt(n: number | null | undefined) {
  return (n ?? 0).toLocaleString()
}

export function fmtTokens(n: number | null | undefined) {
  const v = n ?? 0
  if (v >= 1e9) return `${(v / 1e9).toFixed(2)}B`
  if (v >= 1e6) return `${(v / 1e6).toFixed(2)}M`
  if (v >= 1e4) return `${(v / 1e3).toFixed(1)}K`
  return v.toLocaleString()
}

export function fmtCost(n: number | null | undefined) {
  const v = n ?? 0
  if (v === 0) return '$0'
  const s = v < 0.01 ? v.toFixed(5) : v.toFixed(v < 100 ? 3 : 2)
  // 去掉末尾多余的 0：$10.000 → $10，$0.250 → $0.25
  return `$${s.replace(/\.?0+$/, '')}`
}

export function fmtMs(ms: number | null | undefined) {
  const v = ms ?? 0
  return v >= 1000 ? `${(v / 1000).toFixed(2)}s` : `${v}ms`
}

// 每百万 token 价格
export function fmtPrice(n: number | null | undefined) {
  return n === undefined || n === null ? '—' : `$${n}`
}

// 本地时区某天零点
export function localDayStart(ms: number) {
  const d = new Date(ms)
  d.setHours(0, 0, 0, 0)
  return d.getTime()
}

// 今天的本地零点（默认参数惰性求值，避免在渲染期直接调 Date.now）
export function todayStart(now = Date.now()) {
  return localDayStart(now)
}

export function fmtBytes(n: number) {
  if (n >= 1 << 30) return `${(n / (1 << 30)).toFixed(2)} GB`
  if (n >= 1 << 20) return `${(n / (1 << 20)).toFixed(1)} MB`
  if (n >= 1 << 10) return `${(n / (1 << 10)).toFixed(1)} KB`
  return `${n} B`
}

// 距某时刻的剩余时长：2天3小时 / 3小时20分 / 12分
export function fmtUntil(ms: number | null | undefined, now = Date.now()) {
  if (!ms) return '—'
  const m = Math.max(0, Math.round((ms - now) / 60000))
  if (m >= 1440) return `${Math.floor(m / 1440)}天${Math.floor((m % 1440) / 60)}小时`
  if (m >= 60) return `${Math.floor(m / 60)}小时${m % 60}分`
  return `${m}分`
}
