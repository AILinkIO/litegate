import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { api, clientLabel, qs, type LiveActive, type LiveState, type LiveTarget, type NarrativeLine, type Route } from '@/lib/api'
import { fmtInt, fmtMs } from '@/lib/format'
import { useGet } from '@/lib/query'
import { AFFINITY_HELP, STRATEGY_HELP, STRATEGY_LABEL } from '@/lib/routing'
import { cn } from '@/lib/utils'
import { Logo } from '@/assets/logo'
import { Narrative } from '@/components/narrative'
import { PageHeader } from '@/components/page'
import { SimpleSelect } from '@/components/form-controls'
import { Empty } from '@/components/query-state'
import { VendorLogo } from '@/components/vendor-logo'

const KIND_LABEL: Record<string, string> = {
  rate_limit: '限流', credit: '余额不足', quota: '额度用尽', unserved: '无此模型', server: '服务端错误', network: '网络错误',
  timeout: '超时', auth: '鉴权失败', client: '请求错误', concurrency: '并发已满',
}

interface Last { route: string; narrative: NarrativeLine[]; ts: number }
type Pos = { x: number; y: number }

// 拓扑区宽度（卡片内容宽度）不足时改为纵向：客户端在上、网关居中、候选目标在下；与下面的容器查询 @min-[40rem]/live 一致
const VERTICAL_BELOW = 640
// 纵向时候选目标列表左侧留出的主干位置（距拓扑区左边）
const SPINE_X = 10

// 客户端连线用的颜色（图表色板）
const COLORS = ['var(--chart-1)', 'var(--chart-2)', 'var(--chart-3)', 'var(--chart-4)', 'var(--chart-5)', 'var(--chart-6)']

/** 实时路由视图：客户端 → 网关 → 候选目标，此刻网关在做什么 */
export function Live() {
  const routesCfg = useGet<Route[]>('/routes')
  const [route, setRoute] = useState<string | null>(null)
  const [state, setState] = useState<LiveState | null>(null)
  const [fetchedAt, setFetchedAt] = useState(() => Date.now())
  const [active, setActive] = useState<Record<string, LiveActive>>({})
  const [last, setLast] = useState<Last | null>(null)
  const [connected, setConnected] = useState(false)
  const [now, setNow] = useState(() => Date.now())
  const refreshTimer = useRef<number | undefined>(undefined)
  const connectedRef = useRef(false)
  const lastRefreshAt = useRef(0)
  // 刚启动、还没有流量时网关没有「当前路由」：默认看第一条配置的路由
  const firstRoute = routesCfg.data?.[0]?.name
  const selected = route ?? state?.selected ?? firstRoute ?? null

  const apply = useCallback((s: LiveState) => {
    setState(s)
    setFetchedAt(Date.now())
    setActive(Object.fromEntries(s.active.map((a) => [a.request_id, a])))
  }, [])

  const refresh = useCallback(async () => {
    try {
      apply(await api.get<LiveState>(`/live/state${qs({ route: selected ?? undefined })}`))
    } catch {
      // 断线时保留上一次的画面
    }
  }, [selected, apply])

  const refreshSoon = useCallback(() => {
    window.clearTimeout(refreshTimer.current)
    // 高流量下 attempt_end / request_end 频繁到达：防抖 + 最小间隔 1s，避免每秒多次全量快照
    const wait = Math.max(0, 1000 - (Date.now() - lastRefreshAt.current))
    refreshTimer.current = window.setTimeout(() => {
      lastRefreshAt.current = Date.now()
      refresh()
    }, wait)
  }, [refresh])

  // SSE：快照 + 事件；页面不在前台时断开
  useEffect(() => {
    let es: EventSource | null = null
    const on = (type: string, fn: (d: Record<string, unknown>) => void) =>
      es!.addEventListener(type, (e) => {
        const d = JSON.parse((e as MessageEvent).data)
        // 后端积压丢过事件时在下一条事件带 dropped 计数：丢了的只能全量对账
        if (typeof d.dropped === 'number' && d.dropped > 0) refresh()
        fn(d)
      })
    const patch = (id: unknown, fn: (a: LiveActive) => LiveActive) =>
      setActive((m) => (m[id as string] ? { ...m, [id as string]: fn(m[id as string]) } : m))
    const open = () => {
      if (es) return
      es = new EventSource(`/api/live/stream${qs({ route: route ?? undefined })}`)
      es.onopen = () => { connectedRef.current = true; setConnected(true) }
      es.onerror = () => { connectedRef.current = false; setConnected(false) }
      on('state', (d) => apply(d as unknown as LiveState))
      on('request_start', (d) => {
        const a = d as unknown as LiveActive
        setActive((m) => ({ ...m, [a.request_id]: { ...a, state: 'waiting' } }))
      })
      on('decision', (d) => patch(d.request_id, (a) => ({ ...a, route: d.route as string })))
      on('attempt_start', (d) => patch(d.request_id, (a) => ({ ...a, state: 'attempting', credential: d.credential as string,
        upstream_model: d.upstream_model as string })))
      on('attempt_end', (d) => {
        if (!d.ok) patch(d.request_id, (a) => ({ ...a, state: 'waiting' }))
        refreshSoon()
      })
      on('request_end', (d) => {
        setActive((m) => {
          const next = { ...m }
          delete next[d.request_id as string]
          return next
        })
        if (Array.isArray(d.narrative) && d.narrative.length) {
          setLast({ route: d.route as string, narrative: d.narrative as NarrativeLine[], ts: Date.now() })
        }
        refreshSoon()
      })
    }
    const close = () => {
      es?.close()
      es = null
      connectedRef.current = false
      setConnected(false)
    }
    const onVisible = () => (document.hidden ? close() : open())
    open()
    document.addEventListener('visibilitychange', onVisible)
    // 兜底轮询只服务断连期间（重连后 SSE 的 state 快照会重新对账）；健康连接时纯事件驱动
    const poll = window.setInterval(() => { if (!connectedRef.current && !document.hidden) refresh() }, 5000)
    const tick = window.setInterval(() => setNow(Date.now()), 1000)
    return () => {
      close()
      document.removeEventListener('visibilitychange', onVisible)
      window.clearInterval(poll)
      window.clearInterval(tick)
      window.clearTimeout(refreshTimer.current)
    }
  }, [route, refresh, refreshSoon, apply])

  // 刚启动、还没有流量时网关没有「当前路由」：默认选第一条配置的路由
  const cfg = routesCfg.data?.find((r) => r.name === selected)
  const stats = state?.routes.find((r) => r.route === selected)
  const activeHere = useMemo(() => Object.values(active).filter((a) => a.route === selected), [active, selected])
  const names = useMemo(() => [...new Set([...(state?.routes ?? []).map((r) => r.route), ...(routesCfg.data ?? []).map((r) => r.name)])],
    [state, routesCfg.data])

  // 客户端：最近 5 分钟调用过的，加上正在进行的
  const clients = useMemo(() => {
    const m = new Map<string, { client: string | null; key_name: string | null; requests: number; active: number }>()
    for (const c of stats?.clients ?? []) m.set(`${c.client}|${c.key_name}`, { ...c, active: 0 })
    for (const a of activeHere) {
      const k = `${a.client}|${a.key_name}`
      const c = m.get(k) ?? { client: a.client, key_name: a.key_name, requests: 0, active: 0 }
      m.set(k, { ...c, active: c.active + 1 })
    }
    return [...m.entries()].sort((a, b) => b[1].active - a[1].active || b[1].requests - a[1].requests).slice(0, 6)
  }, [stats, activeHere])

  const targets = useMemo(() => (state?.selected === selected ? state?.targets ?? [] : []), [state, selected])
  const answering = (t: LiveTarget) =>
    activeHere.filter((a) => a.state === 'attempting' && a.credential === t.credential && a.upstream_model === t.upstream_model)
  // 实时事件里的最近一次优先；刚打开页面时用快照里的
  const lastHere = last && last.route === selected ? last : state?.last && state.last.route === selected ? state.last : null

  // ---- 连线：测量节点位置，画 SVG ----
  const box = useRef<HTMLDivElement>(null)
  const gw = useRef<HTMLDivElement>(null)
  const clientRefs = useRef<Record<string, HTMLDivElement | null>>({})
  const targetRefs = useRef<Record<string, HTMLDivElement | null>>({})
  const [geo, setGeo] = useState<{ w: number; h: number; vertical: boolean; gwIn: Pos; gwOut: Pos; clients: Record<string, Pos>; targets: Record<string, Pos> } | null>(null)
  const measure = useCallback(() => {
    const root = box.current?.getBoundingClientRect()
    const g = gw.current?.getBoundingClientRect()
    if (!root || !g) return
    const vertical = root.width < VERTICAL_BELOW
    // 锚点：横向时取左 / 右边中点，纵向时取上 / 下边中点（候选目标始终取左边中点）
    const rel = (r: DOMRect, side: 'left' | 'right' | 'top' | 'bottom'): Pos => ({
      x: (side === 'left' ? r.left : side === 'right' ? r.right : r.left + r.width / 2) - root.left,
      y: (side === 'top' ? r.top : side === 'bottom' ? r.bottom : r.top + r.height / 2) - root.top,
    })
    const cs: Record<string, Pos> = {}
    for (const [k, el] of Object.entries(clientRefs.current)) if (el) cs[k] = rel(el.getBoundingClientRect(), vertical ? 'bottom' : 'right')
    const ts: Record<string, Pos> = {}
    for (const [k, el] of Object.entries(targetRefs.current)) if (el) ts[k] = rel(el.getBoundingClientRect(), 'left')
    setGeo({ w: root.width, h: root.height, vertical, gwIn: rel(g, vertical ? 'top' : 'left'), gwOut: rel(g, vertical ? 'bottom' : 'right'),
      clients: cs, targets: ts })
  }, [])
  useLayoutEffect(measure, [measure, clients.length, targets.length, selected])
  useEffect(() => {
    const ro = new ResizeObserver(measure)
    if (box.current) ro.observe(box.current)
    return () => ro.disconnect()
  }, [measure])

  const curve = (a: Pos, b: Pos) => {
    const mx = (a.x + b.x) / 2
    return `M ${a.x} ${a.y} C ${mx} ${a.y}, ${mx} ${b.y}, ${b.x} ${b.y}`
  }
  // 纵向：客户端底部 → 网关顶部用竖向曲线
  const curveV = (a: Pos, b: Pos) => {
    const my = (a.y + b.y) / 2
    return `M ${a.x} ${a.y} C ${a.x} ${my}, ${b.x} ${my}, ${b.x} ${b.y}`
  }
  // 纵向：网关底部 → 左侧主干 → 横向进入候选目标左边（树形，不穿过目标卡片）
  const tree = (g: Pos, t: Pos) => `M ${g.x} ${g.y} V ${g.y + 12} H ${SPINE_X} V ${t.y} H ${t.x}`
  const tKey = (t: LiveTarget) => `${t.credential}|${t.upstream_model}`

  const status = (t: LiveTarget): { text: string; tone: 'fg' | 'muted' | 'danger' | 'warning'; dashed?: boolean } => {
    const n = answering(t).length
    if (n > 0) return { text: n > 1 ? `回答中 ×${n}…` : '回答中…', tone: 'fg' }
    if (t.state === 'exhausted') return { text: '套餐额度用尽', tone: 'danger', dashed: true }
    if (t.cooldown) {
      const left = Math.max(0, t.cooldown.remaining_ms - (now - fetchedAt))
      if (left > 0) return { text: `${KIND_LABEL[t.cooldown.kind] ?? t.cooldown.kind} · ${fmtMs(Math.ceil(left / 1000) * 1000)}后恢复`, tone: 'danger', dashed: true }
    }
    if (t.concurrency) {
      const q = t.concurrency.queued ? ` · 排队 ${t.concurrency.queued}` : ''
      return { text: `并发 ${t.concurrency.inflight}/${t.concurrency.max}${q}`, tone: 'muted' }
    }
    if (t.tier === 'reserve') return { text: '套餐保留', tone: 'warning' }
    // 套餐窗口说明（已用比例、重置时间）只放悬停提示：长文字会撑宽目标列，让连线错位
    return { text: '空闲', tone: 'muted' }
  }

  // 嵌套路由的成员按经过的路由分组显示
  const groups = useMemo(() => {
    const out: { via: string | null; items: LiveTarget[] }[] = []
    for (const t of targets) {
      const via = t.via?.join(' › ') ?? null
      const g = out[out.length - 1]
      if (g && g.via === via) g.items.push(t)
      else out.push({ via, items: [t] })
    }
    return out
  }, [targets])

  const strategy = cfg?.options?.strategy ?? 'weighted'
  const affinity = cfg?.options?.affinity ?? 'auto'

  return (
    <>
      <PageHeader title='路由视图' subtitle={
        <span className='flex items-center gap-2'>
          <span className={cn('size-2 rounded-full', connected ? 'bg-success' : 'bg-muted-foreground/50')} />
          {connected ? '实时 · 网关正在做的决定' : '未连接，正在重试…'}
        </span>
      } actions={
        <SimpleSelect className='w-56 bg-card font-mono' value={selected ?? ''} onChange={setRoute} placeholder='选择路由'
          options={names.map((n) => ({ value: n, label: n }))} />
      } />

      {!selected ? (
        <div className='rounded-xl border bg-card'><Empty>还没有路由。创建路由并发送请求后，这里会实时显示网关的决定。</Empty></div>
      ) : (
        <div className='@container/live min-w-0 rounded-xl border bg-card p-5'>
          <div className='font-semibold'>
            <span className='font-mono'>{selected}</span>
            <span className='ms-2 font-normal text-muted-foreground'>· {targets.length} 个候选{activeHere.length > 0 && ` · ${activeHere.length} 个请求进行中`}</span>
          </div>
          <p className='mt-1 text-sm text-muted-foreground'>
            {STRATEGY_LABEL[strategy]}：{STRATEGY_HELP[strategy]}。会话粘性：{AFFINITY_HELP[affinity]}。
            {!!cfg?.options?.rules?.length && ` 规则 ${cfg.options.rules.length} 条。`}
          </p>

          {/* 拓扑：按卡片自身宽度（容器查询）切换——够宽时三列加连线，列宽可收缩、长文字截断，不撑破卡片；
              太窄时上下堆叠、不画连线（侧边栏占去的宽度用视口断点判断不准） */}
          <div ref={box} className='relative mt-6 grid min-w-0 grid-cols-1 items-center gap-6 @min-[40rem]/live:grid-cols-[minmax(0,1fr)_auto_minmax(0,2fr)] @min-[40rem]/live:gap-8 @3xl/live:gap-12'>
            {geo && (
              <svg width={geo.w} height={geo.h} className='pointer-events-none absolute inset-0 overflow-visible'>
                <style>{'@keyframes lgDash { to { stroke-dashoffset: -20 } } .flow { animation: lgDash .8s linear infinite } @media (prefers-reduced-motion: reduce) { .flow { animation: none } }'}</style>
                {clients.map(([k, c], i) => geo.clients[k] && (
                  <path key={k} d={(geo.vertical ? curveV : curve)(geo.clients[k], geo.gwIn)} fill='none'
                    stroke={c.active ? COLORS[i % COLORS.length] : 'var(--border)'} strokeWidth={c.active ? 2 : 1.5}
                    strokeDasharray={c.active ? '5 5' : undefined} className={c.active ? 'flow' : undefined} />
                ))}
                {targets.map((t) => {
                  const p = geo.targets[tKey(t)]
                  if (!p) return null
                  const on = answering(t)
                  const ci = on.length ? clients.findIndex(([, c]) => c.client === on[0].client && c.key_name === on[0].key_name) : -1
                  return (
                    <path key={tKey(t)} d={geo.vertical ? tree(geo.gwOut, p) : curve(geo.gwOut, p)} fill='none'
                      stroke={on.length ? COLORS[Math.max(0, ci) % COLORS.length] : 'var(--border)'} strokeWidth={on.length ? 2 : 1.5}
                      strokeDasharray={on.length ? '5 5' : t.state === 'idle' ? undefined : '2 4'} className={on.length ? 'flow' : undefined} />
                  )
                })}
              </svg>
            )}

            {/* 客户端 */}
            <div className='z-10 flex flex-wrap justify-center gap-3 @min-[40rem]/live:grid @min-[40rem]/live:justify-stretch'>
              {clients.length === 0 && <p className='text-sm text-muted-foreground'>最近 5 分钟没有请求</p>}
              {clients.map(([k, c], i) => (
                <div key={k} ref={(el) => { clientRefs.current[k] = el }} className='min-w-40 rounded-xl border bg-card px-3 py-2.5 text-center'>
                  <div className='flex items-center justify-center gap-2'>
                    <span className='size-2 rounded-full' style={{ background: c.active ? COLORS[i % COLORS.length] : 'var(--muted-foreground)', opacity: c.active ? 1 : 0.4 }} />
                    {c.client && <VendorLogo hints={[c.client]} fallback={c.client} />}
                    <span className='text-sm font-semibold'>{clientLabel(c.client)}</span>
                  </div>
                  <div className='mt-0.5 text-xs text-muted-foreground'>{c.key_name ?? '—'} · {fmtInt(c.requests)} 次{c.active ? ` · ${c.active} 进行中` : ''}</div>
                </div>
              ))}
            </div>

            {/* 网关 */}
            <div ref={gw} className='z-10 justify-self-center rounded-xl border-2 border-foreground bg-card px-6 py-4 text-center'>
              <div className='flex items-center justify-center gap-2'><Logo className='size-5' /><span className='font-semibold'>LiteGate</span></div>
              <div className='mt-0.5 font-mono text-xs text-muted-foreground'>{selected}</div>
              <span className='mt-2 inline-block rounded-full bg-foreground px-2.5 py-0.5 text-xs font-semibold text-background'>{STRATEGY_LABEL[strategy]}</span>
            </div>

            {/* 候选目标 */}
            <div className='z-10 grid min-w-0 grid-cols-1 gap-2 ps-6 @min-[40rem]/live:ps-0'>
              {targets.length === 0 && <p className='text-sm text-muted-foreground'>这条路由没有可用的候选</p>}
              {groups.map((g, gi) => (
                <div key={gi} className={cn('grid min-w-0 grid-cols-1 gap-2', gi > 0 && g.via && 'mt-1')}>
                  {g.via && <span className='ps-1 text-xs text-muted-foreground'>嵌套路由 <span className='font-mono'>{g.via}</span></span>}
                  {g.items.map((t) => {
                    const st = status(t)
                    const on = answering(t).length > 0
                    return (
                      <div key={tKey(t)} ref={(el) => { targetRefs.current[tKey(t)] = el }}
                        className={cn('flex items-center gap-2.5 rounded-xl bg-card px-3 py-2', on ? 'border-2 border-foreground' : 'border',
                          st.dashed && 'border-dashed', t.state === 'exhausted' && 'opacity-70')}>
                        <span className={cn('size-2.5 shrink-0 rounded-full border-[1.5px]', on ? 'border-foreground bg-foreground' : 'border-muted-foreground/50')} />
                        <VendorLogo hints={[t.credential_name, t.upstream_model]} fallback={t.credential_name} />
                        <span className='max-w-[40%] shrink-0 truncate text-sm font-semibold'>{t.credential_name}</span>
                        {/* 窄时先截断模型名（悬停可看全名）；状态多为短词（空闲、回答中…），完整显示，长的冷却说明再截断 */}
                        <span className='flex min-w-0 flex-1'>
                          <code title={t.upstream_model} className='min-w-0 truncate rounded-md bg-secondary px-1.5 py-0.5 text-xs'>{t.upstream_model}</code>
                        </span>
                        <span title={t.cooldown?.reason ?? t.note}
                          className={cn('max-w-[45%] shrink-0 truncate ps-1 text-end text-xs',
                            { fg: 'text-foreground', muted: 'text-muted-foreground', danger: 'text-destructive', warning: 'text-warning' }[st.tone])}>
                          {st.text}
                        </span>
                      </div>
                    )
                  })}
                </div>
              ))}
            </div>
          </div>

          {/* 计数 */}
          <div className='mt-6 flex items-end justify-end gap-8 border-t pt-4'>
            {([['请求', stats?.requests ?? 0], ['改道', stats?.reroutes ?? 0], ['客户端收到的错误', stats?.errors ?? 0]] as const).map(([l, v]) => (
              <div key={l}>
                <div className='num text-2xl leading-tight font-semibold'>{fmtInt(v)}</div>
                <div className='text-xs text-muted-foreground'>{l}</div>
              </div>
            ))}
            <span className='text-xs text-muted-foreground'>最近 5 分钟</span>
          </div>

          {/* 最近一个请求 */}
          <div className='mt-4 border-t pt-4'>
            <h3 className='mb-2 text-sm font-semibold'>最近一个请求是怎么路由的</h3>
            {lastHere ? <Narrative lines={lastHere.narrative} />
              : <p className='text-sm text-muted-foreground'>等待这条路由的下一个请求…（历史请求可在「请求日志」中查看路由决策）</p>}
          </div>
        </div>
      )}
    </>
  )
}
