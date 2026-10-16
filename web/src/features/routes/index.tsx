import { useEffect, useState } from 'react'
import { getRouteApi } from '@tanstack/react-router'
import { CornerDownRight, Pencil, Plus, Trash2 } from 'lucide-react'
import { toast } from 'sonner'
import { api, seg, type ApiKey, type Credential, type Route } from '@/lib/api'
import { useGet, useInvalidate } from '@/lib/query'
import { STRATEGY_LABEL } from '@/lib/routing'
import { cn } from '@/lib/utils'
import { Alert, AlertDescription } from '@/components/ui/alert'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { Switch } from '@/components/ui/switch'
import { ConfirmDialog } from '@/components/confirm-dialog'
import { limitSummary } from '@/lib/limits'
import { PageHeader } from '@/components/page'
import { Empty, ErrorAlert } from '@/components/query-state'
import { VendorLogo } from '@/components/vendor-logo'
import { RouteEditor } from './route-editor'
import { draftOf, emptyTarget, isWildcard, type Draft } from './route-editor-model'

const routeApi = getRouteApi('/_authenticated/routes')

export function Routes() {
  const search = routeApi.useSearch()
  const navigate = routeApi.useNavigate()
  const routes = useGet<Route[]>('/routes')
  const creds = useGet<Credential[]>('/credentials')
  const keys = useGet<ApiKey[]>('/keys')
  const invalidate = useInvalidate()
  const [editing, setEditing] = useState<{ route: Route | null; draft: Draft } | null>(null)
  const [deleting, setDeleting] = useState<Route | null>(null)
  const credById = new Map((creds.data ?? []).map((c) => [c.id, c]))

  // 从模型目录跳转过来（?provider=&model=）：渲染期调整状态预填路由名与目标（React「props 变化时调整 state」惯例）
  const [seenSearch, setSeenSearch] = useState(search)
  if (search.model && creds.data && seenSearch !== search) {
    setSeenSearch(search)
    const cred = creds.data.find((c) => c.provider === search.provider)
    setEditing({
      route: null,
      draft: { name: search.model, fallbacks: [], aliases: [], access: 'all', enabled: true,
        targets: [{ ...emptyTarget(cred?.id), upstream_model: search.model,
          model_ref: search.provider ? [search.provider, search.model] : null }] },
    })
  }
  // 预填完成后清掉 URL 参数，避免刷新页面再次触发
  useEffect(() => {
    if (search.model && creds.data) navigate({ search: {}, replace: true })
  }, [search, creds.data, navigate])

  const open = (r: Route | null) => setEditing({ route: r, draft: draftOf(r, creds.data?.[0]?.id) })

  const toggle = async (r: Route) => {
    try {
      await api.put(`/routes/${seg(r.name)}`, { enabled: !r.enabled })
      await invalidate('/routes')
    } catch (e) {
      toast.error((e as Error).message)
    }
  }

  return (
    <>
      <PageHeader title='路由表' subtitle='对外宣告的模型名：客户端请求中的 model 字段对应这里的路由名'
        actions={<Button onClick={() => open(null)} disabled={!creds.data?.length}><Plus /> 新建路由</Button>} />
      {creds.data?.length === 0 && (
        <Alert className='mb-4'><AlertDescription>先添加上游凭证，才能创建路由。</AlertDescription></Alert>
      )}
      {routes.error && <ErrorAlert message={routes.error.message} />}
      {!routes.data && !routes.error && <Skeleton className='h-48 rounded-xl' />}
      {routes.data && (
        <div className='overflow-hidden rounded-xl border bg-card'>
          {routes.data.map((r, i) => {
            const o = r.options ?? {}
            const sorted = [...r.targets].sort((a, b) => a.priority - b.priority)
            return (
              <div key={r.name} className={cn('flex flex-wrap items-start gap-x-6 gap-y-3 px-5 py-4', i > 0 && 'border-t', !r.enabled && 'opacity-60')}>
                <div className='min-w-0 flex-1 basis-80'>
                  <div className='flex flex-wrap items-center gap-1.5'>
                    <span className='font-mono font-semibold'>{r.name}</span>
                    {isWildcard(r.name) && <Badge variant='info'>通配</Badge>}
                    {o.strategy && o.strategy !== 'weighted' && <Badge variant='muted'>{STRATEGY_LABEL[o.strategy]}</Badge>}
                    {!!o.rules?.length && <Badge variant='muted'>规则 {o.rules.length}</Badge>}
                    {o.redact && <Badge variant='muted'>脱敏</Badge>}
                    {!!o.cache_ttl_s && <Badge variant='muted'>缓存 {o.cache_ttl_s}s</Badge>}
                    {o.affinity === 'off' && <Badge variant='outline'>无粘性</Badge>}
                  </div>
                  {!!r.aliases?.length && <div className='mt-0.5 text-xs text-muted-foreground'>别名 <span className='font-mono'>{r.aliases.join(', ')}</span></div>}
                  <div className='mt-2 grid gap-1'>
                    {sorted.map((t, j) => {
                      const c = credById.get(t.credential)
                      return (
                        <div key={j} className={cn('flex items-center gap-1.5 text-sm', !t.enabled && 'text-muted-foreground line-through')}>
                          {t.route ? (
                            <><CornerDownRight className='size-3.5 text-muted-foreground' />路由 <code className='text-[13px]'>{t.route}</code></>
                          ) : (
                            <>
                              <VendorLogo hints={[c?.provider, c?.base_url, t.upstream_model]} />
                              <span className='text-subtle-foreground'>{c?.name ?? t.credential}</span>
                              <span className='text-muted-foreground'>·</span>
                              <code className='text-[13px]'>{t.upstream_model}</code>
                            </>
                          )}
                          {r.targets.length > 1 && <span className='num text-xs text-muted-foreground'>P{t.priority} · W{t.weight}</span>}
                        </div>
                      )
                    })}
                    {r.fallbacks.length > 0 && <div className='text-xs text-muted-foreground'>失败后回退到 <span className='font-mono'>{r.fallbacks.join(' → ')}</span></div>}
                  </div>
                </div>
                <div className='w-44 text-sm'>
                  <div>{r.access === 'all' ? '所有 Key' : `${r.access.length} 个 Key`}</div>
                  {limitSummary(r.limit) && <div className='text-xs text-muted-foreground'>限额 {limitSummary(r.limit)}</div>}
                  {!!r.key_limits?.length && <div className='text-xs text-muted-foreground'>{r.key_limits.length} 个 Key 例外</div>}
                </div>
                <div className='ms-auto flex items-center gap-1'>
                  <Switch checked={r.enabled} onCheckedChange={() => toggle(r)} aria-label='启用' />
                  <Button variant='ghost' size='icon' className='ms-2' aria-label='编辑' onClick={() => open(r)}><Pencil /></Button>
                  <Button variant='ghost' size='icon' aria-label='删除' onClick={() => setDeleting(r)}><Trash2 /></Button>
                </div>
              </div>
            )
          })}
          {routes.data.length === 0 && <Empty>还没有路由。路由决定客户端能调用哪些模型、实际转发到哪个上游。</Empty>}
        </div>
      )}
      {editing && (
        <RouteEditor route={editing.route} initial={editing.draft} credentials={creds.data ?? []} routes={routes.data ?? []}
          keys={keys.data ?? []} onClose={() => setEditing(null)} onSaved={() => invalidate('/routes', '/live')} />
      )}
      <ConfirmDialog open={deleting !== null} onOpenChange={(v) => !v && setDeleting(null)} title='删除路由' destructive confirmText='删除'
        desc={`确定删除路由「${deleting?.name}」？使用这个模型名的客户端将收到 404。`}
        handleConfirm={async () => {
          try {
            await api.del(`/routes/${seg(deleting!.name)}`)
            toast.success('已删除')
            await invalidate('/routes')
          } catch (e) {
            toast.error((e as Error).message)
          }
          setDeleting(null)
        }} />
    </>
  )
}
