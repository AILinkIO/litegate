import { useState } from 'react'
import { Link } from '@tanstack/react-router'
import { Brain, Check, CircleAlert, CircleStop, Code, Copy, FileText, Plus, Terminal, Trash2 } from 'lucide-react'
import { toast } from 'sonner'
import type { CapLevel, RouteCaps } from '@/lib/api'
import { fmtCost, fmtMs, fmtTokens } from '@/lib/format'
import { cn } from '@/lib/utils'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Textarea } from '@/components/ui/textarea'
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip'
import { SimpleSelect } from '@/components/form-controls'
import { Narrative } from '@/components/narrative'
import { Collapsible, Markdown, ThinkingBlock, ToolCallCard } from './chat-parts'
import type { Answer, Question, QuestionType, Turn } from './playground-model'
import { DEFAULT_QUESTIONS, QUESTION_TYPES } from './playground-model'

export function AssistantTurn({ turn: t, showRaw, onRaw, onCurl }: { turn: Turn; showRaw: boolean; onRaw: () => void; onCurl: () => void }) {
  const [copied, setCopied] = useState(false)
  const log = t.meta?.log
  const hasBody = !!(t.thinking || t.text || t.images?.length || t.audio || t.tools?.length || t.error || t.decision)
  const copyText = async () => {
    try {
      await navigator.clipboard.writeText(t.text)
      setCopied(true)
      setTimeout(() => setCopied(false), 1500)
    } catch { toast.error('复制失败') }
  }
  return (
    <div className='flex max-w-[92%] flex-col items-start gap-1.5 self-start text-sm'>
      {/* 气泡：浅底细边框，左下角收成小圆角 */}
      <div className='flex max-w-full min-w-0 flex-col gap-2.5 rounded-[14px] rounded-bl-[4px] border bg-muted/60 px-3.5 py-2.5'>
        {t.thinking && <ThinkingBlock text={t.thinking} streaming={!!t.pending && !t.text} />}
        {t.text && <Markdown text={t.text} />}
        {t.pending && !t.text && !t.thinking && <span className='shimmer-text text-sm'>正在等待回答…</span>}
        {!!t.images?.length && (
          <div className='flex flex-wrap gap-2'>
            {t.images.map((u, i) => (
              <a key={i} href={u} target='_blank' rel='noopener noreferrer'>
                <img src={u} alt={`生成的图片 ${i + 1}`} className='max-h-80 w-60 max-w-full rounded-lg border object-cover' />
              </a>
            ))}
          </div>
        )}
        {t.audio && <audio controls src={t.audio} className='w-full max-w-md' />}
        {t.decision && <DecisionCard answers={t.decision} questions={(t.request as { questions?: Record<string, any> } | undefined)?.questions ?? {}} />}
        {(t.tools ?? []).map((c, i) => <ToolCallCard key={i} name={c.name} args={c.args} />)}
        {t.error && (
          <div className={cn('flex items-start gap-1.5', t.error === '已停止' ? 'text-muted-foreground' : 'text-destructive')}>
            {t.error === '已停止' ? <CircleStop className='mt-0.5 size-4 shrink-0' /> : <CircleAlert className='mt-0.5 size-4 shrink-0' />}
            <span className='break-words'>{t.error}</span>
          </div>
        )}
        {!hasBody && !t.pending && <span className='text-muted-foreground'>（空回答）</span>}
      </div>
      {/* 元信息：命中的上游、耗时与用量；右侧操作 */}
      {t.meta && (
        <div className='flex w-full flex-wrap items-center gap-x-2 gap-y-1 px-1 text-xs text-muted-foreground'>
          {t.meta.target && <span className='rounded-md bg-secondary px-1.5 py-0.5 font-mono text-[11px] text-foreground'>{t.meta.target}</span>}
          {t.meta.attempts && Number(t.meta.attempts) > 1 && <Badge variant='warning'>尝试 {t.meta.attempts} 次</Badge>}
          {t.meta.cacheHit && <Badge variant='info'>缓存命中</Badge>}
          {log?.plan && <Badge variant='info'>{log.plan_usd ? `套餐 · 等价 ${fmtCost(log.plan_usd)}` : '套餐'}</Badge>}
          {log && (
            <span className='num'>
              {log.ttft_ms != null && log.stream && `首 token ${fmtMs(log.ttft_ms)} · `}
              耗时 {fmtMs(log.duration_ms)}
              {log.usage && (log.format === 'images' ? ` · ${log.usage.images ?? 0} 张`
                : log.format === 'speech' ? ` · ${log.usage.chars ?? 0} 字符`
                : log.format === 'systemone' ? ` · 输入 ${fmtTokens(log.usage.input)}`
                : ` · 输入 ${fmtTokens(log.usage.input + log.usage.cache_read + log.usage.cache_write)} / 输出 ${fmtTokens(log.usage.output)}`)}
              {!log.plan && log.cost !== undefined && ` · ${fmtCost(log.cost)}`}
            </span>
          )}
          <span className='flex-1' />
          <span className='flex items-center'>
            {t.text && <MetaAction label={copied ? '已复制' : '复制回答'} onClick={copyText}>{copied ? <Check /> : <Copy />}</MetaAction>}
            {t.meta.id && (
              <Tooltip>
                <TooltipTrigger asChild>
                  <Link to='/logs' search={{ id: t.meta.id }} aria-label='请求日志'
                    className='flex size-6 items-center justify-center rounded-md hover:bg-muted hover:text-foreground [&_svg]:size-3.5'><FileText /></Link>
                </TooltipTrigger>
                <TooltipContent>请求日志</TooltipContent>
              </Tooltip>
            )}
            <MetaAction label={showRaw ? '隐藏原始数据' : '原始请求 / 响应'} onClick={onRaw}><Code /></MetaAction>
            <MetaAction label='复制为 curl（调用网关 /v1 接口）' onClick={onCurl}><Terminal /></MetaAction>
          </span>
        </div>
      )}
      {!!log?.narrative?.length && (
        <div className='w-full px-1'>
          <Collapsible title={`路由决策 · ${log.narrative.length} 条`}>
            <Narrative lines={log.narrative} dense />
          </Collapsible>
        </div>
      )}
      {showRaw && (
        <pre className={cn('max-h-80 w-full overflow-auto rounded-lg border bg-muted/40 p-2.5 font-mono text-xs whitespace-pre-wrap break-all')}>
          {'// 请求\n' + JSON.stringify(t.request, null, 2) + '\n\n// 响应\n' + (t.raw ?? '').slice(0, 50000)}
        </pre>
      )}
    </div>
  )
}

function MetaAction({ label, onClick, children }: { label: string; onClick: () => void; children: React.ReactNode }) {
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <button type='button' aria-label={label} onClick={onClick}
          className='flex size-6 items-center justify-center rounded-md hover:bg-muted hover:text-foreground [&_svg]:size-3.5'>{children}</button>
      </TooltipTrigger>
      <TooltipContent>{label}</TooltipContent>
    </Tooltip>
  )
}

/** 决策模型的问题表编辑（左侧设置） */
export function QuestionsEditor({ value, onChange, error }: { value: Question[]; onChange: (v: Question[]) => void; error?: string }) {
  const upd = (i: number, patch: Partial<Question>) => onChange(value.map((q, j) => (j === i ? { ...q, ...patch } : q)))
  const add = () => onChange([...value, { id: `q${value.length + 1}`, type: 'noul', instructions: '', criteria: '' }])
  return (
    <div className='grid gap-2'>
      <div className='flex items-center justify-between'>
        <span className='text-sm text-subtle-foreground'>问题表</span>
        <div className='flex items-center gap-1'>
          <Button variant='ghost' size='sm' onClick={() => onChange(DEFAULT_QUESTIONS)}>示例</Button>
          <Button variant='ghost' size='sm' onClick={add}><Plus /> 添加</Button>
        </div>
      </div>
      {value.map((q, i) => (
        <div key={i} className='grid gap-1.5 rounded-lg border bg-secondary/30 p-2'>
          <div className='grid grid-cols-[minmax(0,1fr)_84px_28px] items-center gap-1.5'>
            <Input value={q.id} placeholder='id' className='font-mono' onChange={(e) => upd(i, { id: e.target.value })} />
            <SimpleSelect value={q.type} onChange={(v) => upd(i, { type: v as QuestionType })}
              options={Object.entries(QUESTION_TYPES).map(([k, l]) => ({ value: k, label: l }))} />
            <button type='button' aria-label='删除问题' onClick={() => onChange(value.filter((_, j) => j !== i))}
              className='flex size-7 items-center justify-center rounded-md text-muted-foreground hover:bg-muted hover:text-destructive'>
              <Trash2 className='size-3.5' />
            </button>
          </div>
          <Input value={q.instructions} placeholder='问题（instructions）' onChange={(e) => upd(i, { instructions: e.target.value })} />
          {q.type !== 'noul' && (
            <Textarea rows={3} value={q.criteria} spellCheck={false} className='font-mono text-xs leading-relaxed'
              placeholder={q.type === 'choice' ? '每行一个选项：key: 说明' : '每行一个等级，从低到高'}
              onChange={(e) => upd(i, { criteria: e.target.value })} />
          )}
        </div>
      ))}
      {error ? <p className='text-xs text-destructive'>{error}</p>
        : <p className='text-xs text-muted-foreground'>输入框的内容作为 state 发送（JSON 对象按对象、否则按文本）；问题表与 TypeSafe 的 questions 一致</p>}
    </div>
  )
}

const pct = (v?: number) => `${Math.round((v ?? 0) * 100)}%`

/** 决策模型的回答：每道题的结果、置信度与概率分布 */
function DecisionCard({ answers, questions }: { answers: Record<string, Answer>; questions: Record<string, any> }) {
  const entries = Object.entries(answers)
  if (!entries.length) return <span className='text-muted-foreground'>（没有回答）</span>
  return (
    <div className='grid w-full gap-2.5'>
      {entries.map(([id, a]) => {
        const q = questions[id] ?? {}
        const labels: string[] | undefined = Array.isArray(q.criteria) ? q.criteria : undefined
        const label = (k: string) => a.legend?.[k] ?? labels?.[Number(k)] ?? k
        const probs = Object.entries(a.probabilities ?? {}).sort((x, y) => y[1] - x[1])
        return (
          <div key={id} className='grid gap-1.5 rounded-lg border bg-background/60 p-2.5'>
            <div className='flex flex-wrap items-baseline gap-x-2 gap-y-0.5'>
              <span className='font-mono text-xs'>{id}</span>
              <Badge variant='muted'>{QUESTION_TYPES[a.type as QuestionType] ?? a.type}</Badge>
              {q.instructions && <span className='text-xs text-muted-foreground'>{q.instructions}</span>}
            </div>
            <div className='flex flex-wrap items-baseline gap-x-2'>
              {a.type === 'noul' ? (
                <span className={cn('font-medium', (a.noul ?? 0) >= 0.5 ? 'text-success' : 'text-foreground')}>{(a.noul ?? 0) >= 0.5 ? '是' : '否'}</span>
              ) : a.type === 'score' ? (
                <span className='num font-medium'>{a.score?.toFixed(2)}</span>
              ) : (
                <span className='font-medium'>{a.choice ?? '—'}</span>
              )}
              <span className='num text-xs text-muted-foreground'>
                {a.type === 'noul' ? `是的概率 ${pct(a.noul)}` : a.confidence != null ? `置信 ${pct(a.confidence)}` : ''}
              </span>
            </div>
            {a.type === 'noul' ? <Bar value={a.noul ?? 0} /> : probs.map(([k, v]) => (
              <div key={k} className='grid grid-cols-[minmax(0,120px)_1fr_40px] items-center gap-2 text-xs'>
                <span className='truncate' title={label(k)}>{label(k)}</span>
                <Bar value={v} />
                <span className='num text-end text-muted-foreground'>{pct(v)}</span>
              </div>
            ))}
          </div>
        )
      })}
    </div>
  )
}

function Bar({ value }: { value: number }) {
  return (
    <div className='h-1.5 w-full overflow-hidden rounded-full bg-secondary'>
      <div className='h-full rounded-full bg-primary' style={{ width: `${Math.max(0, Math.min(1, value)) * 100}%` }} />
    </div>
  )
}

const LEVEL: Record<CapLevel, string> = { all: '支持', some: '部分支持', none: '不支持', unknown: '未知' }

/** 所选路由能到达的上游与能力（GET /api/routes/:name/capabilities） */
export function CapsCard({ caps, loading, error }: { caps?: RouteCaps; loading: boolean; error: boolean }) {
  if (loading) return <p className='-mt-2 text-xs text-muted-foreground'>读取模型能力…</p>
  if (error || !caps) return <p className='-mt-2 text-xs text-muted-foreground'>没有匹配的路由，无法读取模型能力</p>
  const { summary: sm, targets } = caps
  return (
    <div className='-mt-2 grid gap-1.5 rounded-lg border bg-secondary/30 p-2.5 text-xs'>
      <div className='flex flex-wrap gap-1'>
        <Badge variant={sm.reasoning === 'none' ? 'muted' : 'info'}><Brain className='size-3' /> 推理{LEVEL[sm.reasoning]}</Badge>
        <Badge variant={sm.images === 'none' ? 'muted' : 'info'}>图片{LEVEL[sm.images]}</Badge>
        {sm.context && <Badge variant='muted'>上下文 {fmtTokens(sm.context)}</Badge>}
        {sm.locked_sampling && <Badge variant='warning'>采样参数锁定</Badge>}
      </div>
      <ul className='grid gap-0.5'>
        {targets.slice(0, 8).map((t) => (
          <li key={`${t.credential}/${t.upstream_model}`} className='flex items-baseline gap-1.5' title={`经 ${t.via.join(' → ')}`}>
            <span className='truncate font-mono'>{t.upstream_model}</span>
            <span className='shrink-0 text-muted-foreground'>
              {t.known ? [t.reasoning && '推理', t.images && '图片', t.output && `出 ${fmtTokens(t.output)}`].filter(Boolean).join(' · ') : '目录中无此模型'}
            </span>
          </li>
        ))}
        {targets.length > 8 && <li className='text-muted-foreground'>另有 {targets.length - 8} 个上游</li>}
      </ul>
      {sm.unknown > 0 && <p className='text-muted-foreground'>{sm.unknown} 个上游在模型目录里查不到，未计入；给凭证关联目录供应商后可识别</p>}
    </div>
  )
}
