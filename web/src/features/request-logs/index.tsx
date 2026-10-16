import { useEffect, useState } from 'react'
import { useInfiniteQuery } from '@tanstack/react-query'
import { getRouteApi } from '@tanstack/react-router'
import { RefreshCw, Search } from 'lucide-react'
import { api, CLIENT_LABEL, clientLabel, qs, type LogEntry } from '@/lib/api'
import { fmtCost, fmtMs, fmtTime, fmtTokens } from '@/lib/format'
import { useNames } from '@/lib/names'
import { cn } from '@/lib/utils'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Switch } from '@/components/ui/switch'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { PageHeader } from '@/components/page'
import { ErrorAlert } from '@/components/query-state'
import { Segmented } from '@/components/segmented'
import { VendorLogo } from '@/components/vendor-logo'
import { LogSheet } from './log-sheet'
import { StatusBadge } from './parts'

const route = getRouteApi('/_authenticated/logs')

const RANGES: Record<string, number | null> = { '1h': 3600e3, '24h': 86400e3, '7d': 7 * 86400e3, '30d': 30 * 86400e3, all: null }
const RANGE_OPTIONS = [
  { value: '1h', label: '1 小时' }, { value: '24h', label: '24 小时' }, { value: '7d', label: '7 天' },
  { value: '30d', label: '30 天' }, { value: 'all', label: '全部' },
]

/** 输入框防抖 */
function useDebounced<T>(v: T, ms = 300) {
  const [d, setD] = useState(v)
  useEffect(() => {
    const t = setTimeout(() => setD(v), ms)
    return () => clearTimeout(t)
  }, [v, ms])
  return d
}

export function Logs() {
  const search = route.useSearch()
  const navigate = route.useNavigate()
  const names = useNames()
  const [range, setRange] = useState('24h')
  const [q, setQ] = useState('')
  const [routeName, setRouteName] = useState('')
  const [tag, setTag] = useState('')
  const [client, setClient] = useState('all')
  const [keyId, setKeyId] = useState('all')
  const [errorsOnly, setErrorsOnly] = useState(false)
  const filters = useDebounced({ range, q: q.trim(), route: routeName.trim(), tag: tag.trim(), client, keyId, errorsOnly })
  const searching = filters.q !== ''

  // 游标分页：每页 50 条，「加载更多」取下一页；带 q 时为全文检索（按相关度，不分页）
  const logs = useInfiniteQuery({
    queryKey: ['logs', filters],
    initialPageParam: null as string | null,
    queryFn: ({ pageParam }) => {
      const span = RANGES[filters.range]
      return api.get<{ items: LogEntry[]; next_cursor: string | null }>(`/logs${qs({
        from: span ? Date.now() - span : undefined, route: filters.route, tag: filters.tag,
        client: filters.client === 'all' ? undefined : filters.client, key_id: filters.keyId === 'all' ? undefined : filters.keyId,
        errors_only: filters.errorsOnly || undefined, cursor: pageParam, limit: 50, q: filters.q,
      })}`)
    },
    getNextPageParam: (last) => last.next_cursor,
  })
  const items = logs.data?.pages.flatMap((p) => p.items) ?? []
  const open = (id: string | null) => navigate({ search: id ? { id } : {}, replace: true })

  return (
    <>
      <PageHeader title='请求日志' actions={
        <>
          <Segmented size='sm' value={range} onChange={setRange} options={RANGE_OPTIONS} />
          <Button variant='ghost' size='sm' onClick={() => logs.refetch()} className='text-muted-foreground'>
            <RefreshCw className={cn(logs.isFetching && 'animate-spin')} /> 刷新
          </Button>
        </>
      } />
      <div className='mb-3 flex flex-wrap items-center gap-2'>
        <div className='relative'>
          <Search className='absolute start-2.5 top-1/2 size-4 -translate-y-1/2 text-muted-foreground' />
          <Input className='w-60 bg-card ps-8' placeholder='搜索对话内容（中英文）' value={q} onChange={(e) => setQ(e.target.value)} />
        </div>
        <Input className='w-36 bg-card' placeholder='路由' value={routeName} onChange={(e) => setRouteName(e.target.value)} />
        <Input className='w-32 bg-card' placeholder='标签' value={tag} onChange={(e) => setTag(e.target.value)} />
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
            <SelectItem value='playground'>Playground（控制台）</SelectItem>
          </SelectContent>
        </Select>
        <div className='ms-1 flex items-center gap-2'>
          <Switch id='errors-only' checked={errorsOnly && !searching} disabled={searching} onCheckedChange={setErrorsOnly} />
          <Label htmlFor='errors-only' className='text-sm font-normal'>只看失败</Label>
        </div>
      </div>
      {logs.error && <ErrorAlert message={logs.error.message} />}
      <div className='overflow-hidden rounded-xl border bg-card'>
        <div className='overflow-x-auto'>
          <Table>
            <TableHeader>
              <TableRow className='[&>th]:h-10 [&>th]:text-xs [&>th]:text-muted-foreground'>
                <TableHead className='ps-5'>时间</TableHead>
                <TableHead>路由</TableHead>
                <TableHead>上游</TableHead>
                <TableHead>Key / 客户端</TableHead>
                <TableHead>状态</TableHead>
                <TableHead className='text-end'>输入 / 输出</TableHead>
                <TableHead className='text-end'>费用</TableHead>
                <TableHead className='pe-5 text-end'>耗时</TableHead>
                {searching && <TableHead className='pe-5 text-end'>相关度</TableHead>}
              </TableRow>
            </TableHeader>
            <TableBody>
              {items.map((l) => {
                const cred = names.cred(l.credential)
                return (
                  <TableRow key={l.id} className='cursor-pointer' onClick={() => open(l.id)} data-state={search.id === l.id ? 'selected' : undefined}>
                    <TableCell className='ps-5 whitespace-nowrap text-muted-foreground'>{fmtTime(l.ts)}</TableCell>
                    <TableCell className='max-w-60'>
                      <div className='flex items-center gap-1.5'>
                        <code className='truncate text-[13px]'>{l.route}</code>
                        {l.stream && <Badge variant='muted' className='px-1.5'>流</Badge>}
                      </div>
                      {(l.routed_to || l.affinity === 'hit') && (
                        <div className='text-xs text-muted-foreground'>
                          {l.routed_to && `规则 ${l.rule} → ${l.routed_to}`}{l.routed_to && l.affinity === 'hit' && ' · '}{l.affinity === 'hit' && '会话粘性'}
                        </div>
                      )}
                      {!!l.tags?.length && (
                        <div className='mt-1 flex flex-wrap gap-1'>{l.tags.map((t) => <Badge key={t} variant='outline' className='h-4 px-1 text-[10px]'>{t}</Badge>)}</div>
                      )}
                    </TableCell>
                    <TableCell className='max-w-56'>
                      {l.upstream_model ? (
                        <span className='flex items-center gap-1.5'>
                          <VendorLogo hints={[cred?.provider, cred?.base_url, l.upstream_model]} />
                          <code className='truncate text-[13px]'>{l.upstream_model}</code>
                        </span>
                      ) : '—'}
                    </TableCell>
                    <TableCell>
                      <div className='truncate'>{names.key(l.key_id)}</div>
                      {l.client && l.client !== 'other' && <div className='text-xs text-muted-foreground'>{clientLabel(l.client)}</div>}
                    </TableCell>
                    <TableCell><StatusBadge log={l} /></TableCell>
                    <TableCell className='num text-end whitespace-nowrap'>
                      {!l.usage ? '—' : l.format === 'images' ? `${l.usage.images ?? 0} 张`
                        : l.format === 'speech' ? `${fmtTokens(l.usage.chars ?? 0)} 字符`
                        : `${fmtTokens(l.usage.input + l.usage.cache_read + l.usage.cache_write)} / ${fmtTokens(l.usage.output)}`}
                    </TableCell>
                    <TableCell className='num text-end'>
                      {l.plan ? <Badge variant='info'>套餐</Badge> : l.cost !== undefined ? fmtCost(l.cost) : '—'}
                    </TableCell>
                    <TableCell className='num pe-5 text-end whitespace-nowrap'>{fmtMs(l.duration_ms)}</TableCell>
                    {searching && <TableCell className='num pe-5 text-end'>{l.score?.toFixed(2)}</TableCell>}
                  </TableRow>
                )
              })}
              {!logs.isPending && items.length === 0 && (
                <TableRow><TableCell colSpan={searching ? 9 : 8} className='py-10 text-center text-muted-foreground'>
                  {searching ? '没有匹配的对话（只检索最后一条用户消息与回复）' : '没有日志'}
                </TableCell></TableRow>
              )}
              {logs.isPending && (
                <TableRow><TableCell colSpan={8} className='py-10 text-center text-muted-foreground'>加载中…</TableCell></TableRow>
              )}
            </TableBody>
          </Table>
        </div>
        {logs.hasNextPage && (
          <div className='border-t p-2 text-center'>
            <Button variant='ghost' size='sm' onClick={() => logs.fetchNextPage()} disabled={logs.isFetchingNextPage}>加载更多</Button>
          </div>
        )}
      </div>
      <LogSheet id={search.id ?? null} onClose={() => open(null)} />
    </>
  )
}
