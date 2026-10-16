import { useCallback, useMemo } from 'react'
import { Link } from '@tanstack/react-router'
import { AlertTriangle, ArrowRight, Check } from 'lucide-react'
import { byLocalDay, type Credential, type Overview, type UsageRow } from '@/lib/api'
import { fmtCost, fmtInt, fmtMs, fmtTime, fmtTokens, todayStart } from '@/lib/format'
import { useGet } from '@/lib/query'
import { cn } from '@/lib/utils'
import { useAuth } from '@/context/auth-context'
import { Alert, AlertDescription } from '@/components/ui/alert'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Skeleton } from '@/components/ui/skeleton'
import { EChart } from '@/components/charts/echart'
import { axes, baseOption, type ChartTheme } from '@/lib/chart'
import { PageHeader, SectionTitle } from '@/components/page'
import { BalanceCard, PlanCard } from '@/components/quota-cards'
import { ErrorAlert } from '@/components/query-state'
import { Stat, StatRow } from '@/components/stat-card'

export function Dashboard() {
  const { user } = useAuth()
  const isAdmin = user?.role === 'admin'
  const overview = useGet<Overview>('/overview', { refetchInterval: 60_000 })
  const creds = useGet<Credential[]>(isAdmin ? '/credentials' : null)
  const data = overview.data

  return (
    <>
      <PageHeader title='仪表盘' subtitle={isAdmin ? '全部流量，最近 24 小时' : '你的 API Key 的流量，最近 24 小时'} />
      {overview.error && <ErrorAlert message={overview.error.message} />}
      {data?.counts && <Onboarding counts={data.counts} />}
      {data ? <Summary u={data.usage_24h} /> : <Skeleton className='h-[106px] rounded-xl' />}
      <div className='mt-4 grid gap-4 lg:grid-cols-2'>
        <ChartCard title='最近 24 小时' loading={!data}>
          {data && <HourlyChart rows={data.hourly} />}
        </ChartCard>
        <ChartCard title='最近 14 天 Token' loading={!data}>
          {data && <DailyChart rows={data.hourly} />}
        </ChartCard>
      </div>
      {isAdmin && creds.data && <Quotas creds={creds.data} />}
      {data?.counts && (
        <>
          <SectionTitle>配置</SectionTitle>
          <StatRow>
            <Stat value={fmtInt(data.counts.routes)} label='路由' />
            <Stat value={fmtInt(data.counts.credentials)} label='上游凭证' />
            <Stat value={fmtInt(data.counts.keys)} label='API Key' />
            <Stat value={fmtInt(data.counts.catalog_models)} label='目录模型'
              sub={data.catalog_sync?.at ? `同步于 ${fmtTime(data.catalog_sync.at)}` : '尚未同步'} />
          </StatRow>
          {data.catalog_sync?.status === 'error' && (
            <Alert className='mt-3 border-warning/40 text-warning'>
              <AlertTriangle />
              <AlertDescription className='text-warning'>最近一次模型目录同步失败：{data.catalog_sync.error}</AlertDescription>
            </Alert>
          )}
        </>
      )}
    </>
  )
}

function Summary({ u }: { u: Partial<UsageRow> }) {
  const input = (u.input ?? 0) + (u.cache_read ?? 0) + (u.cache_write ?? 0)
  const hit = input > 0 ? Math.round(((u.cache_read ?? 0) / input) * 100) : null
  return (
    <StatRow>
      <Stat value={fmtInt(u.requests)} label='请求' tone={u.errors ? undefined : undefined}
        sub={u.errors ? <span className='text-destructive'>{fmtInt(u.errors)} 次失败</span> : '没有失败'} />
      <Stat value={fmtTokens(input + (u.output ?? 0))} label='Token' sub={`输入 ${fmtTokens(input)} · 输出 ${fmtTokens(u.output)}`} />
      <Stat value={hit === null ? '—' : `${hit}%`} label='缓存命中' sub={`读取 ${fmtTokens(u.cache_read)}`} />
      <Stat value={fmtCost(u.cost)} label='费用'
        sub={u.plan_requests ? `${fmtInt(u.plan_requests)} 次走套餐${u.plan_usd ? `，等价 ${fmtCost(u.plan_usd)}` : ''}`
          : u.cache_hits ? `响应缓存节省 ${fmtCost(u.saved_usd)}` : '按量计费'} />
      <Stat value={u.p50_ms != null ? fmtMs(u.p50_ms) : '—'} label='延迟 P50'
        sub={u.p95_ms != null ? `P95 ${fmtMs(u.p95_ms)}${u.ttft_p50_ms != null ? ` · 首 token ${fmtMs(u.ttft_p50_ms)}` : ''}` : undefined} />
    </StatRow>
  )
}

function ChartCard({ title, loading, children }: { title: string; loading: boolean; children: React.ReactNode }) {
  return (
    <Card className='min-w-0 gap-2 pb-3'>
      <CardHeader><CardTitle className='text-sm'>{title}</CardTitle></CardHeader>
      <CardContent className='px-3'>{loading ? <Skeleton className='h-[220px]' /> : children}</CardContent>
    </Card>
  )
}

/** 最近 24 小时每小时的请求（成功 / 失败堆叠）与 P95 延迟 */
// 当前小时的整点毫秒；默认参数惰性求值，避免渲染期直接调 Date.now()
const hourStart = (now = Date.now()) => Math.floor(now / 3600e3) * 3600e3
function HourlyChart({ rows }: { rows: UsageRow[] }) {
  const hours = useMemo(() => {
    const byHour = new Map(rows.map((r) => [r.hour ?? 0, r]))
    const now = hourStart()
    return Array.from({ length: 24 }, (_, i) => {
      const h = now - (23 - i) * 3600e3
      return { h, r: byHour.get(h) }
    })
  }, [rows])
  const option = useCallback((t: ChartTheme) => ({
    ...baseOption(t),
    ...axes(t, hours.map(({ h }) => `${new Date(h).getHours()}:00`)),
    yAxis: [
      { ...axes(t, []).yAxis, minInterval: 1 },
      { type: 'value', splitLine: { show: false }, axisLabel: { color: t.muted, formatter: (v: number) => fmtMs(v) } },
    ],
    series: [
      { name: '成功', type: 'bar', stack: 'r', barMaxWidth: 14, itemStyle: { color: t.palette[0] },
        data: hours.map(({ r }) => (r ? r.requests - r.errors : 0)) },
      { name: '失败', type: 'bar', stack: 'r', barMaxWidth: 14, itemStyle: { color: t.danger, borderRadius: [3, 3, 0, 0] },
        data: hours.map(({ r }) => r?.errors ?? 0) },
      { name: 'P95 延迟', type: 'line', yAxisIndex: 1, smooth: true, symbolSize: 5, connectNulls: true,
        lineStyle: { width: 1.5, color: t.palette[3] }, itemStyle: { color: t.palette[3] },
        data: hours.map(({ r }) => r?.p95_ms ?? null) },
    ],
    tooltip: { ...(baseOption(t).tooltip as object), valueFormatter: undefined },
  }), [hours])
  return <EChart option={option} height={220} />
}

/** 最近 14 天每天的 token：未命中缓存的输入、缓存读、输出 */
function DailyChart({ rows }: { rows: UsageRow[] }) {
  const days = useMemo(() => {
    const byDay = byLocalDay(rows)
    const today = new Date(todayStart())
    return Array.from({ length: 14 }, (_, i) => {
      const d = new Date(today)
      d.setDate(d.getDate() - (13 - i)) // 逐日回退，避免夏令时错位
      return { d, r: byDay.get(d.getTime()) }
    })
  }, [rows])
  const option = useCallback((t: ChartTheme) => ({
    ...baseOption(t),
    ...axes(t, days.map(({ d }) => `${d.getMonth() + 1}/${d.getDate()}`), (v) => fmtTokens(v)),
    tooltip: { ...(baseOption(t).tooltip as object), valueFormatter: (v: number) => fmtTokens(v) },
    series: [
      { name: '输入', type: 'bar', stack: 't', barMaxWidth: 22, itemStyle: { color: t.palette[0] },
        data: days.map(({ r }) => (r ? r.input + r.cache_write : 0)) },
      { name: '缓存读', type: 'bar', stack: 't', barMaxWidth: 22, itemStyle: { color: t.palette[0], opacity: 0.35 },
        data: days.map(({ r }) => r?.cache_read ?? 0) },
      { name: '输出', type: 'bar', stack: 't', barMaxWidth: 22, itemStyle: { color: t.palette[1], borderRadius: [3, 3, 0, 0] },
        data: days.map(({ r }) => r?.output ?? 0) },
    ],
  }), [days])
  return <EChart option={option} height={220} />
}

/** 套餐额度与余额（配置了的凭证） */
function Quotas({ creds }: { creds: Credential[] }) {
  const plans = creds.filter((c) => c.plan_status)
  const balances = creds.filter((c) => c.balance_status)
  if (plans.length + balances.length === 0) return null
  return (
    <>
      <SectionTitle actions={<Button asChild variant='ghost' size='sm' className='text-muted-foreground'>
        <Link to='/credentials'>管理凭证 <ArrowRight /></Link></Button>}>套餐与余额</SectionTitle>
      <div className='grid gap-3 sm:grid-cols-2 xl:grid-cols-3'>
        {plans.map((c) => <PlanCard key={c.id} cred={c} status={c.plan_status!} />)}
        {balances.map((c) => <BalanceCard key={c.id} cred={c} status={c.balance_status!} />)}
      </div>
    </>
  )
}

/** 冷启动引导：同步目录 → 添加凭证 → 创建路由 → 创建 Key */
function Onboarding({ counts }: { counts: NonNullable<Overview['counts']> }) {
  const steps = [
    { label: '同步模型目录', done: counts.catalog_models > 0, to: '/models' },
    { label: '添加上游凭证', done: counts.credentials > 0, to: '/credentials' },
    { label: '创建路由', done: counts.routes > 0, to: '/routes' },
    { label: '创建 API Key', done: counts.keys > 0, to: '/keys' },
  ]
  const next = steps.find((s) => !s.done)
  if (!next) return null
  return (
    <Card className='mb-4'>
      <CardContent className='flex flex-wrap items-center gap-x-6 gap-y-3'>
        <span className='font-semibold'>开始使用</span>
        <ol className='flex flex-wrap items-center gap-x-5 gap-y-2'>
          {steps.map((s, i) => (
            <li key={s.label} className={cn('flex items-center gap-2 text-sm', s.done ? 'text-muted-foreground' : s === next ? 'font-medium' : 'text-muted-foreground')}>
              <span className={cn('flex size-5 items-center justify-center rounded-full text-[11px]',
                s.done ? 'bg-success-soft text-success' : s === next ? 'bg-primary text-primary-foreground' : 'bg-secondary')}>
                {s.done ? <Check className='size-3' /> : i + 1}
              </span>
              {s.label}
            </li>
          ))}
        </ol>
        <Button asChild size='sm' className='ms-auto'><Link to={next.to}>下一步：{next.label} <ArrowRight /></Link></Button>
      </CardContent>
    </Card>
  )
}
