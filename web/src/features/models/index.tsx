import { useEffect, useState } from 'react'
import { useNavigate } from '@tanstack/react-router'
import { Pencil, Plus, RefreshCw, Route as RouteIcon, Search, Upload } from 'lucide-react'
import { toast } from 'sonner'
import { api, qs, seg, type CatalogModel, type CatalogProvider, type SyncStatus } from '@/lib/api'
import { fmtInt, fmtPrice, fmtTime } from '@/lib/format'
import { useGet, useInvalidate } from '@/lib/query'
import { cn } from '@/lib/utils'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { ConfirmDialog } from '@/components/confirm-dialog'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip'
import { Field } from '@/components/form-field'
import { Combobox, SimpleSelect } from '@/components/form-controls'
import { PageHeader } from '@/components/page'
import { Pager } from '@/components/pager'
import { ErrorAlert } from '@/components/query-state'
import { VendorLogo } from '@/components/vendor-logo'

const SOURCE: Record<CatalogModel['source'], { label: string; variant: 'muted' | 'info' | 'warning' }> = {
  synced: { label: '同步', variant: 'muted' },
  overridden: { label: '已覆盖', variant: 'info' },
  custom: { label: '自定义', variant: 'warning' },
}

export function Models() {
  const navigate = useNavigate()
  const invalidate = useInvalidate()
  const [provider, setProvider] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [q, setQ] = useState('')
  const [source, setSource] = useState('')
  const [page, setPage] = useState(0)
  const [size, setSize] = useState(25)
  const [editing, setEditing] = useState<CatalogModel | null>(null)
  const [creating, setCreating] = useState(false)
  const [syncing, setSyncing] = useState(false)
  // 待导入的 models.dev api.json（选好文件后先确认：会整体替换同步数据）
  const [importing, setImporting] = useState<{ name: string; data: unknown; providers: number; models: number } | null>(null)
  const [importBusy, setImportBusy] = useState(false)

  // 输入停顿 300ms 后再搜索
  useEffect(() => {
    const t = setTimeout(() => { setQ(search); setPage(0) }, 300)
    return () => clearTimeout(t)
  }, [search])

  const providers = useGet<CatalogProvider[]>('/catalog/providers')
  const sync = useGet<SyncStatus>('/catalog/sync')
  const models = useGet<{ total: number; items: CatalogModel[] }>(
    `/catalog/models${qs({ provider, q, source, offset: page * size, limit: size })}`, { placeholderData: (p) => p })

  const runSync = async () => {
    setSyncing(true)
    try {
      const r = await api.post<{ providers: number; models: number; changed_models: number }>('/catalog/sync')
      toast.success(`同步完成：${r.providers} 个供应商，${r.models} 个模型（${r.changed_models} 个有变化）`)
    } catch (e) {
      toast.error((e as Error).message)
    } finally {
      setSyncing(false)
      await invalidate('/catalog')
    }
  }

  const pickImport = async (f: File | undefined) => {
    if (!f) return
    try {
      const data: unknown = JSON.parse(await f.text())
      const provs = data && typeof data === 'object' && !Array.isArray(data) ? Object.values(data as Record<string, unknown>) : []
      const counts = provs.map((p) => (p && typeof p === 'object' && 'models' in p && p.models && typeof p.models === 'object'
        ? Object.keys(p.models).length : -1))
      if (counts.length === 0 || counts.some((n) => n < 0)) {
        toast.error('不是 models.dev 的 api.json：每个顶层值都应是带 models 的供应商')
        return
      }
      setImporting({ name: f.name, data, providers: counts.length, models: counts.reduce((a, b) => a + b, 0) })
    } catch {
      toast.error('文件不是有效的 JSON')
    }
  }

  const runImport = async () => {
    if (!importing) return
    setImportBusy(true)
    try {
      const r = await api.post<{ providers: number; models: number; changed_models: number }>('/catalog/import', importing.data)
      toast.success(`导入完成：${r.providers} 个供应商，${r.models} 个模型（${r.changed_models} 个有变化）`)
      setImporting(null)
    } catch (e) {
      toast.error((e as Error).message)
    } finally {
      setImportBusy(false)
      await invalidate('/catalog')
    }
  }

  const s = sync.data
  return (
    <>
      <PageHeader title='模型目录'
        subtitle={s?.at ? `models.dev 同步于 ${fmtTime(s.at)}${s.status === 'error' ? `（最近一次失败：${s.error}）` : ''}` : '尚未同步 models.dev'}
        actions={<>
          <Button variant='outline' onClick={() => setCreating(true)}><Plus /> 自定义模型</Button>
          <Button variant='outline' asChild>
            <label className='cursor-pointer'>
              <Upload /> 导入 api.json
              {/* 清空 value：同一个文件可以再次选择 */}
              <input hidden type='file' accept='application/json,.json'
                onChange={(e) => { void pickImport(e.target.files?.[0]); e.target.value = '' }} />
            </label>
          </Button>
          <Button onClick={runSync} disabled={syncing}><RefreshCw className={cn(syncing && 'animate-spin')} /> {syncing ? '同步中…' : '同步 models.dev'}</Button>
        </>} />
      <ConfirmDialog open={importing !== null} onOpenChange={(o) => !o && setImporting(null)} title='导入 models.dev 目录'
        confirmText='导入' isLoading={importBusy} handleConfirm={runImport}
        desc={importing ? `${importing.name}：${importing.providers} 个供应商、${importing.models} 个模型。导入与「同步 models.dev」一样整体替换同步数据，文件中没有的供应商和模型会被移除；覆盖与自定义模型不受影响。` : ''} />
      <div className='mb-3 flex flex-wrap gap-2'>
        <div className='w-64'>
          <Combobox value={provider} onChange={(v) => { setProvider(v); setPage(0) }} clearable placeholder='全部供应商' className='bg-card'
            options={(providers.data ?? []).map((p) => ({ value: p.id, label: (
              <span className='flex items-center gap-1.5'><VendorLogo hints={[p.id, p.api, p.name]} fallback={p.name} />{p.name}</span>
            ), keywords: p.name, hint: p.id }))} />
        </div>
        <div className='relative min-w-60 flex-1'>
          <Search className='absolute start-2.5 top-1/2 size-4 -translate-y-1/2 text-muted-foreground' />
          <Input className='bg-card ps-8' placeholder='搜索 id / 名称 / 系列' value={search} onChange={(e) => setSearch(e.target.value)} />
        </div>
        <SimpleSelect className='w-32 bg-card' value={source} onChange={(v) => { setSource(v); setPage(0) }}
          options={[{ value: '', label: '全部来源' }, { value: 'synced', label: '同步' }, { value: 'overridden', label: '已覆盖' }, { value: 'custom', label: '自定义' }]} />
      </div>
      {models.error && <ErrorAlert message={models.error.message} />}
      <div className='overflow-hidden rounded-xl border bg-card'>
        <div className='overflow-x-auto'>
          <Table>
            <TableHeader>
              <TableRow className='[&>th]:h-10 [&>th]:text-xs [&>th]:text-muted-foreground'>
                <TableHead className='ps-5'>模型</TableHead>
                <TableHead>供应商</TableHead>
                <TableHead className='text-end'>上下文</TableHead>
                <TableHead className='text-end'>输入 / 输出（$/M）</TableHead>
                <TableHead>来源</TableHead>
                <TableHead className='pe-5' />
              </TableRow>
            </TableHeader>
            <TableBody>
              {(models.data?.items ?? []).map((m) => (
                <TableRow key={`${m.provider}/${m.id}`}>
                  <TableCell className='ps-5'>
                    <div className='font-medium'>{m.name ?? m.id}</div>
                    <div className='font-mono text-xs text-muted-foreground'>{m.id}</div>
                  </TableCell>
                  <TableCell>
                    <span className='flex items-center gap-1.5'><VendorLogo hints={[m.provider, m.id]} fallback={m.provider} />{m.provider}</span>
                  </TableCell>
                  <TableCell className='num text-end'>{m.limit?.context ? fmtInt(m.limit.context) : '—'}</TableCell>
                  <TableCell className='num text-end'>{fmtPrice(m.cost?.input)} / {fmtPrice(m.cost?.output)}</TableCell>
                  <TableCell><Badge variant={SOURCE[m.source].variant}>{SOURCE[m.source].label}</Badge></TableCell>
                  <TableCell className='pe-5 text-end whitespace-nowrap'>
                    <Tooltip>
                      <TooltipTrigger asChild>
                        <Button variant='ghost' size='icon' aria-label='用此模型创建路由'
                          onClick={() => navigate({ to: '/routes', search: { provider: m.provider, model: m.id } })}><RouteIcon /></Button>
                      </TooltipTrigger>
                      <TooltipContent>用此模型创建路由</TooltipContent>
                    </Tooltip>
                    <Button variant='ghost' size='icon' aria-label='编辑' onClick={() => setEditing(m)}><Pencil /></Button>
                  </TableCell>
                </TableRow>
              ))}
              {models.data?.items.length === 0 && (
                <TableRow><TableCell colSpan={6} className='py-10 text-center text-muted-foreground'>
                  没有模型{s?.status === 'never' ? '，先点击右上角同步 models.dev' : ''}
                </TableCell></TableRow>
              )}
            </TableBody>
          </Table>
        </div>
        {models.data && (
          <Pager total={models.data.total} page={page} size={size} onPage={setPage} onSize={(v) => { setSize(v); setPage(0) }} />
        )}
      </div>
      {editing && <ModelDialog model={editing} onClose={() => setEditing(null)} onSaved={() => invalidate('/catalog')} />}
      {creating && <ModelDialog providers={providers.data ?? []} onClose={() => setCreating(false)} onSaved={() => invalidate('/catalog')} />}
    </>
  )
}

// ---- 覆盖 / 自定义模型表单 ----

type Fields = { name: string; context: string; output: string; input: string; outputPrice: string; cacheRead: string; cacheWrite: string
  image: string; tts: string }

const numOrUndef = (s: string) => (s.trim() === '' ? undefined : Number(s))

function fieldsFromOverlay(o: Record<string, unknown> | null | undefined): Fields {
  const limit = (o?.limit ?? {}) as Record<string, unknown>
  const cost = (o?.cost ?? {}) as Record<string, unknown>
  const s = (v: unknown) => (v === undefined || v === null ? '' : String(v))
  return { name: s(o?.name), context: s(limit.context), output: s(limit.output), input: s(cost.input),
    outputPrice: s(cost.output), cacheRead: s(cost.cache_read), cacheWrite: s(cost.cache_write), image: s(cost.image), tts: s(cost.tts) }
}

// 只提交填了的字段；空字段继承 models.dev 的值
function overlayFromFields(f: Fields) {
  const limit = { context: numOrUndef(f.context), output: numOrUndef(f.output) }
  const cost = { input: numOrUndef(f.input), output: numOrUndef(f.outputPrice), cache_read: numOrUndef(f.cacheRead),
    cache_write: numOrUndef(f.cacheWrite), image: numOrUndef(f.image), tts: numOrUndef(f.tts) }
  const clean = (o: Record<string, number | undefined>) =>
    Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined && !Number.isNaN(v)))
  const out: Record<string, unknown> = {}
  if (f.name.trim()) out.name = f.name.trim()
  if (Object.keys(clean(limit)).length) out.limit = clean(limit)
  if (Object.keys(clean(cost)).length) out.cost = clean(cost)
  return out
}

function ModelDialog({ model, providers, onClose, onSaved }: {
  model?: CatalogModel
  providers?: CatalogProvider[]
  onClose: () => void
  onSaved: () => void
}) {
  const isNew = !model
  const detail = useGet<CatalogModel>(model ? `/catalog/models/${seg(model.provider)}/${seg(model.id)}` : null)
  const [provider, setProvider] = useState(model?.provider ?? '')
  const [id, setId] = useState(model?.id ?? '')
  const [f, setF] = useState<Fields>(fieldsFromOverlay(null))
  const [busy, setBusy] = useState(false)
  const [loaded, setLoaded] = useState(false)
  if (detail.data && !loaded) {
    setLoaded(true)
    setF(fieldsFromOverlay(detail.data.overlay))
  }
  const base = detail.data
  const ph = (v: unknown) => (v === undefined || v === null ? '' : String(v))
  const input = (k: keyof Fields, label: string, placeholder: unknown, hint?: string) => (
    <Field label={label} hint={hint}>
      <Input type={k === 'name' ? 'text' : 'number'} value={f[k]} placeholder={ph(placeholder)} onChange={(e) => setF({ ...f, [k]: e.target.value })} />
    </Field>
  )

  const run = async (fn: () => Promise<unknown>, msg: string) => {
    setBusy(true)
    try {
      await fn()
      toast.success(msg)
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
      <DialogContent className='sm:max-w-xl'>
        <DialogHeader>
          <DialogTitle>{isNew ? '新增自定义模型' : <span className='font-mono'>{model.provider} / {model.id}</span>}</DialogTitle>
          {!isNew && <DialogDescription>填写的字段会覆盖 models.dev 的值，留空则继承；同步不会改动这里的设置。价格单位：美元 / 百万 token。</DialogDescription>}
        </DialogHeader>
        <div className='grid gap-4 sm:grid-cols-2'>
          {isNew && (
            <>
              <Field label='供应商 id' required hint='可填目录外的自定义供应商'>
                <Combobox allowCustom value={provider || null} onChange={(v) => setProvider(v ?? '')}
                  options={(providers ?? []).map((p) => ({ value: p.id, label: p.id, keywords: p.name, hint: p.name }))} />
              </Field>
              <Field label='模型 id' required><Input className='font-mono' value={id} onChange={(e) => setId(e.target.value)} /></Field>
            </>
          )}
          <div className='sm:col-span-2'>{input('name', '显示名称', base?.name)}</div>
          {input('context', '上下文长度', base?.limit?.context)}
          {input('output', '最大输出', base?.limit?.output)}
          {input('input', '输入价格', base?.cost?.input)}
          {input('outputPrice', '输出价格', base?.cost?.output)}
          {input('cacheRead', '缓存读价格', base?.cost?.cache_read)}
          {input('cacheWrite', '缓存写价格', base?.cost?.cache_write)}
          {input('image', '图片价格（每张）', base?.cost?.image, '图片生成模型按张计费')}
          {input('tts', '语音价格（每百万字符）', base?.cost?.tts, '语音合成模型按输入字符计费')}
        </div>
        <DialogFooter>
          {!isNew && model.source !== 'synced' && (
            <Button variant='ghost' className='me-auto text-destructive' disabled={busy}
              onClick={() => run(() => api.del(`/catalog/models/${seg(model.provider)}/${seg(model.id)}`),
                model.source === 'custom' ? '已删除自定义模型' : '已恢复 models.dev 的值')}>
              {model.source === 'custom' ? '删除' : '恢复默认'}
            </Button>
          )}
          <Button variant='outline' onClick={onClose}>取消</Button>
          <Button disabled={busy || !provider.trim() || !id.trim()}
            onClick={() => run(() => api.put(`/catalog/models/${seg(provider.trim())}/${seg(id.trim())}`, overlayFromFields(f)), '已保存')}>保存</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
