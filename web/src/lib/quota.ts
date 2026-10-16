export const PLAN_KINDS = { minimax: 'MiniMax Token Plan', glm: '智谱 GLM Coding Plan', kimi: 'Kimi Code 会员' } as const

const SYMBOL: Record<string, string> = { CNY: '¥', USD: '$' }

export function fmtMoney(amount: number | null, currency: string | null): string {
  if (amount === null) return '—'
  const sym = currency ? SYMBOL[currency] : undefined
  const n = amount.toFixed(2)
  return sym ? `${sym}${n}` : `${n} ${currency ?? ''}`.trim()
}
