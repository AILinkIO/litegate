import { cn } from '@/lib/utils'

/** 分段切换（如 今天 / 7 天 / 30 天）：灰色轨道 + 白色滑块 */
export function Segmented<T extends string>({ value, onChange, options, className, size = 'default' }: {
  value: T
  onChange: (v: T) => void
  options: { value: T; label: string }[]
  className?: string
  size?: 'default' | 'sm'
}) {
  return (
    <div role='tablist' className={cn('no-scrollbar inline-flex max-w-full overflow-x-auto rounded-lg bg-secondary p-0.5', className)}>
      {options.map((o) => (
        <button key={o.value} role='tab' type='button' aria-selected={o.value === value} onClick={() => onChange(o.value)}
          className={cn('rounded-md px-3 font-medium whitespace-nowrap text-muted-foreground transition-colors hover:text-foreground',
            size === 'sm' ? 'h-7 text-xs' : 'h-8 text-sm',
            o.value === value && 'bg-card text-foreground shadow-[0_1px_2px_rgba(0,0,0,.12),0_0_0_.5px_rgba(0,0,0,.06)]')}>
          {o.label}
        </button>
      ))}
    </div>
  )
}
