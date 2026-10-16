import { type ReactNode } from 'react'
import { cn } from '@/lib/utils'

/** 页面标题行：标题、说明、右侧操作 */
export function PageHeader({ title, subtitle, actions, className }: {
  title: ReactNode
  subtitle?: ReactNode
  actions?: ReactNode
  className?: string
}) {
  return (
    <div className={cn('mb-5 flex flex-wrap items-end justify-between gap-3', className)}>
      <div className='min-w-0'>
        <h1 className='text-xl font-semibold tracking-tight'>{title}</h1>
        {subtitle && <p className='mt-1 text-sm text-muted-foreground'>{subtitle}</p>}
      </div>
      {actions && <div className='flex flex-wrap items-center gap-2'>{actions}</div>}
    </div>
  )
}

/** 区块标题（卡片组之上的小标题） */
export function SectionTitle({ children, actions, className }: { children: ReactNode; actions?: ReactNode; className?: string }) {
  return (
    <div className={cn('mt-7 mb-2.5 flex flex-wrap items-center justify-between gap-2', className)}>
      <h2 className='text-sm font-semibold text-subtle-foreground'>{children}</h2>
      {actions}
    </div>
  )
}
