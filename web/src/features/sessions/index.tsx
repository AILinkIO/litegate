import { useCallback, useMemo, useState } from 'react'
import { useInfiniteQuery } from '@tanstack/react-query'
import { getRouteApi } from '@tanstack/react-router'
import { ArrowLeft, RefreshCw } from 'lucide-react'
import { api, CLIENT_LABEL, clientLabel, qs, seg, type LogEntry, type SessionSummary } from '@/lib/api'
import { fmtCost, fmtMs, fmtTime, fmtTokens } from '@/lib/format'
import { useNames } from '@/lib/names'
import { useGet } from '@/lib/query'
import { cn } from '@/lib/utils'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Skeleton } from '@/components/ui/skeleton'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { EChart } from '@/components/charts/echart'
import { axes, baseOption, type ChartTheme } from '@/lib/chart'
import { Narrative } from '@/components/narrative'
import { PageHeader } from '@/components/page'
import { ErrorAlert } from '@/components/query-state'
import { Segmented } from '@/components/segmented'
import { Stat, StatRow } from '@/components/stat-card'
import { VendorLogo } from '@/components/vendor-logo'
import { LogSheet } from '@/features/request-logs/log-sheet'

const route = getRouteApi('/_authenticated/sessions')

const RANGES: Record<string, number | null> = { '24h': 86400e3, '7d': 7 * 86400e3, '30d': 30 * 86400e3, all: null }
const RANGE_OPTIONS = [{ value: '24h', label: '24 小时' }, { value: '7d', label: '7 天' }, { value: '30d', label: '30 天' }, { value: 'all', label: '全部' }]

const inputOf = (s: { input: number; cache_read: number; cache_write: number }) => s.input + s.cache_read + s.cache_write
const cacheRate = (s: { input: number; cache_read: number; cache_write: number }) =>
  inputOf(s) > 0 ? `${Math.round((s.cache_read / inputOf(s)) * 100)}%` : '—'

function span(s: SessionSummary) {
  const ms = s.last_ts - s.first_ts
  return ms < 60e3 ? `${Math.max(1, Math.round(ms / 1000))} 秒` : ms < 3600e3 ? `${Math.round(ms / 60e3)} 分钟` : `${(ms / 3600e3).toFixed(1)} 小时`
}

/** 会话：按会话标识聚合的请求（编码工具的一次任务、多轮对话） */
export function Sessions() {
  const { id } = route.useSearch()
  const navigate = route.useNavigate()
  return id
    ? <SessionDetail id={id} onBack={() => navigate({ search: {} })} />
    : <SessionList onOpen={(sid) => navigate({ search: { id: sid } })} />
}

function SessionList({ onOpen }: { onOpen: (id: string) => void }) {
  const names = useNames()
  const [range, setRange] = useState('7d')
  const [keyId, setKeyId] = useState('all')
  const [client, setClient] = useState('all')
  const list = useInfiniteQuery({
    queryKey: ['sessions', range, keyId, client],
    initialPageParam: null as string | null,
    queryFn: ({ pageParam }) => {
      const sp = RANGES[range]
      return api.get<{ items: SessionSummary[]; next_cursor: string | null }>(`/sessions${qs({
        from: sp ? Date.now() - sp : undefined, key_id: keyId === 'all' ? undefined : keyId,
        client: client === 'all' ? undefined : client, cursor: pageParam, limit: 50,
      })}`)
    },
    getNextPageParam: (last) => last.next_cursor,
  })
  const items = list.data?.pages.flatMap((p) => p.items) ?? []

  return (
    <>
      <PageHeader title='会话' subtitle='同一会话标识的请求（编码工具的一次任务、多轮对话）汇总在一起，按最近活动排序' actions={
        <>
          <Segmented size='sm' value={range} onChange={setRange} options={RANGE_OPTIONS} />
          <Button variant='ghost' size='sm' onClick={() => list.refetch()} className='text-muted-foreground'>
            <RefreshCw className={cn(list.isFetching && 'animate-spin')} /> 刷新
          </Button>
        </>
      } />
      <div className='mb-3 flex flex-wrap gap-2'>
        <Select value={client} onValueChange={setClient}>
          <SelectTrigger className='w-36 bg-card'><SelectValue /></SelectTrigger>
          <SelectContent>
            <SelectItem value='all'>全部客户端</SelectItem>
            {Object.entries(CLIENT_LABEL).map(([k, v]) => <SelectItem key={k} value={k}>{v}</SelectItem>)}
          </SelectContent>
        </Select>
        <Select value={keyId} onValueChange={setKeyId}>
          <SelectTrigger className='w-40 bg-card'><SelectValue /></SelectTrigger>
          <SelectContent>
            <SelectItem value='all'>全部 API Key</SelectItem>
            {names.keys.map((k) => <SelectItem key={k.id} value={k.id}>{k.name}</SelectItem>)}
          </SelectContent>
        </Select>
      </div>
      {list.error && <ErrorAlert message={list.error.message} />}
      <div className='overflow-hidden rounded-xl border bg-card'>
        <div className='overflow-x-auto'>
          <Table>
            <TableHeader>
              <TableRow className='[&>th]:h-10 [&>th]:text-xs [&>th]:whitespace-nowrap [&>th]:text-muted-foreground'>
                <TableHead className='ps-5'>最近活动</TableHead>
                <TableHead>会话</TableHead>
                <TableHead>客户端 / Key</TableHead>
                <TableHead>路由</TableHead>
                <TableHead className='text-end'>轮数 / 请求</TableHead>
                <TableHead className='text-end'>输入 / 输出</TableHead>
                <TableHead className='text-end'>缓存命中</TableHead>
                <TableHead className='text-end'>费用</TableHead>
                <TableHead className='pe-5 text-end'>持续</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {items.map((s) => (
                <TableRow key={s.id} className='num cursor-pointer' onClick={() => onOpen(s.id)}>
                  <TableCell className='ps-5 whitespace-nowrap text-muted-foreground'>{fmtTime(s.last_ts)}</TableCell>
                  <TableCell className='max-w-56'>
                    <div className='truncate font-mono text-[13px]' title={s.id}>{s.id}</div>
                    {s.session_source === 'derived' && <div className='text-xs text-muted-foreground'>由对话内容推导</div>}
                  </TableCell>
                  <TableCell>
                    <div className='flex items-center gap-1.5'>
                      {s.client && <VendorLogo hints={[s.client]} fallback={s.client} />}
                      {s.client ? clientLabel(s.client) : '—'}
                    </div>
                    <div className='text-xs text-muted-foreground'>{s.key_id ? names.key(s.key_id) : ''}</div>
                  </TableCell>
                  <TableCell className='font-mono text-[13px]'>{s.routes.join(', ')}</TableCell>
                  <TableCell className='text-end whitespace-nowrap'>
                    {s.turns} / {s.requests}
                    {s.errors > 0 && <Badge variant='danger' className='ms-1.5'>{s.errors} 失败</Badge>}
                  </TableCell>
                  <TableCell className='text-end whitespace-nowrap'>{fmtTokens(inputOf(s))} / {fmtTokens(s.output)}</TableCell>
                  <TableCell className='text-end'>{cacheRate(s)}</TableCell>
                  <TableCell className='text-end'>{s.cost > 0 ? fmtCost(s.cost) : s.plan_usd > 0 ? <Badge variant='info'>套餐</Badge> : '—'}</TableCell>
                  <TableCell className='pe-5 text-end whitespace-nowrap'>{span(s)}</TableCell>
                </TableRow>
              ))}
              {!list.isPending && items.length === 0 && (
                <TableRow><TableCell colSpan={9} className='py-10 text-center text-muted-foreground'>
                  没有会话（请求带会话标识头，或对话内容足以推导会话时才会归入会话）
                </TableCell></TableRow>
              )}
            </TableBody>
          </Table>
        </div>
        {list.hasNextPage && (
          <div className='border-t p-2 text-center'>
            <Button variant='ghost' size='sm' onClick={() => list.fetchNextPage()} disabled={list.isFetchingNextPage}>加载更多</Button>
          </div>
        )}
      </div>
    </>
  )
}

type Detail = SessionSummary & { logs: LogEntry[]; truncated: boolean }

function SessionDetail({ id, onBack }: { id: string; onBack: () => void }) {
  const q = useGet<Detail>(`/sessions/${seg(id)}`)
  const names = useNames()
  const [log, setLog] = useState<string | null>(null)
  const s = q.data
  // 每轮的序号：本轮由用户输入开始的请求
  const turns = useMemo(() => {
    let n = 0
    return (s?.logs ?? []).map((l) => (l.new_turn ? ++n : 0))
  }, [s])

  return (
    <>
      <PageHeader title='会话详情' subtitle={<span className='font-mono'>{id}</span>} actions={
        <>
          <Button variant='ghost' size='sm' onClick={onBack}><ArrowLeft /> 返回列表</Button>
          <Button variant='ghost' size='sm' onClick={() => q.refetch()} className='text-muted-foreground'>
            <RefreshCw className={cn(q.isFetching && 'animate-spin')} /> 刷新
          </Button>
        </>
      } />
      {q.error && <ErrorAlert message={q.error.message} />}
      {!s && !q.error && <Skeleton className='h-64 rounded-xl' />}
      {s && (
        <>
          <StatRow>
            <Stat value={`${s.turns} / ${s.requests}`} label='轮数 / 请求' sub={s.errors > 0 ? <span className='text-destructive'>{s.errors} 次失败</span> : '没有失败'} />
            <Stat value={fmtTokens(inputOf(s))} label='输入 token' sub={`缓存命中 ${cacheRate(s)}`} />
            <Stat value={fmtTokens(s.output)} label='输出 token' />
            <Stat value={fmtCost(s.cost)} label='费用' sub={s.plan_usd > 0 ? `套餐内等价 ${fmtCost(s.plan_usd)}` : undefined} />
            <Stat value={span(s)} label='持续' sub={`${fmtTime(s.first_ts)} 起`} />
          </StatRow>
          <div className='mt-3 flex flex-wrap items-center gap-x-4 gap-y-1 text-sm text-muted-foreground'>
            {s.client && <span className='flex items-center gap-1.5'><VendorLogo hints={[s.client]} fallback={s.client} />{clientLabel(s.client)}</span>}
            {s.key_id && <span>Key {names.key(s.key_id)}</span>}
            <span>路由 <span className='font-mono text-foreground'>{s.routes.join(', ')}</span></span>
            <span>上游模型 <span className='font-mono text-foreground'>{s.models.join(', ')}</span></span>
          </div>
          {s.logs.length > 1 && (
            <Card className='mt-4 min-w-0 gap-2 pb-3'>
              <CardHeader><CardTitle className='text-sm'>每个请求的上下文与缓存</CardTitle></CardHeader>
              <CardContent className='px-3'><RequestTrend logs={s.logs} /></CardContent>
            </Card>
          )}
          {s.truncated && <p className='mt-4 text-sm text-muted-foreground'>请求较多，只列出最近 500 条</p>}
          <div className='mt-4 overflow-hidden rounded-xl border bg-card'>
            {s.logs.map((l, i) => {
              const cred = names.cred(l.credential)
              return (
                <button type='button' key={l.id} onClick={() => setLog(l.id)}
                  className={cn('block w-full px-5 py-3 text-start transition-colors hover:bg-accent/50',
                    i > 0 && (turns[i] ? 'border-t-4 border-t-background' : 'border-t'))}>
                  <div className='mb-1 flex flex-wrap items-baseline gap-x-3 gap-y-1'>
                    <span className={cn('min-w-14 text-sm font-semibold', !turns[i] && 'font-normal text-muted-foreground')}>
                      {turns[i] ? `第 ${turns[i]} 轮` : '工具'}
                    </span>
                    <span className='text-sm text-muted-foreground'>{fmtTime(l.ts)}</span>
                    <span className='flex items-center gap-1.5 font-mono text-[13px]'>
                      {l.route} → <VendorLogo hints={[cred?.provider, cred?.base_url, l.upstream_model]} />{l.upstream_model ?? '—'}
                    </span>
                    <span className='num ms-auto text-sm text-muted-foreground'>
                      {l.usage && `${fmtTokens(l.usage.input + l.usage.cache_read + l.usage.cache_write)} / ${fmtTokens(l.usage.output)} token · `}
                      {fmtMs(l.duration_ms)}{l.cost ? ` · ${fmtCost(l.cost)}` : ''}
                    </span>
                    {l.error && <Badge variant='danger'>{l.status}</Badge>}
                  </div>
                  {l.narrative && <Narrative lines={l.narrative} dense />}
                </button>
              )
            })}
          </div>
        </>
      )}
      <LogSheet id={log} onClose={() => setLog(null)} />
    </>
  )
}

/** 会话里每个请求的输入 token（未命中 / 缓存读）与输出，看上下文增长与缓存命中 */
function RequestTrend({ logs }: { logs: LogEntry[] }) {
  const option = useCallback((t: ChartTheme) => {
    const bar = { type: 'bar', stack: 't', barMaxWidth: 18 }
    return {
      ...baseOption(t),
      ...axes(t, logs.map((_, i) => `#${i + 1}`), (v) => fmtTokens(v)),
      tooltip: { ...(baseOption(t).tooltip as object), valueFormatter: (v: number) => fmtTokens(v) },
      series: [
        { ...bar, name: '缓存读', itemStyle: { color: t.palette[0], opacity: 0.35 }, data: logs.map((l) => l.usage?.cache_read ?? 0) },
        { ...bar, name: '未命中输入', itemStyle: { color: t.palette[0] }, data: logs.map((l) => (l.usage ? l.usage.input + l.usage.cache_write : 0)) },
        { ...bar, name: '输出', itemStyle: { color: t.palette[1], borderRadius: [3, 3, 0, 0] }, data: logs.map((l) => l.usage?.output ?? 0) },
      ],
    }
  }, [logs])
  return <EChart option={option} height={200} />
}

