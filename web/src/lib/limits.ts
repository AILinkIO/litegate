import { api, type BudgetStatus, type LimitScope, type LimitValues } from '@/lib/api'
import { fmtTokens } from '@/lib/format'

// 表单内以字符串保存，空串 = 不限
export interface LimitDraft { rpm: string; tpm: string; max_parallel: string }
export interface BudgetDraft { period: 'day' | 'week' | 'month'; max_usd: string }

const str = (n: number | null | undefined) => (n === null || n === undefined ? '' : String(n))
const num = (s: string) => (s.trim() === '' ? null : Number(s))

export const limitDraft = (l?: LimitValues | null): LimitDraft =>
  ({ rpm: str(l?.rpm), tpm: str(l?.tpm), max_parallel: str(l?.max_parallel) })

export const budgetDraft = (b?: BudgetStatus | null): BudgetDraft =>
  ({ period: b?.period ?? 'month', max_usd: str(b?.max_usd) })

export const limitValues = (d: LimitDraft): LimitValues =>
  ({ rpm: num(d.rpm), tpm: num(d.tpm), max_parallel: num(d.max_parallel) })

export function limitValid(d: LimitDraft) {
  return Object.values(d).every((v) => v.trim() === '' || (Number.isInteger(Number(v)) && Number(v) > 0))
}

export function budgetValid(d: BudgetDraft) {
  return d.max_usd.trim() === '' || Number(d.max_usd) >= 0
}

// 三项都为空时服务端删除该条限额
export const saveLimit = (scope: LimitScope, d: LimitDraft) =>
  api.put('/limits', { scope, ...limitValues(d) })

export const saveBudget = (scope: LimitScope, d: BudgetDraft) =>
  api.put('/budgets', { scope, period: d.period, max_usd: num(d.max_usd) })

export const PERIOD_LABEL = { day: '每天', week: '每周', month: '每月' } as const

export function limitSummary(l?: LimitValues | null) {
  if (!l) return null
  const parts = [
    l.rpm && `${l.rpm} RPM`,
    l.tpm && `${fmtTokens(l.tpm)} TPM`,
    l.max_parallel && `并发 ${l.max_parallel}`,
  ].filter(Boolean)
  return parts.length ? parts.join(' · ') : null
}
