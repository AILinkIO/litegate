import { useState } from 'react'
import { Bell, Pencil, Plus, RefreshCw, Send, Trash2, Webhook } from 'lucide-react'
import { toast } from 'sonner'
import { api, seg, type AlertChannel, type AlertEvent, type AlertRecord, type AlertRule, type ChannelType } from '@/lib/api'
import { fmtTime } from '@/lib/format'
import { useGet, useInvalidate } from '@/lib/query'
import { cn } from '@/lib/utils'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Skeleton } from '@/components/ui/skeleton'
import { Switch } from '@/components/ui/switch'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip'
import { ConfirmDialog } from '@/components/confirm-dialog'
import { Field } from '@/components/form-field'
import { SimpleSelect, TagInput } from '@/components/form-controls'
import { PageHeader } from '@/components/page'
import { Empty, ErrorAlert } from '@/components/query-state'

const CHANNEL_TYPES: Record<ChannelType, { label: string; placeholder: string; secret: boolean }> = {
  feishu: { label: '飞书群机器人', placeholder: 'https://open.feishu.cn/open-apis/bot/v2/hook/…', secret: true },
  dingtalk: { label: '钉钉群机器人', placeholder: 'https://oapi.dingtalk.com/robot/send?access_token=…', secret: true },
  wecom: { label: '企业微信群机器人', placeholder: 'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=…', secret: false },
  webhook: { label: '通用 Webhook（JSON）', placeholder: 'https://example.com/hooks/litegate', secret: false },
}

const EVENTS: Record<AlertEvent, { label: string; threshold?: { label: string; unit: string; def: number } }> = {
  budget: { label: '预算用量', threshold: { label: '已用比例', unit: '%', def: 80 } },
  plan_quota: { label: '订阅套餐额度', threshold: { label: '窗口已用比例', unit: '%', def: 90 } },
  upstream_down: { label: '上游故障', threshold: { label: '连续失败次数', unit: '次', def: 3 } },
  catalog_sync_failed: { label: '模型目录同步失败' },
  balance_low: { label: '余额不足（告警线在凭证上设置）' },
}

const LEVEL = {
  info: { label: '恢复', variant: 'success' },
  warning: { label: '警告', variant: 'warning' },
  critical: { label: '严重', variant: 'danger' },
} as const

const errorToast = (e: unknown) => toast.error((e as Error).message)

export function Alerts() {
  const channels = useGet<AlertChannel[]>('/alerts/channels')
  return (
    <>
      <PageHeader title='告警' subtitle='预算、上游故障、套餐额度等事件通过飞书、钉钉、企业微信或 Webhook 通知' />
      <Tabs defaultValue='channels'>
        <TabsList className='mb-4'>
          <TabsTrigger value='channels'>通知渠道</TabsTrigger>
          <TabsTrigger value='rules'>告警规则</TabsTrigger>
          <TabsTrigger value='history'>通知记录</TabsTrigger>
        </TabsList>
        <TabsContent value='channels'><Channels data={channels.data} error={channels.error} /></TabsContent>
        <TabsContent value='rules'><Rules channels={channels.data ?? []} /></TabsContent>
        <TabsContent value='history'><History /></TabsContent>
      </Tabs>
    </>
  )
}

function Row({ children, first, disabled }: { children: React.ReactNode; first: boolean; disabled?: boolean }) {
  return <div className={cn('flex flex-wrap items-center gap-x-6 gap-y-3 px-5 py-3.5', !first && 'border-t', disabled && 'opacity-60')}>{children}</div>
}

function Channels({ data, error }: { data?: AlertChannel[]; error: Error | null }) {
  const invalidate = useInvalidate()
  const [editing, setEditing] = useState<AlertChannel | 'new' | null>(null)
  const [deleting, setDeleting] = useState<AlertChannel | null>(null)
  const [testing, setTesting] = useState<string | null>(null)

  const test = async (c: AlertChannel) => {
    setTesting(c.id)
    try {
      const r = await api.post<{ ok: boolean; error?: string }>(`/alerts/channels/${seg(c.id)}/test`)
      if (r.ok) toast.success('测试消息已发送')
      else toast.error(`发送失败：${r.error}`)
    } catch (e) {
      errorToast(e)
    } finally {
      setTesting(null)
    }
  }
  const toggle = async (c: AlertChannel) => {
    try {
      await api.put(`/alerts/channels/${seg(c.id)}`, { enabled: !c.enabled })
      await invalidate('/alerts/channels')
    } catch (e) {
      errorToast(e)
    }
  }

  return (
    <>
      <Button className='mb-3' onClick={() => setEditing('new')}><Plus /> 添加渠道</Button>
      {error && <ErrorAlert message={error.message} />}
      {!data && !error && <Skeleton className='h-32 rounded-xl' />}
      {data && (
        <div className='overflow-hidden rounded-xl border bg-card'>
          {data.map((c, i) => (
            <Row key={c.id} first={i === 0} disabled={!c.enabled}>
              <div className='flex min-w-0 flex-1 basis-72 items-center gap-3'>
                <div className='flex size-9 shrink-0 items-center justify-center rounded-lg bg-secondary text-subtle-foreground'><Webhook className='size-4' /></div>
                <div className='min-w-0'>
                  <div className='flex items-center gap-1.5'><span className='font-semibold'>{c.name}</span><Badge variant='muted'>{CHANNEL_TYPES[c.type].label}</Badge>
                    {c.has_secret && <Badge variant='outline'>加签</Badge>}</div>
                  <div className='truncate font-mono text-xs text-muted-foreground'>{c.url_hint}</div>
                </div>
              </div>
              <div className='ms-auto flex items-center gap-1'>
                <Switch checked={c.enabled} onCheckedChange={() => toggle(c)} aria-label='启用' />
                <Tooltip>
                  <TooltipTrigger asChild>
                    <Button variant='ghost' size='icon' className='ms-2' aria-label='发送测试消息' disabled={testing === c.id} onClick={() => test(c)}><Send /></Button>
                  </TooltipTrigger>
                  <TooltipContent>发送测试消息</TooltipContent>
                </Tooltip>
                <Button variant='ghost' size='icon' aria-label='编辑' onClick={() => setEditing(c)}><Pencil /></Button>
                <Button variant='ghost' size='icon' aria-label='删除' onClick={() => setDeleting(c)}><Trash2 /></Button>
              </div>
            </Row>
          ))}
          {data.length === 0 && <Empty>还没有通知渠道。添加一个群机器人或 Webhook 地址后即可在规则中使用。</Empty>}
        </div>
      )}
      {editing && <ChannelDialog channel={editing === 'new' ? null : editing} onClose={() => setEditing(null)} onSaved={() => invalidate('/alerts/channels')} />}
      <ConfirmDialog open={deleting !== null} onOpenChange={(o) => !o && setDeleting(null)} title='删除渠道' destructive confirmText='删除'
        desc={`确定删除「${deleting?.name}」？使用它的规则将不再通知到这里。`}
        handleConfirm={async () => {
          try {
            await api.del(`/alerts/channels/${seg(deleting!.id)}`)
            await invalidate('/alerts')
          } catch (e) {
            errorToast(e)
          }
          setDeleting(null)
        }} />
    </>
  )
}

function ChannelDialog({ channel, onClose, onSaved }: { channel: AlertChannel | null; onClose: () => void; onSaved: () => void }) {
  const isNew = channel === null
  const [name, setName] = useState(channel?.name ?? '')
  const [type, setType] = useState<ChannelType>(channel?.type ?? 'feishu')
  const [url, setUrl] = useState('')
  const [secret, setSecret] = useState('')
  const [clearSecret, setClearSecret] = useState(false)
  const [busy, setBusy] = useState(false)
  const meta = CHANNEL_TYPES[type]

  const save = async () => {
    setBusy(true)
    try {
      const body: Record<string, unknown> = { name, type }
      if (url) body.url = url.trim()
      if (secret) body.secret = secret.trim()
      else if (clearSecret || !meta.secret) body.secret = null
      if (isNew) await api.post('/alerts/channels', body)
      else await api.put(`/alerts/channels/${seg(channel.id)}`, body)
      toast.success('已保存')
      onSaved()
      onClose()
    } catch (e) {
      errorToast(e)
    } finally {
      setBusy(false)
    }
  }

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className='sm:max-w-lg'>
        <DialogHeader><DialogTitle>{isNew ? '添加通知渠道' : `编辑渠道：${channel.name}`}</DialogTitle></DialogHeader>
        <div className='grid gap-4'>
          <Field label='名称' required><Input value={name} onChange={(e) => setName(e.target.value)} /></Field>
          <Field label='类型'>
            <SimpleSelect value={type} onChange={(v) => setType(v as ChannelType)}
              options={Object.entries(CHANNEL_TYPES).map(([k, t]) => ({ value: k, label: t.label }))} />
          </Field>
          <Field label='地址' required={isNew} hint={isNew ? '含访问令牌，加密存储' : `当前：${channel.url_hint}；留空保持不变`}>
            <Input className='font-mono text-[13px]' value={url} placeholder={meta.placeholder} onChange={(e) => setUrl(e.target.value)} />
          </Field>
          {meta.secret && (
            <Field label='签名密钥（可选）' hint={channel?.has_secret && !clearSecret
              ? <>已设置；留空保持不变，或 <button type='button' className='text-primary hover:underline' onClick={() => setClearSecret(true)}>清除</button></>
              : '机器人开启「加签」安全设置时填写'}>
              <Input type='password' autoComplete='off' value={secret} onChange={(e) => { setSecret(e.target.value); setClearSecret(false) }} />
            </Field>
          )}
          {type === 'webhook' && (
            <p className='text-xs text-muted-foreground'>POST JSON：{'{ event, level, title, text, ts, data }'}，level 为 info / warning / critical</p>
          )}
        </div>
        <DialogFooter>
          <Button variant='outline' onClick={onClose}>取消</Button>
          <Button onClick={save} disabled={busy || !name.trim() || (isNew && !url.trim())}>保存</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function Rules({ channels }: { channels: AlertChannel[] }) {
  const q = useGet<AlertRule[]>('/alerts/rules')
  const invalidate = useInvalidate()
  const [editing, setEditing] = useState<AlertRule | 'new' | null>(null)
  const [deleting, setDeleting] = useState<AlertRule | null>(null)
  const chName = new Map(channels.map((c) => [c.id, c.name]))

  const toggle = async (r: AlertRule) => {
    try {
      await api.put(`/alerts/rules/${seg(r.id)}`, { enabled: !r.enabled })
      await invalidate('/alerts/rules')
    } catch (e) {
      errorToast(e)
    }
  }

  return (
    <>
      <div className='mb-3 flex items-center gap-3'>
        <Button onClick={() => setEditing('new')} disabled={channels.length === 0}><Plus /> 添加规则</Button>
        {channels.length === 0 && <span className='text-sm text-muted-foreground'>先在「通知渠道」中添加至少一个渠道。</span>}
      </div>
      {q.error && <ErrorAlert message={q.error.message} />}
      {q.data && (
        <div className='overflow-hidden rounded-xl border bg-card'>
          {q.data.map((r, i) => {
            const ev = EVENTS[r.event]
            return (
              <Row key={r.id} first={i === 0} disabled={!r.enabled}>
                <div className='flex min-w-0 flex-1 basis-72 items-center gap-3'>
                  <div className='flex size-9 shrink-0 items-center justify-center rounded-lg bg-secondary text-subtle-foreground'><Bell className='size-4' /></div>
                  <div>
                    <div className='font-semibold'>{ev.label}</div>
                    <div className='text-xs text-muted-foreground'>{ev.threshold ? `${ev.threshold.label} ≥ ${r.threshold}${ev.threshold.unit}` : '每次失败'}</div>
                  </div>
                </div>
                <div className='flex flex-wrap gap-1'>
                  {r.channels.length ? r.channels.map((c) => <Badge key={c} variant='muted'>{chName.get(c) ?? c}</Badge>)
                    : <span className='text-xs text-warning'>无渠道，不会通知</span>}
                </div>
                <div className='ms-auto flex items-center gap-1'>
                  <Switch checked={r.enabled} onCheckedChange={() => toggle(r)} aria-label='启用' />
                  <Button variant='ghost' size='icon' className='ms-2' aria-label='编辑' onClick={() => setEditing(r)}><Pencil /></Button>
                  <Button variant='ghost' size='icon' aria-label='删除' onClick={() => setDeleting(r)}><Trash2 /></Button>
                </div>
              </Row>
            )
          })}
          {q.data.length === 0 && <Empty>还没有告警规则。</Empty>}
        </div>
      )}
      <p className='mt-3 text-xs text-muted-foreground'>
        预算每个周期、套餐额度每个窗口周期只通知一次；上游故障在恢复时发送恢复通知；目录同步失败在静默期（运行参数 alert_silence_ms）内不重复。
      </p>
      {editing && <RuleDialog rule={editing === 'new' ? null : editing} channels={channels} onClose={() => setEditing(null)} onSaved={() => invalidate('/alerts/rules')} />}
      <ConfirmDialog open={deleting !== null} onOpenChange={(o) => !o && setDeleting(null)} title='删除规则' desc='确定删除这条告警规则？' destructive confirmText='删除'
        handleConfirm={async () => {
          try {
            await api.del(`/alerts/rules/${seg(deleting!.id)}`)
            await invalidate('/alerts/rules')
          } catch (e) {
            errorToast(e)
          }
          setDeleting(null)
        }} />
    </>
  )
}

function RuleDialog({ rule, channels, onClose, onSaved }: { rule: AlertRule | null; channels: AlertChannel[]; onClose: () => void; onSaved: () => void }) {
  const [event, setEvent] = useState<AlertEvent>(rule?.event ?? 'budget')
  const [threshold, setThreshold] = useState(String(rule?.threshold ?? EVENTS[rule?.event ?? 'budget'].threshold?.def ?? ''))
  const [selected, setSelected] = useState<string[]>(channels.filter((c) => rule?.channels.includes(c.id)).map((c) => c.id))
  const [busy, setBusy] = useState(false)
  const t = EVENTS[event].threshold

  const save = async () => {
    setBusy(true)
    try {
      const body = { event, threshold: t ? Number(threshold) : null, channels: selected }
      if (rule) await api.put(`/alerts/rules/${seg(rule.id)}`, body)
      else await api.post('/alerts/rules', body)
      toast.success('已保存')
      onSaved()
      onClose()
    } catch (e) {
      errorToast(e)
    } finally {
      setBusy(false)
    }
  }

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className='sm:max-w-lg'>
        <DialogHeader><DialogTitle>{rule ? '编辑告警规则' : '添加告警规则'}</DialogTitle></DialogHeader>
        <div className='grid gap-4'>
          <Field label='事件'>
            <SimpleSelect value={event} onChange={(v) => { setEvent(v as AlertEvent); setThreshold(String(EVENTS[v as AlertEvent].threshold?.def ?? '')) }}
              options={Object.entries(EVENTS).map(([k, v]) => ({ value: k, label: v.label }))} />
          </Field>
          {t && <Field label={`${t.label}（${t.unit}）`}><Input type='number' value={threshold} onChange={(e) => setThreshold(e.target.value)} /></Field>}
          <Field label='通知渠道'>
            <TagInput freeSolo={false} value={selected} onChange={setSelected} placeholder='选择渠道'
              options={channels.map((c) => ({ value: c.id, label: c.name }))} />
          </Field>
        </div>
        <DialogFooter>
          <Button variant='outline' onClick={onClose}>取消</Button>
          <Button onClick={save} disabled={busy || selected.length === 0 || (!!t && !(Number(threshold) > 0))}>保存</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function History() {
  const q = useGet<AlertRecord[]>('/alerts/history?limit=200')
  return (
    <>
      <Button variant='ghost' size='sm' className='mb-3 text-muted-foreground' onClick={() => q.refetch()}>
        <RefreshCw className={cn(q.isFetching && 'animate-spin')} /> 刷新
      </Button>
      {q.error && <ErrorAlert message={q.error.message} />}
      {q.data && (
        <div className='overflow-hidden rounded-xl border bg-card'>
          {q.data.map((a, i) => (
            <Row key={a.id} first={i === 0}>
              <span className='w-40 shrink-0 text-sm text-muted-foreground'>{fmtTime(a.ts)}</span>
              <Badge variant={LEVEL[a.level].variant}>{LEVEL[a.level].label}</Badge>
              <div className='min-w-0 flex-1 basis-60'>
                <div className='font-medium'>{a.title}</div>
                <div className='text-xs text-muted-foreground'>{a.text}</div>
              </div>
              <div className='flex flex-wrap gap-1'>
                {a.deliveries.map((d) => (
                  <Tooltip key={d.channel}>
                    <TooltipTrigger asChild>
                      <Badge variant={d.status === 'ok' ? 'success' : d.status === 'error' ? 'danger' : 'muted'}>{d.channel_name}</Badge>
                    </TooltipTrigger>
                    {d.error && <TooltipContent>{d.error}</TooltipContent>}
                  </Tooltip>
                ))}
              </div>
            </Row>
          ))}
          {q.data.length === 0 && <Empty>暂无通知</Empty>}
        </div>
      )}
    </>
  )
}
