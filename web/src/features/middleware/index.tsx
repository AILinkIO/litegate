import { useState } from 'react'
import { FlaskConical, FolderSync, Pencil, Plus, Puzzle, Trash2 } from 'lucide-react'
import { toast } from 'sonner'
import { api, seg, type MiddlewareImpl, type MiddlewareItem, type MiddlewareTest, type PluginScan, type Route } from '@/lib/api'
import { fmtInt, fmtTime } from '@/lib/format'
import { useGet, useInvalidate } from '@/lib/query'
import { cn } from '@/lib/utils'
import { Alert, AlertDescription } from '@/components/ui/alert'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Skeleton } from '@/components/ui/skeleton'
import { Switch } from '@/components/ui/switch'
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip'
import { ConfirmDialog } from '@/components/confirm-dialog'
import { Field } from '@/components/form-field'
import { JsonTextarea, SimpleSelect, TagInput } from '@/components/form-controls'
import { parseJsonObject } from '@/lib/json'
import { PageHeader } from '@/components/page'
import { Empty, ErrorAlert } from '@/components/query-state'
import { Segmented } from '@/components/segmented'

const HOOK: Record<string, string> = { on_request: '请求', on_event: '流式事件', on_response: '响应' }

/** 网关中间件：在请求、流式事件、响应三个点位上改写或拒绝 */
export function Middleware() {
  const q = useGet<{ items: MiddlewareItem[]; impls: MiddlewareImpl[]; plugin_dir: string }>('/middleware')
  const routes = useGet<Route[]>('/routes')
  const invalidate = useInvalidate()
  const [editing, setEditing] = useState<MiddlewareItem | 'new' | null>(null)
  const [deleting, setDeleting] = useState<MiddlewareItem | null>(null)
  const [scan, setScan] = useState<PluginScan | null>(null)
  const [scanning, setScanning] = useState(false)
  const data = q.data

  const rescan = async () => {
    setScanning(true)
    try {
      setScan(await api.post<PluginScan>('/middleware/plugins/rescan'))
      await invalidate('/middleware')
    } catch (e) {
      toast.error((e as Error).message)
    } finally {
      setScanning(false)
    }
  }
  const implOf = (n: string) => data?.impls.find((i) => i.impl === n)

  const toggle = async (m: MiddlewareItem) => {
    try {
      await api.put(`/middleware/${seg(m.id)}`, { enabled: !m.enabled })
      await invalidate('/middleware')
    } catch (e) {
      toast.error((e as Error).message)
    }
  }

  return (
    <>
      <PageHeader title='中间件' subtitle='在请求、流式事件、响应三个点位上按顺序运行；出错或超时时原样放行'
        actions={<>
          <Button variant='outline' onClick={rescan} disabled={scanning}><FolderSync className={cn(scanning && 'animate-pulse')} /> 重新扫描插件</Button>
          <Button onClick={() => setEditing('new')} disabled={!data?.impls.length}><Plus /> 新建中间件</Button>
        </>} />
      <Alert className='mb-4 border-primary/20 bg-primary-soft/60'>
        <AlertDescription className='text-subtle-foreground'>
          中间件是 Erlang 模块：请求点位在路由之前运行（看到的是客户端格式的请求体），流式事件与响应点位在写给客户端之前运行。
          除内置模块外，可以把编译好的模块放进插件目录 <code className='text-foreground'>{data?.plugin_dir ?? '…'}</code> 后重新扫描，
          或用「远程节点」实现调用你自己 Erlang 节点上的模块（示例见 examples/middleware）。
        </AlertDescription>
      </Alert>
      {q.error && <ErrorAlert message={q.error.message} />}
      {!data && !q.error && <Skeleton className='h-40 rounded-xl' />}
      {data && (
        <div className='overflow-hidden rounded-xl border bg-card'>
          {data.items.map((m, i) => {
            const impl = implOf(m.impl)
            const st = m.stats
            return (
              <div key={m.id} className={cn('flex flex-wrap items-center gap-x-6 gap-y-3 px-5 py-4', i > 0 && 'border-t', !m.enabled && 'opacity-60')}>
                <div className='flex min-w-0 flex-1 basis-72 items-start gap-3'>
                  <div className='flex size-9 shrink-0 items-center justify-center rounded-lg bg-secondary text-subtle-foreground'><Puzzle className='size-4' /></div>
                  <div className='min-w-0'>
                    <div className='flex flex-wrap items-center gap-1.5'>
                      <span className='num text-xs text-muted-foreground'>#{m.position}</span>
                      <span className='font-semibold'>{m.name}</span>
                      <Badge variant='muted'>{impl?.title ?? m.impl}</Badge>
                      {impl?.source === 'plugin' && <Badge variant='info'>插件</Badge>}
                      {m.missing_impl && <Badge variant='danger'>实现不存在，未生效</Badge>}
                      {(m.hooks ?? impl?.hooks ?? []).map((h) => <Badge key={h} variant='outline'>{HOOK[h] ?? h}</Badge>)}
                    </div>
                    <div className='mt-0.5 text-xs text-muted-foreground'>
                      作用于 {m.routes === 'all' ? '全部路由' : <span className='font-mono'>{m.routes.join(', ')}</span>}
                    </div>
                  </div>
                </div>
                <div className='num grid grid-cols-3 gap-6 text-end text-sm'>
                  <div><div>{fmtInt(st?.calls ?? 0)}</div><div className='text-xs text-muted-foreground'>调用</div></div>
                  <div>
                    {st?.last_error ? (
                      <Tooltip>
                        <TooltipTrigger asChild><div className='text-destructive'>{fmtInt(st.failures)}</div></TooltipTrigger>
                        <TooltipContent>{fmtTime(st.last_error.at)} {HOOK[st.last_error.hook] ?? st.last_error.hook}：{st.last_error.message}</TooltipContent>
                      </Tooltip>
                    ) : <div>{fmtInt(st?.failures ?? 0)}</div>}
                    <div className='text-xs text-muted-foreground'>失败</div>
                  </div>
                  <div><div>{st?.calls ? `${fmtInt(st.avg_us)} µs` : '—'}</div><div className='text-xs text-muted-foreground'>平均耗时</div></div>
                </div>
                <div className='ms-auto flex items-center gap-1'>
                  <Switch checked={m.enabled} onCheckedChange={() => toggle(m)} aria-label='启用' />
                  <Button variant='ghost' size='icon' className='ms-2' aria-label='编辑' onClick={() => setEditing(m)}><Pencil /></Button>
                  <Button variant='ghost' size='icon' aria-label='删除' onClick={() => setDeleting(m)}><Trash2 /></Button>
                </div>
              </div>
            )
          })}
          {data.items.length === 0 && <Empty>还没有中间件</Empty>}
        </div>
      )}
      {editing && data && (
        <MiddlewareDialog item={editing === 'new' ? null : editing} impls={data.impls} routes={(routes.data ?? []).map((r) => r.name)}
          onClose={() => setEditing(null)} onSaved={() => invalidate('/middleware')} />
      )}
      {scan && <ScanResult scan={scan} onClose={() => setScan(null)} />}
      <ConfirmDialog open={deleting !== null} onOpenChange={(o) => !o && setDeleting(null)} title='删除中间件' destructive confirmText='删除'
        desc={`确定删除「${deleting?.name}」？`}
        handleConfirm={async () => {
          try {
            await api.del(`/middleware/${seg(deleting!.id)}`)
            toast.success('已删除')
            await invalidate('/middleware')
          } catch (e) {
            toast.error((e as Error).message)
          }
          setDeleting(null)
        }} />
    </>
  )
}

function MiddlewareDialog({ item, impls, routes, onClose, onSaved }: {
  item: MiddlewareItem | null
  impls: MiddlewareImpl[]
  routes: string[]
  onClose: () => void
  onSaved: () => void
}) {
  const [name, setName] = useState(item?.name ?? '')
  const [impl, setImpl] = useState(item?.impl ?? impls[0]?.impl ?? '')
  const example = (n: string) => JSON.stringify(impls.find((i) => i.impl === n)?.options_example ?? {}, null, 2)
  const [options, setOptions] = useState(item ? JSON.stringify(item.options, null, 2) : example(impl))
  const [allRoutes, setAllRoutes] = useState(!item || item.routes === 'all')
  const [selected, setSelected] = useState<string[]>(item && item.routes !== 'all' ? item.routes : [])
  const [position, setPosition] = useState(String(item?.position ?? 0))
  const [busy, setBusy] = useState(false)
  const parsed = parseJsonObject(options || '{}')
  const info = impls.find((i) => i.impl === impl)

  const save = async () => {
    setBusy(true)
    const body = { name: name.trim(), options: parsed.value ?? {}, routes: allRoutes ? 'all' : selected, position: Number(position) || 0 }
    try {
      if (item) await api.put(`/middleware/${seg(item.id)}`, body)
      else await api.post('/middleware', { ...body, impl })
      toast.success('已保存')
      onSaved()
      onClose()
    } catch (e) {
      toast.error((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className='max-h-[90svh] overflow-y-auto sm:max-w-xl'>
        <DialogHeader><DialogTitle>{item ? `编辑中间件：${item.name}` : '新建中间件'}</DialogTitle></DialogHeader>
        <div className='grid gap-4'>
          <div className='grid gap-4 sm:grid-cols-[1fr_120px]'>
            <Field label='名称'><Input value={name} onChange={(e) => setName(e.target.value)} /></Field>
            <Field label='顺序' hint='越小越先运行'><Input type='number' value={position} onChange={(e) => setPosition(e.target.value)} /></Field>
          </div>
          <Field label='实现' hint={info ? `${info.description}（点位：${info.hooks.map((h) => HOOK[h] ?? h).join('、')}）` : undefined}>
            <SimpleSelect value={impl} disabled={item !== null} onChange={(v) => { setImpl(v); setOptions(example(v)) }}
              options={impls.map((i) => ({ value: i.impl, label: `${i.title}（${i.impl}）${i.source === 'plugin' ? ' · 插件' : ''}` }))} />
          </Field>
          <Field label='配置（JSON）' error={parsed.ok ? undefined : '必须是 JSON 对象'} hint='由实现解释；保存时由实现校验'>
            <JsonTextarea rows={6} value={options} onChange={setOptions} invalid={!parsed.ok} />
          </Field>
          <Field label='作用路由' hint='按客户端请求解析出的路由名匹配'>
            <div className='grid gap-2'>
              <Segmented value={allRoutes ? 'all' : 'some'} onChange={(v) => setAllRoutes(v === 'all')}
                options={[{ value: 'all', label: '全部路由' }, { value: 'some', label: '指定路由' }]} />
              {!allRoutes && (
                <TagInput freeSolo={false} mono value={selected} onChange={setSelected} placeholder='选择路由'
                  options={routes.map((r) => ({ value: r, label: r }))} />
              )}
            </div>
          </Field>
          <TestPanel impl={impl} options={parsed.ok ? parsed.value ?? {} : null} />
        </div>
        <DialogFooter>
          <Button variant='outline' onClick={onClose}>取消</Button>
          <Button onClick={save} disabled={busy || !name.trim() || !impl || !parsed.ok || (!allRoutes && selected.length === 0)}>保存</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

/** 扫描插件目录的结果 */
function ScanResult({ scan, onClose }: { scan: PluginScan; onClose: () => void }) {
  const STATUS = { loaded: { label: '已加载', variant: 'success' }, library: { label: '辅助模块', variant: 'muted' }, error: { label: '失败', variant: 'danger' } } as const
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className='sm:max-w-xl'>
        <DialogHeader>
          <DialogTitle>插件扫描结果</DialogTitle>
          <DialogDescription className='font-mono text-xs break-all'>{scan.dir}</DialogDescription>
        </DialogHeader>
        {scan.files.length === 0 ? (
          <p className='text-sm text-muted-foreground'>目录里没有 .beam 文件。把编译好的中间件模块（或 &lt;应用&gt;/ebin）放进这个目录后再扫描。</p>
        ) : (
          <div className='grid max-h-80 gap-1.5 overflow-y-auto'>
            {scan.files.map((f) => (
              <div key={f.file} className='flex flex-wrap items-center gap-2 rounded-lg border px-3 py-2 text-sm'>
                <code className='font-medium'>{f.module}</code>
                <Badge variant={STATUS[f.result.status].variant}>{STATUS[f.result.status].label}</Badge>
                {f.result.impl && <span className='text-muted-foreground'>实现名 <code>{f.result.impl}</code></span>}
                {f.result.message && <span className='w-full text-xs text-destructive'>{f.result.message}</span>}
              </div>
            ))}
          </div>
        )}
        <DialogFooter><Button onClick={onClose}>好</Button></DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

const SAMPLES: Record<'openai' | 'anthropic' | 'responses', unknown> = {
  openai: { model: 'fast', messages: [{ role: 'system', content: '你是助手' }, { role: 'user', content: '你好' }] },
  anthropic: { model: 'fast', max_tokens: 1024, system: '你是助手', messages: [{ role: 'user', content: '你好' }] },
  responses: { model: 'fast', instructions: '你是助手', input: '你好' },
}

/** 试运行：对示例请求体调用一次 on_request，看返回值与耗时（不经过路由、不访问上游） */
function TestPanel({ impl, options }: { impl: string; options: Record<string, unknown> | null }) {
  const [open, setOpen] = useState(false)
  const [format, setFormat] = useState<'openai' | 'anthropic' | 'responses'>('openai')
  const [body, setBody] = useState(JSON.stringify(SAMPLES.openai, null, 2))
  const [busy, setBusy] = useState(false)
  const [res, setRes] = useState<MiddlewareTest | null>(null)
  const parsed = parseJsonObject(body)

  const run = async () => {
    setBusy(true)
    try {
      setRes(await api.post<MiddlewareTest>('/middleware/test', { impl, options, format, body: parsed.value }))
    } catch (e) {
      toast.error((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  if (!open) {
    return <div><Button variant='ghost' size='sm' onClick={() => setOpen(true)}><FlaskConical /> 试运行</Button></div>
  }
  const r = res?.result
  return (
    <div className='grid gap-3 rounded-lg border bg-secondary/30 p-3'>
      <div className='flex flex-wrap items-center gap-2'>
        <span className='text-sm font-semibold'>试运行</span>
        <Segmented size='sm' value={format} onChange={(v) => { setFormat(v); setBody(JSON.stringify(SAMPLES[v], null, 2)); setRes(null) }}
          options={[{ value: 'openai', label: 'OpenAI' }, { value: 'anthropic', label: 'Anthropic' }, { value: 'responses', label: 'Responses' }]} />
        <Button size='sm' className='ms-auto' onClick={run} disabled={busy || !parsed.ok || !options}>{busy ? '运行中…' : '调用 on_request'}</Button>
      </div>
      <JsonTextarea rows={5} value={body} onChange={(v) => { setBody(v); setRes(null) }} invalid={!parsed.ok} />
      {r && (
        <div className='grid gap-1.5 text-sm'>
          <div className='flex flex-wrap items-center gap-2'>
            <Badge variant={r.kind === 'reject' ? 'warning' : r.kind === 'error' || r.kind === 'bad_return' ? 'danger' : r.kind === 'ok' ? 'success' : 'muted'}>
              {{ continue: '不改动', ok: '改写', reject: `拒绝 ${r.status ?? ''}`, error: '出错（网关会放行）', no_hook: '没有请求点位', bad_return: '返回值无法识别（网关会放行）' }[r.kind]}
            </Badge>
            <span className='num text-xs text-muted-foreground'>{res.us} µs{res.timeout_ms ? ` · 超时 ${res.timeout_ms}ms` : ''}</span>
          </div>
          {r.message && <p className={cn('text-xs break-all', r.kind === 'reject' ? 'text-warning' : 'text-destructive')}>{r.message}</p>}
          {r.body && <pre className='max-h-56 overflow-auto rounded-md border bg-card p-2 font-mono text-xs'>{JSON.stringify(r.body, null, 2)}</pre>}
          {r.state && <p className='text-xs text-muted-foreground'>state：<code>{r.state}</code></p>}
        </div>
      )}
    </div>
  )
}
