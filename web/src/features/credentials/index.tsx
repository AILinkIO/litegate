import { useState } from 'react'
import { Pencil, Plus, RefreshCw, Trash2 } from 'lucide-react'
import { toast } from 'sonner'
import { api, BALANCE_KINDS, seg, type Credential } from '@/lib/api'
import { fmtTime, fmtUntil } from '@/lib/format'
import { useGet, useInvalidate } from '@/lib/query'
import { cn } from '@/lib/utils'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { Switch } from '@/components/ui/switch'
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip'
import { ConfirmDialog } from '@/components/confirm-dialog'
import { Meter } from '@/components/meter'
import { PageHeader } from '@/components/page'
import { Empty, ErrorAlert } from '@/components/query-state'
import { fmtMoney, PLAN_KINDS } from '@/lib/quota'
import { VendorLogo } from '@/components/vendor-logo'
import { CredentialDialog } from './credential-dialog'

export function Credentials() {
  const q = useGet<Credential[]>('/credentials')
  const invalidate = useInvalidate()
  const [editing, setEditing] = useState<Credential | 'new' | null>(null)
  const [deleting, setDeleting] = useState<Credential | null>(null)
  const [refreshing, setRefreshing] = useState(false)
  const data = q.data
  const hasPlans = (data ?? []).some((c) => c.plan_status)

  const refreshPlans = async () => {
    setRefreshing(true)
    try {
      await api.post('/plans/refresh', {})
      await invalidate('/credentials')
    } catch (e) {
      toast.error((e as Error).message)
    } finally {
      setRefreshing(false)
    }
  }

  const toggle = async (c: Credential) => {
    try {
      await api.put(`/credentials/${seg(c.id)}`, { enabled: !c.enabled })
      await invalidate('/credentials')
    } catch (e) {
      toast.error((e as Error).message)
    }
  }

  return (
    <>
      <PageHeader title='上游凭证' subtitle='上游服务的协议、地址与 API Key（加密存储）' actions={
        <>
          {hasPlans && (
            <Button variant='ghost' onClick={refreshPlans} disabled={refreshing} className='text-muted-foreground'>
              <RefreshCw className={cn(refreshing && 'animate-spin')} /> 刷新套餐额度
            </Button>
          )}
          <Button onClick={() => setEditing('new')}><Plus /> 添加凭证</Button>
        </>
      } />
      {q.error && <ErrorAlert message={q.error.message} />}
      {!data && !q.error && <Skeleton className='h-48 rounded-xl' />}
      {data && (
        <div className='overflow-hidden rounded-xl border bg-card'>
          {data.map((c, i) => (
            <div key={c.id} className={cn('flex flex-wrap items-center gap-x-6 gap-y-3 px-5 py-4', i > 0 && 'border-t', !c.enabled && 'opacity-60')}>
              <div className='flex min-w-0 flex-1 basis-72 items-start gap-3'>
                <div className='flex size-9 shrink-0 items-center justify-center rounded-lg border bg-background'>
                  <VendorLogo hints={[c.provider, c.base_url, c.name]} fallback={c.name} className='size-5' />
                </div>
                <div className='min-w-0'>
                  <div className='flex flex-wrap items-center gap-1.5'>
                    <span className='font-semibold'>{c.name}</span>
                    <Badge variant='muted'>{c.protocol === 'openai' ? 'OpenAI' : 'Anthropic'}</Badge>
                    {c.options.responses_api && <Badge variant='muted'>Responses</Badge>}
                    {c.options.plan && <Badge variant='info'>{PLAN_KINDS[c.options.plan.kind]}</Badge>}
                    {!!c.options.max_concurrency && <Badge variant='outline'>并发 {c.options.max_concurrency}</Badge>}
                  </div>
                  <div className='mt-0.5 truncate font-mono text-xs text-muted-foreground'>{c.base_url}</div>
                  <div className='text-xs text-muted-foreground'>
                    Key {c.api_key_hint ? <span className='font-mono'>…{c.api_key_hint.slice(-4)}</span> : '无'}
                    {c.provider && <> · 计费按 <span className='font-mono'>{c.provider}</span></>}
                  </div>
                </div>
              </div>
              <Quota c={c} />
              <div className='ms-auto flex items-center gap-1'>
                <Switch checked={c.enabled} onCheckedChange={() => toggle(c)} aria-label='启用' />
                <Button variant='ghost' size='icon' className='ms-2' aria-label='编辑' onClick={() => setEditing(c)}><Pencil /></Button>
                <Button variant='ghost' size='icon' aria-label='删除' onClick={() => setDeleting(c)}><Trash2 /></Button>
              </div>
            </div>
          ))}
          {data.length === 0 && <Empty>还没有凭证。添加一个上游服务的 API Key 后即可在路由表中使用。</Empty>}
        </div>
      )}
      {editing && (
        <CredentialDialog credential={editing === 'new' ? null : editing} onClose={() => setEditing(null)}
          onSaved={() => invalidate('/credentials')} />
      )}
      <ConfirmDialog open={deleting !== null} onOpenChange={(o) => !o && setDeleting(null)} title='删除凭证' destructive
        desc={`确定删除「${deleting?.name}」？被路由引用的凭证无法删除。`} confirmText='删除'
        handleConfirm={async () => {
          try {
            await api.del(`/credentials/${seg(deleting!.id)}`)
            toast.success('已删除')
            await invalidate('/credentials')
          } catch (e) {
            toast.error((e as Error).message)
          }
          setDeleting(null)
        }} />
    </>
  )
}

/** 行内的套餐额度或余额 */
function Quota({ c }: { c: Credential }) {
  const p = c.plan_status
  const b = c.balance_status
  if (p) {
    const windows = p.windows ?? []
    return (
      <div className='grid w-56 gap-1.5'>
        {p.error && <span className='text-xs text-destructive'>额度查询失败：{p.error}</span>}
        {windows.map((w) => (
          <Tooltip key={w.name}>
            <TooltipTrigger asChild>
              <div>
                <div className='mb-0.5 flex justify-between text-xs'>
                  <span className='text-muted-foreground'>{w.name} <span className='num text-foreground'>{Math.round(w.used_pct)}%</span></span>
                  <span className='text-muted-foreground'>{fmtUntil(w.resets_at)}后重置</span>
                </div>
                <Meter pct={w.used_pct} warnAt={100 - p.reserve_pct} />
              </div>
            </TooltipTrigger>
            <TooltipContent>重置于 {fmtTime(w.resets_at)}{p.fetched_at ? `，查询于 ${fmtTime(p.fetched_at)}` : ''}</TooltipContent>
          </Tooltip>
        ))}
        {!p.error && windows.length === 0 && <span className='text-xs text-muted-foreground'>额度尚未查询</span>}
      </div>
    )
  }
  if (b) {
    const low = b.amount !== null && b.alert_below !== null && b.amount < b.alert_below
    return (
      <div className='w-56 text-end'>
        <div className={cn('num text-lg font-semibold', low && 'text-destructive')}>{fmtMoney(b.amount, b.currency)}</div>
        <div className={cn('text-xs', b.error ? 'text-destructive' : 'text-muted-foreground')}>
          {b.error ? `查询失败：${b.error}` : `${BALANCE_KINDS[b.kind]}余额`}
        </div>
      </div>
    )
  }
  return null
}
