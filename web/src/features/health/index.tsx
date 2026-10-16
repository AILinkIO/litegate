import { useState } from 'react'
import { Radar, RotateCcw } from 'lucide-react'
import { toast } from 'sonner'
import { api, type Credential, type HealthStatus, type HealthTarget, type UnfitItem } from '@/lib/api'
import { fmtMs, fmtTime } from '@/lib/format'
import { useGet, useInvalidate } from '@/lib/query'
import { cn } from '@/lib/utils'
import { Alert, AlertDescription } from '@/components/ui/alert'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip'
import { Meter } from '@/components/meter'
import { PageHeader, SectionTitle } from '@/components/page'
import { Empty, ErrorAlert } from '@/components/query-state'
import { VendorLogo } from '@/components/vendor-logo'

const KIND: Record<string, string> = {
  rate_limit: '限流', credit: '余额不足', quota: '额度用尽', unserved: '无此模型', server: '服务端', network: '网络', timeout: '超时', auth: '鉴权', client: '请求错误', internal: '内部',
}

function status(t: HealthTarget): { label: string; variant: 'danger' | 'warning' | 'success' | 'muted' } {
  if (t.plan_state === 'exhausted') return { label: '额度用尽', variant: 'danger' }
  if (t.cooldown_ms > 0) return { label: '冷却中', variant: 'danger' }
  if (t.errors > 0) return { label: '有错误', variant: 'warning' }
  if (t.ok > 0) return { label: '正常', variant: 'success' }
  return { label: '无流量', variant: 'muted' }
}

export function Health() {
  const q = useGet<HealthStatus>('/health', { refetchInterval: 10_000 })
  const creds = useGet<Credential[]>('/credentials')
  const invalidate = useInvalidate()
  const [probing, setProbing] = useState<string | 'all' | null>(null)
  const data = q.data
  const credById = new Map((creds.data ?? []).map((c) => [c.id, c]))

  const reset = async (t?: HealthTarget) => {
    try {
      await api.post('/health/reset', t ? { credential: t.credential, upstream_model: t.upstream_model } : {})
      toast.success(t ? '已解除冷却' : '已解除全部冷却')
      await invalidate('/health')
    } catch (e) {
      toast.error((e as Error).message)
    }
  }

  const probe = async (credential?: string) => {
    setProbing(credential ?? 'all')
    try {
      await api.post('/health/probe', credential ? { credentials: [credential] } : {})
      await invalidate('/health')
    } catch (e) {
      toast.error((e as Error).message)
    } finally {
      setProbing(null)
    }
  }

  const probes = new Map((data?.probes ?? []).map((p) => [p.credential, p]))

  return (
    <>
      <PageHeader title='上游健康' subtitle='最近 5 分钟每个上游目标的调用情况（每 10 秒刷新）' actions={
        <>
          <Button variant='outline' onClick={() => probe()} disabled={probing !== null}><Radar /> {probing === 'all' ? '探活中…' : '立即探活全部'}</Button>
          <Button variant='outline' onClick={() => reset()}><RotateCcw /> 解除全部冷却</Button>
        </>
      } />
      {q.error && <ErrorAlert message={q.error.message} />}
      {!data && !q.error && <Skeleton className='h-48 rounded-xl' />}
      {data && (
        <>
          <div className='grid gap-3 md:grid-cols-2 xl:grid-cols-3'>
            {data.targets.map((t) => {
              const st = status(t)
              const c = credById.get(t.credential)
              const total = t.ok + t.errors
              return (
                <div key={`${t.credential}/${t.upstream_model}`} className={cn('rounded-xl border bg-card px-4 py-3.5', t.cooldown_ms > 0 && 'border-destructive/50')}>
                  <div className='flex items-center gap-2'>
                    <VendorLogo hints={[c?.provider, c?.base_url, t.upstream_model]} fallback={t.credential_name} className='size-[18px]' />
                    <span className='truncate font-semibold'>{t.credential_name}</span>
                    <Badge variant={st.variant} className='ms-auto'>{st.label}</Badge>
                  </div>
                  <code className='mt-0.5 block truncate text-xs text-muted-foreground'>{t.upstream_model}</code>
                  <div className='num mt-3 grid grid-cols-3 gap-2'>
                    <div><div className='text-lg font-semibold'>{total}</div><div className='text-xs text-muted-foreground'>请求</div></div>
                    <div><div className='text-lg font-semibold'>{t.success_rate === null ? '—' : `${(t.success_rate * 100).toFixed(1)}%`}</div><div className='text-xs text-muted-foreground'>成功率</div></div>
                    <div><div className='text-lg font-semibold'>{t.avg_ms === null ? '—' : fmtMs(t.avg_ms)}</div><div className='text-xs text-muted-foreground'>平均耗时</div></div>
                  </div>
                  {total > 0 && <Meter className='mt-2' tone={t.errors ? (t.success_rate! < 0.8 ? 'danger' : 'warning') : 'primary'} pct={(t.success_rate ?? 0) * 100} />}
                  <div className='mt-2 flex flex-wrap gap-1'>
                    {Object.entries(t.error_kinds).map(([k, n]) => <Badge key={k} variant='danger'>{KIND[k] ?? k} {n}</Badge>)}
                    {t.concurrency && (
                      <Badge variant={t.concurrency.inflight >= t.concurrency.max ? 'warning' : 'muted'}>
                        并发 {t.concurrency.inflight}/{t.concurrency.max}{t.concurrency.queued > 0 && ` · 排队 ${t.concurrency.queued}`}
                      </Badge>
                    )}
                    {t.plan_state === 'reserve' && <Badge variant='warning'>套餐额度进入保留</Badge>}
                  </div>
                  {t.cooldown_ms > 0 && (
                    <div className='mt-2 flex items-center gap-2 text-xs text-destructive'>
                      <span className='min-w-0 flex-1 truncate' title={t.cooldown?.reason ?? ''}>
                        {t.cooldown && `${KIND[t.cooldown.kind] ?? t.cooldown.kind}${t.cooldown.scope === 'credential' ? '（整个凭证）' : ''}${t.cooldown.streak > 1 ? ` ×${t.cooldown.streak}` : ''} · `}
                        剩余 {fmtMs(t.cooldown_ms)}
                      </span>
                      <Button variant='outline' size='sm' className='h-7' onClick={() => reset(t)}>解除冷却</Button>
                    </div>
                  )}
                  {t.last_error && (
                    <Tooltip>
                      <TooltipTrigger asChild>
                        <p className='mt-2 truncate text-xs text-muted-foreground'>
                          最近错误 {fmtTime(t.last_error.at)} · {KIND[t.last_error.kind] ?? t.last_error.kind}{t.last_error.message && ` · ${t.last_error.message}`}
                        </p>
                      </TooltipTrigger>
                      <TooltipContent className='max-w-md'>{t.last_error.message}</TooltipContent>
                    </Tooltip>
                  )}
                </div>
              )
            })}
          </div>
          {data.targets.length === 0 && <div className='rounded-xl border bg-card'><Empty>还没有配置上游目标</Empty></div>}

          <SectionTitle>凭证探活</SectionTitle>
          {data.probe_interval_ms === 0 && (
            <Alert className='mb-3'><AlertDescription>自动探活未开启，可在「运行参数」中设置 probe_interval_ms；探活请求上游的模型列表接口，只检查连通性与鉴权。</AlertDescription></Alert>
          )}
          <div className='overflow-hidden rounded-xl border bg-card'>
            <Table>
              <TableHeader>
                <TableRow className='[&>th]:h-10 [&>th]:text-xs [&>th]:text-muted-foreground'>
                  <TableHead className='ps-5'>凭证</TableHead><TableHead>结果</TableHead><TableHead className='text-end'>延迟</TableHead>
                  <TableHead>时间</TableHead><TableHead className='pe-5' />
                </TableRow>
              </TableHeader>
              <TableBody>
                {(creds.data ?? []).filter((c) => c.enabled).map((c) => {
                  const p = probes.get(c.id)
                  return (
                    <TableRow key={c.id}>
                      <TableCell className='ps-5'><span className='flex items-center gap-2'><VendorLogo hints={[c.provider, c.base_url, c.name]} />{c.name}</span></TableCell>
                      <TableCell>
                        {p ? (
                          <Tooltip>
                            <TooltipTrigger asChild><Badge variant={p.result === 'ok' ? 'success' : 'danger'}>{p.result === 'ok' ? '正常' : KIND[p.result] ?? p.result}</Badge></TooltipTrigger>
                            {p.message && <TooltipContent className='max-w-md'>{p.message}</TooltipContent>}
                          </Tooltip>
                        ) : <span className='text-muted-foreground'>未探活</span>}
                      </TableCell>
                      <TableCell className='num text-end'>{p ? fmtMs(p.latency_ms) : '—'}</TableCell>
                      <TableCell className='text-muted-foreground'>{p ? fmtTime(p.at) : '—'}</TableCell>
                      <TableCell className='pe-5 text-end'>
                        <Button variant='ghost' size='sm' onClick={() => probe(c.id)} disabled={probing !== null}>{probing === c.id ? '探活中…' : '探活'}</Button>
                      </TableCell>
                    </TableRow>
                  )
                })}
              </TableBody>
            </Table>
          </div>
        </>
      )}
      <UnfitCard />
    </>
  )
}

const FEATURE: Record<string, string> = {
  temperature: '不接受 temperature', top_p: '不接受 top_p', thinking_off: '不能关闭思考',
  bare_reasoning: '不接受 reasoning 项', retired: '模型已退役',
  enable_thinking_sync: '非流式请求必须关闭思考', prefill: '不接受以助手消息结尾',
  output_config: '不支持 output_config（结构化输出改用强制工具）', json_schema: '不支持 JSON Schema 格式（降为 json_object）',
  forced_tool: '思考模式下不能强制调用工具（改为 tool_choice auto）',
}

/** 网关从上游 400 错误中学到的参数限制：之后发往该目标的请求自动改写 */
function UnfitCard() {
  const q = useGet<UnfitItem[]>('/unfit')
  const invalidate = useInvalidate()
  const forget = async (u?: UnfitItem) => {
    try {
      await api.post('/unfit/forget', u ? { credential: u.credential, upstream_model: u.upstream_model, feature: u.feature } : {})
      toast.success(u ? '已清除' : '已全部清除')
      await invalidate('/unfit')
    } catch (e) {
      toast.error((e as Error).message)
    }
  }
  if (!q.data?.length) return null
  return (
    <>
      <SectionTitle actions={<Button variant='ghost' size='sm' onClick={() => forget()}>全部清除</Button>}>已学到的上游限制</SectionTitle>
      <p className='mb-2 text-sm text-muted-foreground'>上游以 400 拒绝某个参数时网关自动改写并重试，记下后之后的请求直接改写。清除后会在下次被拒时重新学到。</p>
      <div className='overflow-hidden rounded-xl border bg-card'>
        <Table>
          <TableHeader>
            <TableRow className='[&>th]:h-10 [&>th]:text-xs [&>th]:text-muted-foreground'>
              <TableHead className='ps-5'>凭证 / 上游模型</TableHead><TableHead>限制</TableHead><TableHead>上游原话</TableHead>
              <TableHead>学到时间</TableHead><TableHead className='pe-5' />
            </TableRow>
          </TableHeader>
          <TableBody>
            {q.data.map((u) => (
              <TableRow key={`${u.credential}/${u.upstream_model}/${u.feature}`}>
                <TableCell className='ps-5'><div className='font-medium'>{u.credential_name}</div><code className='text-xs text-muted-foreground'>{u.upstream_model}</code></TableCell>
                <TableCell>{FEATURE[u.feature] ?? u.feature}</TableCell>
                <TableCell className='max-w-80'>
                  <Tooltip>
                    <TooltipTrigger asChild><span className='block truncate text-xs'>{u.message}</span></TooltipTrigger>
                    <TooltipContent className='max-w-md'>{u.message}</TooltipContent>
                  </Tooltip>
                </TableCell>
                <TableCell className='text-muted-foreground'>{fmtTime(u.learned_at)}</TableCell>
                <TableCell className='pe-5 text-end'><Button variant='ghost' size='sm' onClick={() => forget(u)}>清除</Button></TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>
    </>
  )
}
