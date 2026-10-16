import type { NarrativeLine } from '@/lib/api'
import { cn } from '@/lib/utils'

const DOT: Record<NarrativeLine['tone'], string> = {
  info: 'bg-foreground', muted: 'border border-muted-foreground bg-transparent', warn: 'bg-warning', ok: 'bg-success', error: 'bg-destructive',
}

/** 决策叙述：一次请求是怎么路由的（后端 lg_narrate 生成） */
export function Narrative({ lines, dense }: { lines: NarrativeLine[]; dense?: boolean }) {
  return (
    <ul className={cn('grid', dense ? 'gap-0.5' : 'gap-1.5')}>
      {lines.map((l, i) => (
        <li key={i} className='flex items-baseline gap-2.5'>
          <span className={cn('size-[7px] shrink-0 -translate-y-px rounded-full', DOT[l.tone])} />
          <span className={cn('text-sm break-words', l.tone === 'muted' && 'text-muted-foreground')}>{l.text}</span>
        </li>
      ))}
    </ul>
  )
}
