import { useState } from 'react'
import { Eraser, RotateCcw } from 'lucide-react'
import { toast } from 'sonner'
import { api, seg, type Setting, type StoreStatus } from '@/lib/api'
import { fmtBytes, fmtInt, fmtMs, fmtTime } from '@/lib/format'
import { useGet, useInvalidate } from '@/lib/query'
import { cn } from '@/lib/utils'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Skeleton } from '@/components/ui/skeleton'
import { Switch } from '@/components/ui/switch'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip'
import { PageHeader } from '@/components/page'
import { ErrorAlert } from '@/components/query-state'
import { AutoBackupCard, ConfigBackup } from './backup'
import { DESCRIPTIONS, GROUPS } from './descriptions'

const CASK: Record<string, string> = {
  logs: '请求日志', msgs: '对话内容', idx: '日志索引', usage: '用量汇总', search: '对话全文索引',
  cache: '响应缓存', responses: 'Responses 会话', alerts: '告警通知记录', sessions: '会话汇总',
}

const SOURCE: Record<Setting['source'], string> = { runtime: '控制台', env: '环境变量', app: 'sys.config', default: '默认值' }

export function Settings() {
  const q = useGet<Setting[]>('/settings')
  const invalidate = useInvalidate()

  const save = async (key: string, value: Setting['value'] | null) => {
    try {
      await api.put(`/settings/${seg(key)}`, { value })
      toast.success(value === null ? '已恢复' : '已保存')
    } catch (e) {
      toast.error((e as Error).message)
    } finally {
      await invalidate('/settings')
    }
  }

  const byKey = new Map((q.data ?? []).map((s) => [s.key, s]))
  const grouped = new Set(GROUPS.flatMap((g) => g.keys))
  const groups = [...GROUPS, { title: '其他', keys: (q.data ?? []).map((s) => s.key).filter((k) => !grouped.has(k)) }]

  return (
    <>
      <PageHeader title='运行参数' subtitle='在控制台修改的值立即生效，优先级高于环境变量与 sys.config；灰色项需修改配置后重启' />
      <Tabs defaultValue='params'>
        <TabsList className='mb-4'>
          <TabsTrigger value='params'>参数</TabsTrigger>
          <TabsTrigger value='store'>数据存储</TabsTrigger>
          <TabsTrigger value='otlp'>链路导出</TabsTrigger>
          <TabsTrigger value='backup'>备份与迁移</TabsTrigger>
        </TabsList>
        <TabsContent value='params' className='grid gap-6'>
          {q.error && <ErrorAlert message={q.error.message} />}
          {!q.data && !q.error && <Skeleton className='h-96 rounded-xl' />}
          {q.data && groups.map((g) => {
            const items = g.keys.map((k) => byKey.get(k)).filter((s): s is Setting => !!s)
            if (!items.length) return null
            return (
              <section key={g.title}>
                <h2 className='mb-2 text-sm font-semibold text-subtle-foreground'>{g.title}</h2>
                <div className='overflow-hidden rounded-xl border bg-card'>
                  {items.map((s, i) => (
                    <div key={s.key} className={cn('flex flex-wrap items-center gap-x-6 gap-y-2 px-5 py-3', i > 0 && 'border-t', !s.editable && 'opacity-60')}>
                      <div className='min-w-0 flex-1 basis-80'>
                        <div className='flex items-center gap-2'>
                          <code className='text-[13px] font-medium'>{s.key}</code>
                          <Badge variant={s.source === 'runtime' ? 'info' : 'muted'}>{SOURCE[s.source]}</Badge>
                        </div>
                        {DESCRIPTIONS[s.key] && <p className='mt-0.5 text-xs text-muted-foreground'>{DESCRIPTIONS[s.key]}</p>}
                        <p className='text-xs text-muted-foreground'>默认 <code>{String(s.default) || '（空）'}</code></p>
                      </div>
                      <div className='flex items-center gap-1'>
                        {/* key 含值：保存后重新挂载编辑器，丢弃未提交的输入 */}
                        <ValueEditor key={`${s.key}:${String(s.value)}`} s={s} onSave={(v) => save(s.key, v)} />
                        <span className='w-9'>
                          {s.editable && s.source === 'runtime' && (
                            <Tooltip>
                              <TooltipTrigger asChild>
                                <Button variant='ghost' size='icon' aria-label='撤销控制台设置' onClick={() => save(s.key, null)}><RotateCcw /></Button>
                              </TooltipTrigger>
                              <TooltipContent>撤销控制台设置</TooltipContent>
                            </Tooltip>
                          )}
                        </span>
                      </div>
                    </div>
                  ))}
                </div>
              </section>
            )
          })}
        </TabsContent>
        <TabsContent value='store'><StoreCard /></TabsContent>
        <TabsContent value='otlp'><OtlpCard settings={q.data ?? null} /></TabsContent>
        <TabsContent value='backup' className='grid gap-4'><AutoBackupCard /><ConfigBackup /></TabsContent>
      </Tabs>
    </>
  )
}

function ValueEditor({ s, onSave }: { s: Setting; onSave: (v: Setting['value']) => void }) {
  const [text, setText] = useState(String(s.value))
  if (!s.editable) return <code className='text-sm'>{String(s.value)}</code>
  if (typeof s.default === 'boolean') return <Switch checked={s.value === true} onCheckedChange={(v) => onSave(v)} />
  const commit = () => {
    if (text === String(s.value)) return
    onSave(typeof s.default === 'number' ? Number(text) : text)
  }
  return (
    <Input className='w-64 font-mono text-[13px]' value={text} type={typeof s.default === 'number' ? 'number' : 'text'}
      onChange={(e) => setText(e.target.value)} onBlur={commit} onKeyDown={(e) => e.key === 'Enter' && commit()} />
  )
}

function StoreCard() {
  const q = useGet<StoreStatus>('/store')
  const invalidate = useInvalidate()
  const [busy, setBusy] = useState(false)
  const c = q.data?.cleanup
  const run = async () => {
    setBusy(true)
    try {
      const r = await api.post<NonNullable<StoreStatus['cleanup']>>('/store/cleanup')
      toast.success(`清理完成：删除 ${fmtInt(r.logs)} 条日志、${fmtInt(r.usage)} 条用量汇总`)
      await invalidate('/store')
    } catch (e) {
      toast.error((e as Error).message)
    } finally {
      setBusy(false)
    }
  }
  return (
    <div className='rounded-xl border bg-card'>
      <div className='flex items-center justify-between px-5 py-4'>
        <div className='font-semibold'>数据存储</div>
        <Button variant='outline' onClick={run} disabled={busy}><Eraser /> {busy ? '清理中…' : '立即清理'}</Button>
      </div>
      <Table>
        <TableHeader>
          <TableRow className='[&>th]:h-9 [&>th]:text-xs [&>th]:text-muted-foreground'>
            <TableHead className='ps-5'>数据</TableHead><TableHead className='text-end'>条数</TableHead>
            <TableHead className='text-end'>磁盘占用</TableHead><TableHead className='pe-5'>空间回收</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {(q.data?.casks ?? []).map((k) => (
            <TableRow key={k.cask} className='num'>
              <TableCell className='ps-5'>{CASK[k.cask] ?? k.cask}</TableCell>
              <TableCell className='text-end'>{fmtInt(k.keys)}</TableCell>
              <TableCell className='text-end'>{fmtBytes(k.bytes)}</TableCell>
              <TableCell className='pe-5'>{k.needs_merge ? <Badge variant='warning'>待合并</Badge> : '—'}</TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
      <p className='border-t px-5 py-3 text-sm text-muted-foreground'>
        {c
          ? `最近清理：${fmtTime(c.at)}，删除日志 ${fmtInt(c.logs)} 条、索引 ${fmtInt(c.index)} 条、用量汇总 ${fmtInt(c.usage)} 条，耗时 ${fmtMs(c.duration_ms)}${c.merged.length ? `，已合并 ${c.merged.map((m) => CASK[m] ?? m).join('、')}` : ''}`
          : '尚未运行清理（每天自动运行一次，保留期在「参数」中设置）'}
      </p>
    </div>
  )
}

// 链路导出：配置在「参数」的 otlp_* 中修改，这里给出 Langfuse 配置说明与测试按钮
function OtlpCard({ settings }: { settings: Setting[] | null }) {
  const [busy, setBusy] = useState<'span' | 'metric' | null>(null)
  const get = (k: string) => settings?.find((s) => s.key === k)?.value
  const enabled = get('otlp_enabled') === true
  const metricsEnabled = get('otlp_metrics_enabled') === true
  const endpoint = String(get('otlp_endpoint') ?? '')
  const test = async (kind: 'span' | 'metric') => {
    setBusy(kind)
    try {
      await api.post(kind === 'span' ? '/otlp/test' : '/otlp/test-metric')
      toast.success(kind === 'span' ? '测试 span 已发送' : '测试 metric 已发送')
    } catch (e) {
      toast.error((e as Error).message)
    } finally {
      setBusy(null)
    }
  }
  return (
    <div className='rounded-xl border bg-card px-5 py-4'>
      <div className='mb-2 flex items-center gap-2'>
        <span className='font-semibold'>链路导出（OTLP）</span>
        <Badge variant={enabled ? 'success' : 'muted'}>{enabled ? '已开启' : '未开启'}</Badge>
        <Badge variant={metricsEnabled ? 'success' : 'muted'}>{metricsEnabled ? '指标已开启' : '指标未开启'}</Badge>
        <span className='ms-auto flex gap-2'>
          <Button variant='outline' onClick={() => test('span')} disabled={busy !== null || !endpoint}>
            {busy === 'span' ? '发送中…' : '发送测试 span'}
          </Button>
          <Button variant='outline' onClick={() => test('metric')} disabled={busy !== null || !endpoint}>
            {busy === 'metric' ? '发送中…' : '发送测试 metric'}
          </Button>
        </span>
      </div>
      <p className='text-sm text-muted-foreground'>
        每个请求导出一条 trace：父 span 为请求，每次上游尝试（含失败与回退）一个子 span，带 token 用量与费用。
        打开 otlp_metrics_enabled 后另按周期把 /metrics 同源的指标推到同端点的 /v1/metrics。
        在「参数」中设置 otlp_endpoint、otlp_headers 后打开 otlp_enabled。Langfuse：端点填
        <code className='mx-1 text-foreground'>https://&lt;host&gt;/api/public/otel</code>，请求头填
        <code className='mx-1 text-foreground'>Authorization=Basic%20&lt;base64(公钥:私钥)&gt;</code>。
      </p>
      {endpoint && <p className='mt-2 text-sm'>当前端点 <code>{endpoint}</code></p>}
    </div>
  )
}
