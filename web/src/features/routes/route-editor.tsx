import { useEffect, useMemo, useState } from 'react'
import { Plus, X } from 'lucide-react'
import { toast } from 'sonner'
import { api, qs, seg, type Affinity, type ApiKey, type CatalogModel, type Credential, type Route, type RouteTarget, type Strategy, type IntentEngine, type DecisionStyle } from '@/lib/api'
import { emptyTarget, isWildcard, type Draft } from './route-editor-model'
import { AFFINITY_HELP, STRATEGY_HELP, STRATEGY_LABEL } from '@/lib/routing'
import { cn } from '@/lib/utils'
import { Button } from '@/components/ui/button'
import { Checkbox } from '@/components/ui/checkbox'
import { Input } from '@/components/ui/input'
import { Sheet, SheetContent, SheetDescription, SheetFooter, SheetHeader, SheetTitle } from '@/components/ui/sheet'
import { Switch } from '@/components/ui/switch'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { Field } from '@/components/form-field'
import { CheckRow, Combobox, SimpleSelect, TagInput } from '@/components/form-controls'
import { LimitInputs } from '@/components/limits'
import { limitDraft, limitValid, saveLimit, type LimitDraft } from '@/lib/limits'
import { Segmented } from '@/components/segmented'
import { VendorLogo } from '@/components/vendor-logo'
import { RulesEditor } from './rules-editor'
import { rangeOk, ruleDraft, ruleFromDraft, ruleValid, type RuleDraft } from './rules-model'

function Section({ title, desc, children }: { title: string; desc?: string; children: React.ReactNode }) {
  return (
    <section className='grid gap-3'>
      <div>
        <h3 className='text-sm font-semibold'>{title}</h3>
        {desc && <p className='mt-0.5 text-sm text-muted-foreground'>{desc}</p>}
      </div>
      {children}
    </section>
  )
}

/** 路由编辑：右侧宽抽屉，按目标 / 路由方式 / 规则 / 访问与限额 / 其他分页 */
export function RouteEditor({ route, initial, credentials, routes, keys, onClose, onSaved }: {
  route: Route | null
  initial: Draft
  credentials: Credential[]
  routes: Route[]
  keys: ApiKey[]
  onClose: () => void
  onSaved: () => void
}) {
  const o = route?.options
  const [d, setD] = useState<Draft>(initial)
  const [limit, setLimit] = useState(limitDraft(route?.limit))
  const [cacheTtl, setCacheTtl] = useState(o?.cache_ttl_s ? String(o.cache_ttl_s) : '')
  const [affinity, setAffinity] = useState<Affinity>(o?.affinity ?? 'auto')
  const [strategy, setStrategy] = useState<Strategy>(o?.strategy ?? 'weighted')
  const [rules, setRules] = useState<RuleDraft[]>((o?.rules ?? []).map(ruleDraft))
  const [classifier, setClassifier] = useState(o?.classifier ?? '')
  const [engine, setEngine] = useState<IntentEngine>(o?.intent_engine ?? 'llm')
  const [decisionRoute, setDecisionRoute] = useState(o?.decision_route ?? '')
  const [decisionStyle, setDecisionStyle] = useState<DecisionStyle>(o?.decision_style ?? 'choice')
  const [loopGuard, setLoopGuard] = useState(o?.loop_guard !== false)
  const [redact, setRedact] = useState(o?.redact === true)
  // 按 Key 例外限额：Key×路由
  const [keyLimits, setKeyLimits] = useState<{ key_id: string; draft: LimitDraft }[]>(
    (route?.key_limits ?? []).map((l) => ({ key_id: l.key_id, draft: limitDraft(l) })))
  const [busy, setBusy] = useState(false)
  const [tab, setTab] = useState('targets')
  // 按供应商缓存目录模型，用于上游模型补全与计费匹配
  const [catalog, setCatalog] = useState<Record<string, CatalogModel[]>>({})

  const providers = useMemo(() => [...new Set(d.targets
    .map((t) => credentials.find((c) => c.id === t.credential)?.provider)
    .filter((p): p is string => !!p))], [d.targets, credentials])

  useEffect(() => {
    for (const p of providers) {
      if (catalog[p]) continue
      api.get<{ items: CatalogModel[] }>(`/catalog/models${qs({ provider: p, limit: 500 })}`)
        .then((r) => setCatalog((c) => ({ ...c, [p]: r.items })))
        .catch(() => setCatalog((c) => ({ ...c, [p]: [] })))
    }
  }, [providers, catalog])

  // 可嵌套的路由：非通配、不是自己
  const nestable = routes.map((r) => r.name).filter((n) => n !== d.name && !isWildcard(n))
  // 规则「先发给路由」的目标不能是自己：后端 guard 下自引用静默 no-op（R5）
  const otherRoutes = routes.map((r) => r.name).filter((n) => n !== d.name)
  // 意图判断模型只能选启用的路由：后端保存时校验（R8），前端直接过滤给即时反馈
  const classifierRoutes = routes.filter((r) => r.enabled && r.name !== d.name).map((r) => r.name)
  const setTarget = (i: number, patch: Partial<RouteTarget>) =>
    setD({ ...d, targets: d.targets.map((t, j) => (j === i ? { ...t, ...patch } : t)) })

  // 计费参考：凭证关联了目录供应商时按 [供应商, 上游模型] 匹配
  const refFor = (t: RouteTarget): [string, string] | null => {
    if (t.route || t.upstream_model === '*') return null // 通配目标的计费参考由网关按请求模型名计算
    const p = credentials.find((c) => c.id === t.credential)?.provider
    if (p && catalog[p]?.some((m) => m.id === t.upstream_model)) return [p, t.upstream_model]
    return p ? null : t.model_ref
  }

  const targetsOk = d.targets.length > 0
    && d.targets.every((t) => (t.route ? t.route !== d.name : t.credential && t.upstream_model.trim()))
    && (isWildcard(d.name) || d.targets.every((t) => t.route || t.upstream_model.trim() !== '*'))
  const hasIntent = rules.some((r) => r.intent.trim())
  const judgeOk = engine === 'laya' || (engine === 'systemone' ? decisionRoute !== '' : classifier !== '')
  const rulesOk = rules.every((r) => ruleValid(r) && rangeOk(r)) && (!hasIntent || judgeOk)
  const limitsOk = limitValid(limit) && keyLimits.every((k) => k.key_id && limitValid(k.draft))
    && new Set(keyLimits.map((k) => k.key_id)).size === keyLimits.length
  const ttlOk = cacheTtl.trim() === '' || (Number.isInteger(Number(cacheTtl)) && Number(cacheTtl) >= 0)
  const nameOk = d.name.trim() !== '' && !/\s/.test(d.name) && (!d.name.includes('*') || isWildcard(d.name))
  const valid = nameOk && targetsOk && rulesOk && limitsOk && ttlOk

  const save = async () => {
    setBusy(true)
    const body = {
      ...d,
      name: d.name.trim(),
      targets: d.targets.map((t) => (t.route
        ? { route: t.route, priority: t.priority, weight: t.weight, enabled: t.enabled }
        : { ...t, route: undefined, upstream_model: t.upstream_model.trim(), model_ref: refFor(t) })),
      options: {
        cache_ttl_s: cacheTtl.trim() === '' || Number(cacheTtl) === 0 ? null : Number(cacheTtl),
        affinity: affinity === 'auto' ? null : affinity,
        strategy: strategy === 'weighted' ? null : strategy,
        rules: rules.length ? rules.map(ruleFromDraft) : null,
        classifier: hasIntent && classifier ? classifier : null,
        intent_engine: hasIntent && engine !== 'llm' ? engine : null,
        decision_route: hasIntent && engine === 'systemone' && decisionRoute ? decisionRoute : null,
        decision_style: hasIntent && engine === 'systemone' ? decisionStyle : null,
        loop_guard: loopGuard ? null : false,
        redact: redact || null,
      },
    }
    try {
      if (route) await api.put(`/routes/${seg(route.name)}`, body)
      else await api.post('/routes', body)
      await saveLimit({ type: 'route', route: body.name }, limit)
      const kept = new Set(keyLimits.map((k) => k.key_id))
      for (const k of keyLimits) await saveLimit({ type: 'key_route', key_id: k.key_id, route: body.name }, k.draft)
      // 移除的例外：三项置空即删除
      for (const old of route?.key_limits ?? []) {
        if (!kept.has(old.key_id)) await saveLimit({ type: 'key_route', key_id: old.key_id, route: body.name }, limitDraft(null))
      }
      toast.success('已保存')
      onSaved()
      onClose()
    } catch (e) {
      toast.error((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  const bad = (ok: boolean) => (!ok ? <span className='ms-1 size-1.5 rounded-full bg-destructive' /> : null)

  return (
    <Sheet open onOpenChange={(v) => !v && onClose()}>
      <SheetContent className='w-full gap-0 sm:w-2/3 sm:max-w-none'>
        <SheetHeader className='border-b'>
          <SheetTitle>{route ? `编辑路由：${route.name}` : '新建路由'}</SheetTitle>
          <SheetDescription>路由名就是客户端请求里的 model；目标是实际转发到的上游</SheetDescription>
        </SheetHeader>
        <div className='flex-1 overflow-y-auto px-4 py-4'>
          <div className='mb-4 grid gap-3 sm:grid-cols-[1fr_auto] sm:items-end'>
            <Field label='路由名（对外模型名）' required
              hint='不能含空白，可含 /。以 * 结尾为通配路由（如 openrouter/*、claude-*），单独的 * 为兜底路由'>
              <Input className='font-mono' value={d.name} disabled={route !== null} aria-invalid={d.name !== '' && !nameOk}
                onChange={(e) => setD({ ...d, name: e.target.value })} />
            </Field>
            <label className='flex items-center gap-2 pb-6 text-sm'>
              <Switch checked={d.enabled} onCheckedChange={(v) => setD({ ...d, enabled: v })} /> 启用
            </label>
          </div>
          <Tabs value={tab} onValueChange={setTab}>
            <TabsList className='mb-4 flex-wrap'>
              <TabsTrigger value='targets'>上游目标{bad(targetsOk)}</TabsTrigger>
              <TabsTrigger value='strategy'>路由方式</TabsTrigger>
              <TabsTrigger value='rules'>规则{rules.length > 0 && ` ${rules.length}`}{bad(rulesOk)}</TabsTrigger>
              <TabsTrigger value='access'>访问与限额{bad(limitsOk)}</TabsTrigger>
              <TabsTrigger value='more'>其他{bad(ttlOk)}</TabsTrigger>
            </TabsList>

            <TabsContent value='targets' className='grid gap-3'>
              <p className='text-sm text-muted-foreground'>
                优先级数字小的先尝试；同优先级按「路由方式」排序。失败（429 / 5xx / 超时 / 鉴权错误）时自动换下一个目标。
              </p>
              {d.targets.map((t, i) => {
                const cred = credentials.find((c) => c.id === t.credential)
                const models = cred?.provider ? catalog[cred.provider] ?? [] : []
                const ref = refFor(t)
                const nested = t.route !== undefined
                return (
                  <div key={i} className={cn('rounded-lg border bg-card p-3', !t.enabled && 'opacity-60')}>
                    <div className='flex flex-wrap items-end gap-2'>
                      <Segmented size='sm' value={nested ? 'route' : 'cred'} className='mb-0.5'
                        onChange={(v) => setTarget(i, v === 'route' ? { route: nestable[0] ?? '' } : { route: undefined })}
                        options={[{ value: 'cred', label: '凭证' }, ...(nestable.length ? [{ value: 'route', label: '路由' }] : [])]} />
                      {nested ? (
                        <Field label='嵌套路由' className='min-w-48 flex-1'>
                          <SimpleSelect value={t.route ?? ''} onChange={(v) => setTarget(i, { route: v })}
                            options={nestable.map((n) => ({ value: n, label: n }))} placeholder='选择路由' />
                        </Field>
                      ) : (
                        <>
                          <Field label='凭证' className='min-w-40 flex-1'>
                            <SimpleSelect value={t.credential} onChange={(v) => setTarget(i, { credential: v })}
                              options={credentials.map((c) => ({ value: c.id, label: (
                                <span className='flex items-center gap-1.5'>
                                  <VendorLogo hints={[c.provider, c.base_url, c.name]} />{c.name}{c.enabled ? '' : '（已停用）'}
                                </span>
                              ) }))} />
                          </Field>
                          <Field label='上游模型' className='min-w-48 flex-[1.4]'>
                            <Combobox mono allowCustom value={t.upstream_model || null} onChange={(v) => setTarget(i, { upstream_model: v ?? '' })}
                              placeholder='选择或输入模型名' searchPlaceholder='搜索或输入…'
                              options={models.map((m) => ({ value: m.id, label: m.id, keywords: m.name, hint: m.name !== m.id ? m.name : undefined }))} />
                          </Field>
                        </>
                      )}
                      <Field label='优先级' className='w-20'>
                        <Input type='number' min={0} value={t.priority} onChange={(e) => setTarget(i, { priority: Math.max(0, Number(e.target.value)) })} />
                      </Field>
                      <Field label='权重' className='w-20'>
                        <Input type='number' min={1} value={t.weight} onChange={(e) => setTarget(i, { weight: Math.max(1, Number(e.target.value)) })} />
                      </Field>
                      <div className='flex h-9 items-center gap-1'>
                        <Checkbox checked={t.enabled} onCheckedChange={(v) => setTarget(i, { enabled: v === true })} aria-label='启用' title='启用' />
                        <Button variant='ghost' size='icon' className='size-8' disabled={d.targets.length === 1} aria-label='删除目标'
                          onClick={() => setD({ ...d, targets: d.targets.filter((_, j) => j !== i) })}><X /></Button>
                      </div>
                    </div>
                    {nested ? (
                      <p className='mt-2 text-xs text-muted-foreground'>按该路由自己的策略、规则与回退展开，以它的第一个候选参与本路由的排序</p>
                    ) : t.upstream_model === '*' ? (
                      <p className={cn('mt-2 text-xs', isWildcard(d.name) ? 'text-muted-foreground' : 'text-destructive')}>
                        {isWildcard(d.name)
                          ? `上游模型取请求模型名去掉前缀「${d.name.slice(0, -1)}」后的部分；${cred?.provider ? `按目录供应商 ${cred.provider} 的同名模型计费` : '凭证未关联目录供应商，不计费'}`
                          : '* 只能用于通配路由（路由名以 * 结尾）'}
                      </p>
                    ) : t.upstream_model && (
                      <p className={cn('mt-2 text-xs', ref ? 'text-muted-foreground' : 'text-warning')}>
                        {ref ? `按目录模型 ${ref[0]}/${ref[1]} 计费` : '目录中没有匹配的模型，费用记为 0（可在模型目录中添加自定义模型）'}
                      </p>
                    )}
                  </div>
                )
              })}
              <div>
                <Button variant='outline' size='sm' onClick={() => setD({ ...d, targets: [...d.targets, emptyTarget(credentials[0]?.id)] })}>
                  <Plus /> 添加目标
                </Button>
              </div>
              <Field label='回退路由' hint='本路由的目标全部失败后按顺序尝试'>
                <TagInput freeSolo={false} mono value={d.fallbacks} onChange={(v) => setD({ ...d, fallbacks: v })} placeholder='不回退'
                  options={otherRoutes.map((n) => ({ value: n, label: n }))} />
              </Field>
            </TabsContent>

            <TabsContent value='strategy' className='grid gap-6'>
              <Section title='同优先级内的顺序'>
                <SimpleSelect className='max-w-xs' value={strategy} onChange={(v) => setStrategy(v as Strategy)}
                  options={Object.entries(STRATEGY_LABEL).map(([k, v]) => ({ value: k, label: v }))} />
                <p className='text-sm text-muted-foreground'>{STRATEGY_HELP[strategy]}</p>
              </Section>
              <Section title='会话粘性'>
                <Segmented value={affinity} onChange={(v) => setAffinity(v as Affinity)}
                  options={[{ value: 'auto', label: '自动' }, { value: 'session', label: '整个会话' }, { value: 'off', label: '关闭' }]} />
                <p className='text-sm text-muted-foreground'>{AFFINITY_HELP[affinity]}</p>
              </Section>
              <Section title='保护'>
                <CheckRow checked={redact} onChange={setRedact} label='敏感信息脱敏'
                  hint='密钥类内容换成占位符再发往上游，回复中还原（规则见运行参数 redact_rules / redact_pii）' />
                <CheckRow checked={loopGuard} onChange={setLoopGuard} label='流式复读检测' hint='模型陷入重复输出时提前结束' />
              </Section>
            </TabsContent>

            <TabsContent value='rules'>
              <RulesEditor rules={rules} onChange={setRules} credentials={credentials} routes={otherRoutes}
                classifierRoutes={classifierRoutes} classifier={classifier} onClassifier={setClassifier}
                engine={engine} onEngine={setEngine}
                decisionRoute={decisionRoute} onDecisionRoute={setDecisionRoute}
                decisionStyle={decisionStyle} onDecisionStyle={setDecisionStyle} />
            </TabsContent>

            <TabsContent value='access' className='grid gap-6'>
              <Section title='可调用的 API Key'>
                <Segmented value={d.access === 'all' ? 'all' : 'some'} onChange={(v) => setD({ ...d, access: v === 'all' ? 'all' : [] })}
                  options={[{ value: 'all', label: '所有 Key' }, { value: 'some', label: '指定 Key' }]} />
                {d.access !== 'all' && (
                  <TagInput freeSolo={false} value={d.access} onChange={(v) => setD({ ...d, access: v })} placeholder='选择 Key'
                    options={keys.map((k) => ({ value: k.id, label: k.name, hint: `${k.prefix}…` }))} />
                )}
              </Section>
              <Section title='路由限额' desc='所有 Key 调用该路由的总量上限，用于保护上游额度；按 Key 例外对单个 Key 另设上限（同时受路由总额约束）'>
                <LimitInputs value={limit} onChange={setLimit} />
                {keyLimits.map((k, i) => (
                  <div key={i} className='grid gap-3 rounded-lg border bg-card p-3'>
                    <div className='flex items-center gap-2'>
                      <SimpleSelect className='flex-1' value={k.key_id} placeholder='选择 Key'
                        onChange={(v) => setKeyLimits(keyLimits.map((x, j) => (j === i ? { ...x, key_id: v } : x)))}
                        options={keys.map((key) => ({ value: key.id, label: `${key.name}（${key.prefix}…）` }))} />
                      <Button variant='ghost' size='icon' className='size-8' aria-label='删除例外'
                        onClick={() => setKeyLimits(keyLimits.filter((_, j) => j !== i))}><X /></Button>
                    </div>
                    <LimitInputs value={k.draft} onChange={(v) => setKeyLimits(keyLimits.map((x, j) => (j === i ? { ...x, draft: v } : x)))} />
                  </div>
                ))}
                <div>
                  <Button variant='outline' size='sm' disabled={keys.length === 0}
                    onClick={() => setKeyLimits([...keyLimits, { key_id: '', draft: limitDraft(null) }])}><Plus /> 按 Key 例外</Button>
                </div>
              </Section>
            </TabsContent>

            <TabsContent value='more' className='grid gap-6'>
              <Section title='别名' desc='也路由到这里的精确模型名，如 Claude Code 默认请求的 claude-sonnet-4-5'>
                <TagInput mono value={d.aliases} onChange={(v) => setD({ ...d, aliases: v })} />
              </Section>
              <Section title='响应缓存' desc='相同的非流式请求直接返回缓存结果（不访问上游、不计费）；客户端可用 cache-control: no-cache 跳过'>
                <Field label='缓存有效期（秒）' className='max-w-48'>
                  <Input type='number' min={0} placeholder='关闭' value={cacheTtl} aria-invalid={!ttlOk} onChange={(e) => setCacheTtl(e.target.value)} />
                </Field>
              </Section>
            </TabsContent>
          </Tabs>
        </div>
        <SheetFooter className='flex-row justify-end border-t'>
          <Button variant='outline' onClick={onClose}>取消</Button>
          <Button onClick={save} disabled={busy || !valid}>保存</Button>
        </SheetFooter>
      </SheetContent>
    </Sheet>
  )
}
