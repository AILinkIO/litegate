import { type ReactNode, useState } from 'react'
import type { ContextBreakdown, LogEntry, Usage } from '@/lib/api'
import { fmtMs, fmtTokens } from '@/lib/format'
import { cn } from '@/lib/utils'
import { Badge } from '@/components/ui/badge'

export function StatusBadge({ log }: { log: Pick<LogEntry, 'cache_hit' | 'client_aborted' | 'error' | 'status'> }) {
  if (log.cache_hit) return <Badge variant='info'>缓存命中</Badge>
  if (log.client_aborted) return <Badge variant='warning'>客户端断开</Badge>
  if (log.error) return <Badge variant='danger'>{log.status} {log.error.kind}</Badge>
  return <Badge variant='success'>{log.status}</Badge>
}

/** 详情里的「标签：值」行 */
export function Row({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className='grid grid-cols-[96px_minmax(0,1fr)] gap-3 py-1 text-sm'>
      <span className='text-muted-foreground'>{label}</span>
      <div className='min-w-0 break-words'>{children}</div>
    </div>
  )
}

export function Section({ title, children, className }: { title: string; children: ReactNode; className?: string }) {
  return (
    <section className={cn('border-t pt-4 pb-1', className)}>
      <h3 className='mb-2 text-sm font-semibold'>{title}</h3>
      {children}
    </section>
  )
}

const TIER: Record<string, string> = {
  hot: '正常', reserve: '套餐保留', cold: '冷却中', cold_reserve: '冷却且保留', exhausted: '额度用尽',
}

/** 路由决策的细节：规则 / 意图判断、候选顺序、每次尝试 */
export function DecisionDetail({ log, credName }: { log: LogEntry; credName: (id: string) => string }) {
  const attempts = log.attempt_list ?? []
  return (
    <>
      {log.rule !== undefined && (
        <Row label='规则'>{log.rule > 0 ? `命中规则 ${log.rule}` : '没有规则命中'}{log.routed_to && `，先发给 ${log.routed_to}`}</Row>
      )}
      {log.intent && (
        <Row label='意图判断'>
          {log.intent.error ? `失败（${log.intent.error}）` : `回答 ${log.intent.answer}${log.intent.reply ? `（“${log.intent.reply}”）` : ''}`}
          {log.intent.cached ? '，来自缓存' : `，${fmtMs(log.intent.ms)}`}
        </Row>
      )}
      {log.plan_trace && (
        <Row label='候选顺序'>
          <ol className='grid gap-1'>
            {log.plan_trace.map((c, i) => (
              <li key={i}>
                <span className='text-muted-foreground'>{i + 1}.</span> {credName(c.credential)} → <code className='text-[13px]'>{c.upstream_model}</code>
                {c.route !== log.route && <span className='text-xs text-muted-foreground'>（{c.route}）</span>}
                {c.tier !== 'hot' && <Badge variant='muted' className='ms-1.5'>{TIER[c.tier] ?? c.tier}</Badge>}
                {c.note && <div className='ps-4 text-xs text-muted-foreground'>{c.note}</div>}
              </li>
            ))}
          </ol>
        </Row>
      )}
      {attempts.length > 0 && (
        <Row label='尝试'>
          <ol className='grid gap-1'>
            {attempts.map((a, i) => (
              <li key={i} className={cn(!a.ok && 'text-destructive')}>
                <span className='text-muted-foreground'>{i + 1}.</span> {credName(a.credential)} → <code className='text-[13px]'>{a.upstream_model}</code>：
                {a.busy ? '并发已满，跳过' : a.ok ? `成功 ${fmtMs(a.duration_ms)}` : `${a.kind ?? '失败'} ${fmtMs(a.duration_ms)}`}
                {a.message && <div className='ps-4 text-xs'>{a.message}</div>}
              </li>
            ))}
          </ol>
        </Row>
      )}
    </>
  )
}

const CTX_PARTS: { key: 'system' | 'tools' | 'history' | 'input' | 'images'; label: string; color: string }[] = [
  { key: 'system', label: '系统提示', color: 'var(--chart-6)' },
  { key: 'tools', label: '工具定义', color: 'var(--chart-3)' },
  { key: 'history', label: '历史对话', color: 'var(--chart-2)' },
  { key: 'input', label: '本轮输入', color: 'var(--chart-4)' },
  { key: 'images', label: '图片 / 文件', color: 'var(--chart-5)' },
]

/** 上下文占用：各部分估算 token，按上游报告的输入 token 等比校准 */
export function ContextUsage({ ctx, usage }: { ctx: ContextBreakdown; usage?: Usage }) {
  const [showTools, setShowTools] = useState(false)
  const reported = usage ? usage.input + (usage.cache_read ?? 0) + (usage.cache_write ?? 0) : 0
  const scale = reported > 0 && ctx.total > 0 ? reported / ctx.total : 1
  const parts = CTX_PARTS.filter((p) => ctx[p.key] > 0)
  const est = (n: number) => fmtTokens(Math.round(n * scale))
  const share = (n: number) => `${Math.round((n / ctx.total) * 100)}%`
  return (
    <>
      <div className='mb-3 flex h-2.5 overflow-hidden rounded-full bg-secondary'>
        {parts.map((p) => (
          <div key={p.key} title={`${p.label} ${est(ctx[p.key])}`} style={{ width: share(ctx[p.key]), background: p.color }} />
        ))}
      </div>
      <div className='grid gap-1 text-sm'>
        {parts.map((p) => (
          <div key={p.key}>
            <div className='flex items-center gap-2'>
              <span className='size-2.5 rounded-[3px]' style={{ background: p.color }} />
              <span>{p.label}</span>
              {p.key === 'tools' && ctx.tool_list.length > 0 && (
                <button type='button' onClick={() => setShowTools(!showTools)} className='text-xs text-primary hover:underline'>
                  {ctx.tool_list.length} 个，{showTools ? '收起' : '展开'}
                </button>
              )}
              <span className='num ms-auto'>{est(ctx[p.key])}</span>
              <span className='num w-10 text-end text-muted-foreground'>{share(ctx[p.key])}</span>
            </div>
            {p.key === 'tools' && showTools && (
              <div className='my-1 grid gap-0.5 rounded-lg bg-secondary/60 px-3 py-2'>
                {ctx.tool_list.map((t) => (
                  <div key={t.name} className='flex text-xs'>
                    <span className='truncate font-mono text-subtle-foreground'>{t.name}</span>
                    <span className='num ms-auto ps-3 text-muted-foreground'>{est(t.tokens)}</span>
                  </div>
                ))}
              </div>
            )}
          </div>
        ))}
      </div>
      <p className='mt-2 text-xs text-muted-foreground'>
        本地估算共 {fmtTokens(ctx.total)} token（{ctx.messages} 条消息）
        {reported > 0 && `，上游报告输入 ${fmtTokens(reported)}，上表已按比例校准`}
        {usage && reported > 0 && (usage.cache_read ?? 0) > 0 && `；其中 ${Math.round(((usage.cache_read ?? 0) / reported) * 100)}% 读自缓存`}
      </p>
    </>
  )
}

const ROLE: Record<string, string> = { system: '系统', user: '用户', assistant: '助手', tool: '工具', developer: '开发者' }

export function Bubble({ role, text }: { role: string; text: string }) {
  return (
    <div className='mb-3'>
      <div className='mb-1 text-xs font-medium text-muted-foreground'>{ROLE[role] ?? role}</div>
      <div className={cn('max-h-80 overflow-auto rounded-lg border px-3 py-2 text-[13px] leading-relaxed whitespace-pre-wrap break-words',
        role === 'assistant' ? 'bg-primary-soft/50' : role === 'system' ? 'bg-secondary/60' : 'bg-card')}>
        {text || <span className='text-muted-foreground'>（空）</span>}
      </div>
    </div>
  )
}
