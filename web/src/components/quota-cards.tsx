import { type ReactNode } from 'react'
import { BALANCE_KINDS, type BalanceStatus, type Credential, type PlanStatus } from '@/lib/api'
import { fmtMoney, PLAN_KINDS } from '@/lib/quota'
import { fmtTime, fmtUntil } from '@/lib/format'
import { cn } from '@/lib/utils'
import { t, tk } from '@/i18n'
import { Badge } from '@/components/ui/badge'
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip'
import { Meter } from '@/components/meter'
import { VendorLogo } from '@/components/vendor-logo'

const PLAN_STATE = {
  normal: { label: tk('正常'), variant: 'success' },
  reserve: { label: tk('保留'), variant: 'warning' },
  exhausted: { label: tk('已用尽'), variant: 'danger' },
} as const

function CardShell({ cred, title, aside, children, alert }: {
  cred: Pick<Credential, 'name' | 'provider' | 'base_url'>
  title?: string
  aside?: ReactNode
  children: ReactNode
  alert?: boolean
}) {
  return (
    <div className={cn('rounded-xl border bg-card px-5 py-4', alert && 'border-destructive/60')}>
      <div className='flex items-center gap-2'>
        <VendorLogo hints={[cred.provider, cred.base_url, cred.name]} className='size-[18px]' />
        <span className='truncate font-semibold'>{title ?? cred.name}</span>
        <span className='ms-auto shrink-0'>{aside}</span>
      </div>
      {children}
    </div>
  )
}

/** 订阅套餐：每个窗口的已用比例与重置倒计时 */
export function PlanCard({ cred, status }: { cred: Pick<Credential, 'name' | 'provider' | 'base_url'>; status: PlanStatus }) {
  const s = PLAN_STATE[status.state]
  const windows = status.windows ?? []
  return (
    <CardShell cred={cred} aside={<Badge variant={status.error ? 'danger' : s.variant}>{status.error ? t('查询失败') : t(s.label)}</Badge>}>
      <div className='mt-0.5 text-xs text-muted-foreground'>
        {t(PLAN_KINDS[status.kind] ?? status.kind)}{status.level && ` · ${status.level}`}
      </div>
      <div className='mt-3 grid gap-2.5'>
        {windows.map((w) => (
          <Tooltip key={w.name}>
            <TooltipTrigger asChild>
              <div>
                <div className='mb-1 flex justify-between text-xs'>
                  <span><span className='text-subtle-foreground'>{w.name}</span> <span className='num font-medium'>{Math.round(w.used_pct)}%</span></span>
                  <span className='text-muted-foreground'>{t('{time}后重置', { time: fmtUntil(w.resets_at) })}</span>
                </div>
                <Meter pct={w.used_pct} warnAt={100 - status.reserve_pct} />
              </div>
            </TooltipTrigger>
            <TooltipContent>{t('重置于 {time}', { time: fmtTime(w.resets_at) })}</TooltipContent>
          </Tooltip>
        ))}
        {windows.length === 0 && (
          <p className={cn('text-xs', status.error ? 'text-destructive' : 'text-muted-foreground')}>
            {status.error ? t('查询失败：{error}', { error: status.error }) : t('尚未查询')}
          </p>
        )}
      </div>
    </CardShell>
  )
}

/** 按量付费余额 */
export function BalanceCard({ cred, status }: { cred: Pick<Credential, 'name' | 'provider' | 'base_url'>; status: BalanceStatus }) {
  const low = status.amount !== null && status.alert_below !== null && status.amount < status.alert_below
  return (
    <CardShell cred={cred} alert={low} aside={<span className='text-xs text-muted-foreground'>{t(BALANCE_KINDS[status.kind] ?? status.kind)}</span>}>
      <div className='mt-3 flex items-end justify-between gap-2'>
        <span className='text-xs text-muted-foreground'>{t('余额')}</span>
        <span className={cn('num text-2xl font-semibold tracking-tight', low && 'text-destructive')}>{fmtMoney(status.amount, status.currency)}</span>
      </div>
      {status.details.length > 1 && (
        <div className='mt-0.5 text-end text-xs text-muted-foreground'>{status.details.map((d) => fmtMoney(d.amount, d.currency)).join(' · ')}</div>
      )}
      <p className={cn('mt-1 text-xs', status.error ? 'text-destructive' : 'text-muted-foreground')}>
        {status.error ? t('查询失败：{error}', { error: status.error }) : status.fetched_at ? t('查询于 {time}', { time: fmtTime(status.fetched_at) }) : t('尚未查询')}
        {low && t('，低于告警线 {n}', { n: status.alert_below ?? '' })}
      </p>
    </CardShell>
  )
}
