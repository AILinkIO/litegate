import { cn } from '@/lib/utils'

/** 细进度条：pct 为 0–100；tone 决定颜色，不给时按 warnAt / 100 自动变黄 / 红 */
export function Meter({ pct, warnAt = 80, tone, className }: {
  pct: number
  warnAt?: number
  tone?: 'primary' | 'warning' | 'danger' | 'muted'
  className?: string
}) {
  const t = tone ?? (pct >= 100 ? 'danger' : pct >= warnAt ? 'warning' : 'primary')
  const color = { primary: 'bg-primary', warning: 'bg-warning', danger: 'bg-destructive', muted: 'bg-muted-foreground/40' }[t]
  return (
    <div className={cn('h-1.5 overflow-hidden rounded-full bg-secondary', className)}>
      <div className={cn('h-full rounded-full transition-[width]', color)} style={{ width: `${Math.min(100, Math.max(pct > 0 ? 2 : 0, pct))}%` }} />
    </div>
  )
}
