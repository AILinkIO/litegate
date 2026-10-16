import { type ReactNode } from 'react'
import { cn } from '@/lib/utils'

/** 统计数字：大数字 + 标签 + 说明（magpie 风格，可多个并排在一张卡片里） */
export function Stat({ value, label, sub, tone, className }: {
  value: ReactNode
  label: ReactNode
  sub?: ReactNode
  tone?: 'success' | 'warning' | 'danger'
  className?: string
}) {
  const color = tone === 'success' ? 'text-success' : tone === 'warning' ? 'text-warning' : tone === 'danger' ? 'text-destructive' : ''
  return (
    <div className={cn('min-w-0 px-5 py-4', className)}>
      <div className={cn('num truncate text-[26px] leading-tight font-semibold tracking-tight', color)}>{value}</div>
      <div className='mt-1 text-xs font-medium tracking-wide text-subtle-foreground'>{label}</div>
      {sub && <div className='mt-1 truncate text-xs text-muted-foreground md:whitespace-normal md:break-words'>{sub}</div>}
    </div>
  )
}

/** 一张卡片里横排的多个统计，窄屏时两列 */
export function StatRow({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <div className={cn('grid grid-cols-2 divide-border overflow-hidden rounded-xl border bg-card md:auto-cols-fr md:grid-flow-col md:grid-cols-none md:divide-x',
      '[&>*]:border-border max-md:[&>*:nth-child(n+3)]:border-t max-md:[&>*:nth-child(even)]:border-s max-md:[&>*:last-child:nth-child(odd)]:col-span-2', className)}>
      {children}
    </div>
  )
}
