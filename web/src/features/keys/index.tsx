import { useState } from 'react'
import { Copy, KeyRound, Pencil, Plus, Trash2 } from 'lucide-react'
import { toast } from 'sonner'
import { api, seg, type ApiKey, type Route, type User } from '@/lib/api'
import { fmtInt, fmtTime } from '@/lib/format'
import { useGet, useInvalidate } from '@/lib/query'
import { cn } from '@/lib/utils'
import { useAuth } from '@/context/auth-context'
import { Alert, AlertDescription } from '@/components/ui/alert'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Skeleton } from '@/components/ui/skeleton'
import { Switch } from '@/components/ui/switch'
import { ConfirmDialog } from '@/components/confirm-dialog'
import { Field } from '@/components/form-field'
import { CheckRow, SimpleSelect, TagInput } from '@/components/form-controls'
import { BudgetBar, BudgetInputs, LimitInputs } from '@/components/limits'
import {
  budgetDraft, budgetValid, limitDraft, limitSummary, limitValid, saveBudget, saveLimit,
} from '@/lib/limits'
import { PageHeader } from '@/components/page'
import { Empty, ErrorAlert } from '@/components/query-state'
import { Segmented } from '@/components/segmented'

export function Keys() {
  const { user } = useAuth()
  const isAdmin = user?.role === 'admin'
  const authEnabled = user?.auth_enabled !== false
  const keys = useGet<ApiKey[]>('/keys')
  const users = useGet<User[]>(isAdmin && authEnabled ? '/users' : null)
  const routes = useGet<Route[]>(isAdmin ? '/routes' : null)
  const invalidate = useInvalidate()
  const [editing, setEditing] = useState<ApiKey | 'new' | null>(null)
  const [created, setCreated] = useState<string | null>(null)
  const [deleting, setDeleting] = useState<ApiKey | null>(null)
  const userName = new Map((users.data ?? []).map((u) => [u.id, u.username]))
  const [now] = useState(() => Date.now())

  const toggle = async (k: ApiKey) => {
    try {
      await api.put(`/keys/${seg(k.id)}`, { enabled: !k.enabled })
      await invalidate('/keys')
    } catch (e) {
      toast.error((e as Error).message)
    }
  }

  return (
    <>
      <PageHeader title='API Key' subtitle='客户端调用 /v1 接口时使用的网关 Key（Authorization: Bearer 或 x-api-key）'
        actions={<Button onClick={() => setEditing('new')}><Plus /> 创建 Key</Button>} />
      {keys.error && <ErrorAlert message={keys.error.message} />}
      {!keys.data && !keys.error && <Skeleton className='h-48 rounded-xl' />}
      {keys.data && (
        <div className='overflow-hidden rounded-xl border bg-card'>
          {keys.data.map((k, i) => {
            const expired = k.expires_at !== null && k.expires_at < now
            const quota = [limitSummary(k.limit), k.max_tokens && `单次 ≤ ${fmtInt(k.max_tokens)} token`].filter(Boolean).join(' · ')
            return (
              <div key={k.id} className={cn('flex flex-wrap items-center gap-x-6 gap-y-3 px-5 py-4', i > 0 && 'border-t', !k.enabled && 'opacity-60')}>
                <div className='flex min-w-0 flex-1 basis-72 items-start gap-3'>
                  <div className='flex size-9 shrink-0 items-center justify-center rounded-lg bg-secondary text-subtle-foreground'><KeyRound className='size-4' /></div>
                  <div className='min-w-0'>
                    <div className='flex flex-wrap items-center gap-1.5'>
                      <span className='font-semibold'>{k.name}</span>
                      <code className='text-xs text-muted-foreground'>{k.prefix}…</code>
                      {k.options?.redact && <Badge variant='muted'>脱敏</Badge>}
                      {expired && <Badge variant='danger'>已过期</Badge>}
                      {k.tags?.map((t) => <Badge key={t} variant='outline' className='font-mono'>{t}</Badge>)}
                    </div>
                    <div className='mt-0.5 text-xs text-muted-foreground'>
                      {k.allowed_routes === 'all' ? '可调用全部路由' : `可调用 ${k.allowed_routes.join(', ') || '无'}`}
                      {isAdmin && authEnabled && k.user_id && ` · 属于 ${userName.get(k.user_id) ?? k.user_id}`}
                      {` · ${k.expires_at ? `${expired ? '已于' : ''}${fmtTime(k.expires_at)}${expired ? '过期' : ' 过期'}` : '永不过期'}`}
                    </div>
                    <div className='text-xs text-muted-foreground'>创建于 {fmtTime(k.created_at)}{quota && ` · ${quota}`}</div>
                  </div>
                </div>
                {k.budget && <BudgetBar budget={k.budget} className='w-48' />}
                <div className='ms-auto flex items-center gap-1'>
                  <Switch checked={k.enabled} onCheckedChange={() => toggle(k)} aria-label='启用' />
                  <Button variant='ghost' size='icon' className='ms-2' aria-label='编辑' onClick={() => setEditing(k)}><Pencil /></Button>
                  <Button variant='ghost' size='icon' aria-label='删除' onClick={() => setDeleting(k)}><Trash2 /></Button>
                </div>
              </div>
            )
          })}
          {keys.data.length === 0 && <Empty>还没有 API Key</Empty>}
        </div>
      )}
      {editing && (
        <KeyDialog apiKey={editing === 'new' ? null : editing} isAdmin={isAdmin} authEnabled={authEnabled}
          users={users.data ?? []} routes={routes.data ?? []} onClose={() => setEditing(null)}
          onSaved={(plain) => { invalidate('/keys'); if (plain) setCreated(plain) }} />
      )}
      <CreatedDialog value={created} onClose={() => setCreated(null)} />
      <ConfirmDialog open={deleting !== null} onOpenChange={(o) => !o && setDeleting(null)} title='删除 API Key' destructive confirmText='删除'
        desc={`确定删除「${deleting?.name}」？使用它的客户端将立即无法访问。`}
        handleConfirm={async () => {
          try {
            await api.del(`/keys/${seg(deleting!.id)}`)
            toast.success('已删除')
            await invalidate('/keys')
          } catch (e) {
            toast.error((e as Error).message)
          }
          setDeleting(null)
        }} />
    </>
  )
}

function CreatedDialog({ value, onClose }: { value: string | null; onClose: () => void }) {
  const copy = async () => {
    await navigator.clipboard.writeText(value ?? '')
    toast.success('已复制')
  }
  return (
    <Dialog open={value !== null} onOpenChange={(o) => !o && onClose()}>
      <DialogContent className='sm:max-w-lg'>
        <DialogHeader><DialogTitle>API Key 已创建</DialogTitle></DialogHeader>
        <Alert className='border-warning/40 bg-warning-soft text-warning'><AlertDescription className='text-warning'>请立即复制保存，关闭后将无法再次查看完整 Key。</AlertDescription></Alert>
        <div className='flex gap-2'>
          <Input readOnly value={value ?? ''} className='font-mono' onFocus={(e) => e.target.select()} />
          <Button variant='outline' size='icon' onClick={copy} aria-label='复制'><Copy /></Button>
        </div>
        <DialogFooter><Button onClick={onClose}>我已保存</Button></DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

// datetime-local 输入值 ↔ 毫秒时间戳
const toLocalInput = (ms: number | null) => {
  if (!ms) return ''
  const d = new Date(ms - new Date().getTimezoneOffset() * 60000)
  return d.toISOString().slice(0, 16)
}

function KeyDialog({ apiKey, isAdmin, authEnabled, users, routes, onClose, onSaved }: {
  apiKey: ApiKey | null
  isAdmin: boolean
  authEnabled: boolean
  users: User[]
  routes: Route[]
  onClose: () => void
  onSaved: (plain?: string) => void
}) {
  const [name, setName] = useState(apiKey?.name ?? '')
  const [userId, setUserId] = useState(apiKey?.user_id ?? '')
  const [allowed, setAllowed] = useState<'all' | string[]>(apiKey?.allowed_routes ?? 'all')
  const [maxTokens, setMaxTokens] = useState(apiKey?.max_tokens ? String(apiKey.max_tokens) : '')
  const [tags, setTags] = useState<string[]>(apiKey?.tags ?? [])
  const [redact, setRedact] = useState(apiKey?.options?.redact === true)
  const [expires, setExpires] = useState(toLocalInput(apiKey?.expires_at ?? null))
  const [limit, setLimit] = useState(limitDraft(apiKey?.limit))
  const [budget, setBudget] = useState(budgetDraft(apiKey?.budget))
  const [busy, setBusy] = useState(false)

  const save = async () => {
    setBusy(true)
    const body: Record<string, unknown> = {
      name: name.trim(), allowed_routes: allowed, max_tokens: maxTokens ? Number(maxTokens) : null,
      expires_at: expires ? new Date(expires).getTime() : null, tags, options: { redact: redact || null },
    }
    if (isAdmin && authEnabled) body.user_id = userId || null
    try {
      let id = apiKey?.id
      let plain: string | undefined
      if (apiKey) {
        await api.put(`/keys/${seg(apiKey.id)}`, body)
      } else {
        const res = await api.post<ApiKey>('/keys', body)
        id = res.id
        plain = res.key
      }
      // 限额与预算只有管理员可设置
      if (isAdmin && id) {
        await saveLimit({ type: 'key', key_id: id }, limit)
        if (budget.max_usd.trim() !== '' || apiKey?.budget) await saveBudget({ type: 'key', key_id: id }, budget)
      }
      onSaved(plain)
      toast.success('已保存')
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
        <DialogHeader><DialogTitle>{apiKey ? `编辑 Key：${apiKey.name}` : '创建 API Key'}</DialogTitle></DialogHeader>
        <div className='grid gap-4'>
          <Field label='名称' required hint='用于区分用途，如 ci-bot、alice-laptop'>
            <Input autoFocus value={name} onChange={(e) => setName(e.target.value)} />
          </Field>
          {isAdmin && authEnabled && (
            <Field label='所属用户' hint='用户可在控制台看到自己 Key 的日志与用量'>
              <SimpleSelect value={userId} onChange={setUserId} options={[{ value: '', label: '无' }, ...users.map((u) => ({ value: u.id, label: u.username }))]} />
            </Field>
          )}
          {isAdmin && (
            <Field label='可调用路由' hint={allowed === 'all' ? '仍受路由自身的访问控制' : undefined}>
              <div className='grid gap-2'>
                <Segmented value={allowed === 'all' ? 'all' : 'some'} onChange={(v) => setAllowed(v === 'all' ? 'all' : [])}
                  options={[{ value: 'all', label: '全部' }, { value: 'some', label: '指定路由' }]} />
                {allowed !== 'all' && (
                  <TagInput freeSolo={false} mono value={allowed} onChange={setAllowed} placeholder='选择路由'
                    options={routes.map((r) => ({ value: r.name, label: r.name }))} />
                )}
              </div>
            </Field>
          )}
          <Field label='默认标签' hint='该 Key 的每个请求都带上这些标签（如 tool:claude-code）；只允许字母、数字与 _ . : / -'>
            <TagInput mono value={tags} onChange={setTags} />
          </Field>
          <div className='grid gap-4 sm:grid-cols-2'>
            <Field label='单次 max_tokens 上限' hint='留空不限；请求值超过上限时自动收紧'>
              <Input type='number' min={1} value={maxTokens} onChange={(e) => setMaxTokens(e.target.value)} />
            </Field>
            <Field label='过期时间' hint='留空永不过期'>
              <Input type='datetime-local' value={expires} onChange={(e) => setExpires(e.target.value)} />
            </Field>
          </div>
          <CheckRow checked={redact} onChange={setRedact} label='敏感信息脱敏' hint='该 Key 的请求中密钥类内容换成占位符再发往上游，回复中还原' />
          {isAdmin && (
            <>
              <div className='border-t pt-4'>
                <h3 className='mb-3 text-sm font-semibold'>限流（对该 Key 的全部请求）</h3>
                <LimitInputs value={limit} onChange={setLimit} />
              </div>
              <div className='border-t pt-4'>
                <h3 className='mb-3 text-sm font-semibold'>预算</h3>
                <BudgetInputs value={budget} onChange={setBudget} />
                {apiKey?.budget && <BudgetBar budget={apiKey.budget} className='mt-3' />}
              </div>
            </>
          )}
        </div>
        <DialogFooter>
          <Button variant='outline' onClick={onClose}>取消</Button>
          <Button onClick={save} disabled={busy || !name.trim() || !limitValid(limit) || !budgetValid(budget)}>{apiKey ? '保存' : '创建'}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
