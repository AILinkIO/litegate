import { useCallback, useMemo, useState } from 'react'
import { RefreshCw } from 'lucide-react'
import { toast } from 'sonner'
import { api, byLocalDay, clientLabel, qs, type UsageRow } from '@/lib/api'
import { fmtCost, fmtInt, fmtMs, fmtTokens } from '@/lib/format'
import { useNames } from '@/lib/names'
import { useGet, useInvalidate } from '@/lib/query'
import { cn } from '@/lib/utils'
import { useAuth } from '@/context/auth-context'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Skeleton } from '@/components/ui/skeleton'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { EChart } from '@/components/charts/echart'
import { axes, baseOption, type ChartTheme } from '@/lib/chart'
import { Meter } from '@/components/meter'
import { PageHeader, SectionTitle } from '@/components/page'
import { ErrorAlert } from '@/components/query-state'
import { BalanceCard } from '@/components/quota-cards'
import { Segmented } from '@/components/segmented'
import { Stat, StatRow } from '@/components/stat-card'
import { VendorLogo } from '@/components/vendor-logo'
import { TagBudgets } from './tag-budgets'

type Dim = 'route' | 'key_id' | 'model' | 'credential' | 'user_id' | 'tag' | 'client'

const DIM_LABEL: Record<Dim, string> = {
  route: '路由', key_id: 'API Key', model: '上游模型', credential: '上游凭证', user_id: '用户', tag: '标签', client: '客户端',
}

const RANGES = [
  { value: '1', label: '今天' },
  { value: '7', label: '7 天' },
  { value: '30', label: '30 天' },
  { value: '90', label: '90 天' },
]

const inputOf = (r?: Partial<UsageRow>) => (r?.input ?? 0) + (r?.cache_read ?? 0) + (r?.cache_write ?? 0)
const hitRate = (r?: Partial<UsageRow>) => (inputOf(r) > 0 ? (r!.cache_read ?? 0) / inputOf(r) : null)
const pct = (v: number | null, digits = 0) => (v === null ? '—' : `${(v * 100).toFixed(digits)}%`)
// 范围起点对齐到本地整天（服务端按小时汇总）；now 用默认参数惰性求值，避免渲染期直接调 Date.now
const rangeStart = (days: number, now = Date.now()) => {
  const d = new Date(now)
  d.setHours(0, 0, 0, 0)
  d.setDate(d.getDate() - (days - 1))
  return d.getTime()
}

export function Usage() {
  const { user } = useAuth()
  const isAdmin = user?.role === 'admin'
  const [range, setRange] = useState('7')
  const days = Number(range)
  const [dim, setDim] = useState<Dim>('route')
  const from = useMemo(() => rangeStart(days), [days])

  const total = useGet<UsageRow[]>(`/usage${qs({ from })}`)
  const hourly = useGet<UsageRow[]>(`/usage${qs({ from, group_by: 'hour' })}`)
  const byDim = useGet<UsageRow[]>(`/usage${qs({ from, group_by: dim })}`)
  const names = useNames()
  const t = total.data?.[0]

  const dims: Dim[] = !isAdmin ? ['route', 'key_id', 'model']
    : user?.auth_enabled === false ? ['route', 'model', 'credential', 'key_id', 'client', 'tag']
    : ['route', 'model', 'credential', 'key_id', 'user_id', 'client', 'tag']

  return (
    <>
      <PageHeader title='用量' subtitle={isAdmin ? '全部流量' : '你的 API Key 的流量'}
        actions={<Segmented value={range} onChange={setRange} options={RANGES} />} />
      {isAdmin && <Balances />}
      {total.error && <ErrorAlert message={total.error.message} />}
      {total.isPending ? <Skeleton className='h-[106px] rounded-xl' /> : (
        <StatRow>
          <Stat value={fmtTokens(inputOf(t) + (t?.output ?? 0))} label='Token' sub={`输入 ${fmtTokens(inputOf(t))} · 输出 ${fmtTokens(t?.output)}`} />
          <Stat value={fmtTokens(t?.cache_read)} label='缓存读取' sub={`命中率 ${pct(hitRate(t))}`} />
          <Stat value={fmtInt(t?.requests)} label='请求'
            sub={t?.errors ? <span className='text-destructive'>{fmtInt(t.errors)} 次失败</span> : '没有失败'} />
          <Stat value={fmtCost(t?.cost)} label='费用'
            sub={t?.plan_requests ? `${fmtInt(t.plan_requests)} 次走套餐${t.plan_usd ? `，等价 ${fmtCost(t.plan_usd)}` : ''}` : '按量计费'} />
          <Stat value={fmtInt(t?.cache_hits)} label='响应缓存命中'
            sub={t?.cache_hits ? `节省 ${fmtCost(t.saved_usd)}` : '未命中'} />
        </StatRow>
      )}

      <Card className='mt-4 min-w-0 gap-2 pb-3'>
        <CardHeader><CardTitle className='text-sm'>每日 Token</CardTitle></CardHeader>
        <CardContent className='px-3'>
          {hourly.data ? <DailyTokens rows={hourly.data} from={from} days={days} /> : <Skeleton className='h-[240px]' />}
        </CardContent>
      </Card>

      <SectionTitle actions={<Segmented size='sm' value={dim} onChange={setDim}
        options={dims.map((d) => ({ value: d, label: DIM_LABEL[d] }))} />}>按维度</SectionTitle>
      <div className='grid gap-4 lg:grid-cols-[minmax(0,1fr)_minmax(0,2fr)]'>
        <Card className='min-w-0 gap-2 pb-3'>
          <CardHeader><CardTitle className='text-sm'>占比</CardTitle></CardHeader>
          <CardContent className='px-3'>
            {byDim.data ? <Share rows={byDim.data} label={(r) => dimLabel(dim, r, names)} /> : <Skeleton className='h-[240px]' />}
          </CardContent>
        </Card>
        <Card className='min-w-0 gap-0 py-0'>
          {byDim.error && <ErrorAlert message={byDim.error.message} />}
          <DimTable dim={dim} rows={byDim.data ?? []} names={names} loading={byDim.isPending} />
        </Card>
      </div>
      {isAdmin && <TagBudgets />}
    </>
  )
}

type Names = ReturnType<typeof useNames>

function dimLabel(dim: Dim, r: UsageRow, names: Names): string {
  const v = r[dim] ?? null
  if (v === null) return '（无）'
  if (dim === 'client') return clientLabel(v)
  if (dim === 'key_id') return names.key(v)
  if (dim === 'credential') return names.credName(v)
  if (dim === 'user_id') return names.user(v)
  return v
}

/** 余额卡片 + 立即查询 */
function Balances() {
  const names = useNames()
  const invalidate = useInvalidate()
  const [busy, setBusy] = useState(false)
  const items = names.creds.filter((c) => c.balance_status)
  if (items.length === 0) return null
  const refresh = async () => {
    setBusy(true)
    try {
      await api.post('/balances/refresh')
      await invalidate('/credentials')
    } catch (e) {
      toast.error((e as Error).message)
    } finally {
      setBusy(false)
    }
  }
  return (
    <>
      <SectionTitle className='mt-0' actions={<Button variant='ghost' size='sm' onClick={refresh} disabled={busy} className='text-muted-foreground'>
        <RefreshCw className={cn(busy && 'animate-spin')} /> 立即查询</Button>}>余额</SectionTitle>
      <div className='mb-4 grid gap-3 sm:grid-cols-2 xl:grid-cols-3'>
        {items.map((c) => <BalanceCard key={c.id} cred={c} status={c.balance_status!} />)}
      </div>
    </>
  )
}

/** 每日 token：未命中缓存的输入、缓存读、输出堆叠，费用为折线 */
function DailyTokens({ rows, from, days }: { rows: UsageRow[]; from: number; days: number }) {
  const data = useMemo(() => {
    const map = byLocalDay(rows)
    return Array.from({ length: days }, (_, i) => {
      const d = new Date(from)
      d.setDate(d.getDate() + i)
      return { d, r: map.get(d.getTime()) }
    })
  }, [rows, from, days])
  // 只看今天时按小时
  const hours = useMemo(() => {
    if (days !== 1) return null
    const byHour = new Map(rows.map((r) => [r.hour ?? 0, r]))
    return Array.from({ length: 24 }, (_, i) => {
      const h = from + i * 3600e3
      return { h, r: byHour.get(h) }
    })
  }, [rows, from, days])
  const option = useCallback((t: ChartTheme) => {
    const pts = hours
      ? hours.map(({ h, r }) => ({ x: `${new Date(h).getHours()}:00`, r }))
      : data.map(({ d, r }) => ({ x: `${d.getMonth() + 1}/${d.getDate()}`, r }))
    const bar = { type: 'bar', stack: 't', barMaxWidth: 28 }
    return {
      ...baseOption(t),
      ...axes(t, pts.map((p) => p.x), (v) => fmtTokens(v)),
      yAxis: [
        { ...axes(t, [], (v) => fmtTokens(v)).yAxis },
        { type: 'value', splitLine: { show: false }, axisLabel: { color: t.muted, formatter: (v: number) => fmtCost(v) } },
      ],
      tooltip: {
        ...(baseOption(t).tooltip as object),
        valueFormatter: undefined,
        formatter: (ps: { axisIndex: number; dataIndex: number; seriesName: string; value: number; marker: string }[]) => {
          const r = pts[ps[0].dataIndex].r
          return [`<b>${pts[ps[0].dataIndex].x}</b>`,
            ...ps.map((p) => `${p.marker}${p.seriesName} ${p.seriesName === '费用' ? fmtCost(p.value) : fmtTokens(p.value)}`),
            r ? `请求 ${fmtInt(r.requests)} · 缓存命中 ${pct(hitRate(r))}` : ''].filter(Boolean).join('<br/>')
        },
      },
      series: [
        { ...bar, name: '输入', itemStyle: { color: t.palette[0] }, data: pts.map(({ r }) => (r ? r.input + r.cache_write : 0)) },
        { ...bar, name: '缓存读', itemStyle: { color: t.palette[0], opacity: 0.35 }, data: pts.map(({ r }) => r?.cache_read ?? 0) },
        { ...bar, name: '输出', itemStyle: { color: t.palette[1], borderRadius: [3, 3, 0, 0] }, data: pts.map(({ r }) => r?.output ?? 0) },
        // 全部走套餐（费用为 0）时不画费用线
        ...(pts.some(({ r }) => (r?.cost ?? 0) > 0) ? [{
          name: '费用', type: 'line', yAxisIndex: 1, smooth: true, symbolSize: 4, lineStyle: { width: 1.5, color: t.palette[3] },
          itemStyle: { color: t.palette[3] }, data: pts.map(({ r }) => r?.cost ?? 0) }] : []),
      ],
    }
  }, [data, hours])
  return <EChart option={option} height={260} />
}

/** 占比环图：按费用（没有费用时按套餐等价，再没有按 token），前 6 项 + 其他 */
function Share({ rows, label }: { rows: UsageRow[]; label: (r: UsageRow) => string }) {
  const option = useCallback((t: ChartTheme) => {
    const metric = rows.some((r) => r.cost > 0) ? 'cost' : rows.some((r) => (r.plan_usd ?? 0) > 0) ? 'plan_usd' : 'tokens'
    const val = (r: UsageRow) => metric === 'cost' ? r.cost : metric === 'plan_usd' ? r.plan_usd ?? 0 : inputOf(r) + r.output
    const sorted = [...rows].sort((a, b) => val(b) - val(a))
    const top = sorted.slice(0, 6).map((r) => ({ name: label(r), value: val(r) }))
    const rest = sorted.slice(6).reduce((s, r) => s + val(r), 0)
    if (rest > 0) top.push({ name: '其他', value: rest })
    const fmt = (v: number) => (metric === 'tokens' ? fmtTokens(v) : fmtCost(v))
    return {
      ...baseOption(t),
      tooltip: { ...(baseOption(t).tooltip as object), trigger: 'item', valueFormatter: fmt },
      legend: { ...(baseOption(t).legend as object), type: 'scroll', top: 'auto', bottom: 0, left: 'center', right: 'auto' },
      title: {
        text: metric === 'cost' ? '费用' : metric === 'plan_usd' ? '套餐等价' : 'Token', left: 'center', top: '36%',
        textStyle: { color: t.muted, fontSize: 12, fontWeight: 'normal' },
        subtext: fmt(top.reduce((s, x) => s + x.value, 0)), subtextStyle: { color: t.fg, fontSize: 18, fontWeight: 600 },
      },
      series: [{
        type: 'pie', radius: ['52%', '72%'], center: ['50%', '44%'], avoidLabelOverlap: true,
        itemStyle: { borderColor: t.card, borderWidth: 2, borderRadius: 4 }, label: { show: false },
        data: top.length ? top : [{ name: '没有数据', value: 0, itemStyle: { color: t.border } }],
      }],
    }
  }, [rows, label])
  return <EChart option={option} height={260} />
}

function DimTable({ dim, rows, names, loading }: { dim: Dim; rows: UsageRow[]; names: Names; loading: boolean }) {
  const sorted = [...rows].sort((a, b) => b.cost - a.cost || (b.plan_usd ?? 0) - (a.plan_usd ?? 0) || b.requests - a.requests)
  const max = Math.max(...sorted.map((r) => r.cost + (r.plan_usd ?? 0)), 0)
  const mono = dim === 'route' || dim === 'model' || dim === 'tag'
  return (
    <div className='overflow-x-auto'>
      <Table>
        <TableHeader>
          <TableRow className='[&>th]:h-10 [&>th]:text-xs [&>th]:text-muted-foreground'>
            <TableHead className='ps-5'>{DIM_LABEL[dim]}</TableHead>
            <TableHead className='text-end'>请求</TableHead>
            <TableHead className='text-end'>输入 / 缓存命中</TableHead>
            <TableHead className='text-end'>输出</TableHead>
            <TableHead className='text-end'>P50 / P95</TableHead>
            <TableHead className='min-w-36 pe-5 text-end'>费用</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {sorted.map((r, i) => {
            const cred = dim === 'credential' ? names.cred(r.credential) : undefined
            return (
              <TableRow key={i} className='num'>
                <TableCell className={cn('max-w-64 truncate ps-5', mono && 'font-mono text-[13px]')}>
                  <span className='inline-flex items-center gap-2'>
                    {(dim === 'credential' || dim === 'model' || dim === 'client') && (
                      <VendorLogo hints={dim === 'credential' ? [cred?.provider, cred?.base_url, cred?.name] : [r[dim]]} />
                    )}
                    {dimLabel(dim, r, names)}
                  </span>
                </TableCell>
                <TableCell className='text-end'>
                  {fmtInt(r.requests)}
                  {r.errors > 0 && <div className='text-xs text-destructive'>{fmtInt(r.errors)} 失败</div>}
                </TableCell>
                <TableCell className='text-end'>
                  {fmtTokens(inputOf(r))}
                  <div className='text-xs text-muted-foreground'>{pct(hitRate(r))}</div>
                </TableCell>
                <TableCell className='text-end'>{fmtTokens(r.output)}</TableCell>
                <TableCell className='text-end whitespace-nowrap'>
                  {r.p50_ms != null ? `${fmtMs(r.p50_ms)} / ${fmtMs(r.p95_ms)}` : '—'}
                  {r.ttft_p50_ms != null && <div className='text-xs text-muted-foreground'>首 token {fmtMs(r.ttft_p50_ms)}</div>}
                </TableCell>
                <TableCell className='pe-5 text-end'>
                  {fmtCost(r.cost)}
                  {!!r.plan_usd && <div className='text-xs text-muted-foreground'>套餐等价 {fmtCost(r.plan_usd)}</div>}
                  <Meter className='mt-1' tone='primary' pct={max ? ((r.cost + (r.plan_usd ?? 0)) / max) * 100 : 0} />
                </TableCell>
              </TableRow>
            )
          })}
          {!loading && sorted.length === 0 && (
            <TableRow><TableCell colSpan={6} className='py-10 text-center text-muted-foreground'>该时间范围内没有用量</TableCell></TableRow>
          )}
        </TableBody>
      </Table>
    </div>
  )
}
