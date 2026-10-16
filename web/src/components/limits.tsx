import { PERIOD_LABEL, type BudgetDraft, type LimitDraft } from '@/lib/limits'
import type { BudgetStatus } from '@/lib/api'
import { fmtCost, fmtTime } from '@/lib/format'
import { cn } from '@/lib/utils'
import { Input } from '@/components/ui/input'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Field } from '@/components/form-field'
import { Meter } from '@/components/meter'

export function LimitInputs({ value, onChange }: { value: LimitDraft; onChange: (v: LimitDraft) => void }) {
  const field = (k: keyof LimitDraft, label: string) => (
    <Field label={label}>
      <Input type='number' min={1} placeholder='不限' value={value[k]} onChange={(e) => onChange({ ...value, [k]: e.target.value })} />
    </Field>
  )
  return (
    <div className='grid grid-cols-3 gap-3'>
      {field('rpm', '每分钟请求')}
      {field('tpm', '每分钟 token')}
      {field('max_parallel', '最大并发')}
    </div>
  )
}

export function BudgetInputs({ value, onChange }: { value: BudgetDraft; onChange: (v: BudgetDraft) => void }) {
  return (
    <div className='grid grid-cols-3 gap-3'>
      <Field label='周期'>
        <Select value={value.period} onValueChange={(v) => onChange({ ...value, period: v as BudgetDraft['period'] })}>
          <SelectTrigger className='w-full'><SelectValue /></SelectTrigger>
          <SelectContent>
            {Object.entries(PERIOD_LABEL).map(([k, v]) => <SelectItem key={k} value={k}>{v}</SelectItem>)}
          </SelectContent>
        </Select>
      </Field>
      <Field label='上限（美元）' hint='周期按 UTC 计算；超出后返回 429 直到下个周期' className='col-span-2'>
        <Input type='number' min={0} placeholder='不限' value={value.max_usd} onChange={(e) => onChange({ ...value, max_usd: e.target.value })} />
      </Field>
    </div>
  )
}

const CURRENT = { day: '今日', week: '本周', month: '本月' }

export function BudgetBar({ budget, className }: { budget: BudgetStatus; className?: string }) {
  const pct = budget.max_usd > 0 ? (budget.spent_usd / budget.max_usd) * 100 : 100
  const over = budget.spent_usd >= budget.max_usd
  return (
    <div className={cn('min-w-36', className)} title={`重置于 ${fmtTime(budget.resets_at)}`}>
      <div className={cn('mb-1 text-xs', over ? 'text-destructive' : 'text-muted-foreground')}>
        {CURRENT[budget.period]} <span className='num'>{fmtCost(budget.spent_usd)} / {fmtCost(budget.max_usd)}</span>
      </div>
      <Meter pct={pct} />
    </div>
  )
}

