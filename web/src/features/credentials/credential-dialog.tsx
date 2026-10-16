import { type ReactNode, useState } from 'react'
import { toast } from 'sonner'
import { api, BALANCE_KINDS, seg, type BalanceKind, type CatalogProvider, type Credential, type PlanKind } from '@/lib/api'
import { useGet } from '@/lib/query'
import { Button } from '@/components/ui/button'
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Tabs, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { Textarea } from '@/components/ui/textarea'
import { Field } from '@/components/form-field'
import { CheckRow, Combobox, JsonTextarea, SimpleSelect } from '@/components/form-controls'
import { parseJsonObject } from '@/lib/json'
import { PLAN_KINDS } from '@/lib/quota'

// headers 文本（每行 Name: value）↔ 对象
const headersToText = (h: Record<string, string>) => Object.entries(h).map(([k, v]) => `${k}: ${v}`).join('\n')
function textToHeaders(t: string) {
  const out: Record<string, string> = {}
  for (const line of t.split('\n')) {
    const i = line.indexOf(':')
    if (i > 0) out[line.slice(0, i).trim()] = line.slice(i + 1).trim()
  }
  return out
}

function Group({ title, children }: { title: string; children: ReactNode }) {
  return (
    <fieldset className='grid gap-3 border-t pt-4'>
      <legend className='-ms-0.5 pe-2 text-xs font-semibold tracking-wide text-muted-foreground'>{title}</legend>
      {children}
    </fieldset>
  )
}

export function CredentialDialog({ credential, onClose, onSaved }: {
  credential: Credential | null
  onClose: () => void
  onSaved: () => void
}) {
  const isNew = credential === null
  const opts = credential?.options
  const [mode, setMode] = useState<'provider' | 'manual'>(isNew ? 'provider' : 'manual')
  const providers = useGet<CatalogProvider[]>('/catalog/providers')
  const [provider, setProvider] = useState<string | null>(null)
  const [pricingProvider, setPricingProvider] = useState<string | null>(credential?.provider ?? null)
  const [name, setName] = useState(credential?.name ?? '')
  const [protocol, setProtocol] = useState<'openai' | 'anthropic'>(credential?.protocol ?? 'openai')
  const [baseUrl, setBaseUrl] = useState(credential?.base_url ?? '')
  const [apiKey, setApiKey] = useState('')
  const [headers, setHeaders] = useState(headersToText(credential?.headers ?? {}))
  const [responsesApi, setResponsesApi] = useState(opts?.responses_api === true)
  const [responsesBase, setResponsesBase] = useState(opts?.responses_base_url ?? '')
  const [thinkSplit, setThinkSplit] = useState(opts?.think_tags === 'split')
  const [promptCache, setPromptCache] = useState(opts?.prompt_cache === 'auto')
  const [mediaApi, setMediaApi] = useState<'openai' | 'minimax'>(opts?.media_api ?? 'openai')
  const [extraBody, setExtraBody] = useState(opts?.extra_body ? JSON.stringify(opts.extra_body, null, 2) : '')
  const [planKind, setPlanKind] = useState<PlanKind | ''>(opts?.plan?.kind ?? '')
  const [reservePct, setReservePct] = useState(String(opts?.plan?.reserve_pct ?? 0))
  const [windowCaps, setWindowCaps] = useState(Object.entries(opts?.plan?.window_caps ?? {}).map(([k, v]) => `${k}=${v}`).join(', '))
  const [maxConc, setMaxConc] = useState(String(opts?.max_concurrency ?? ''))
  const [balanceKind, setBalanceKind] = useState<BalanceKind | ''>(opts?.balance?.kind ?? '')
  const [alertBelow, setAlertBelow] = useState(opts?.balance?.alert_below?.toString() ?? '')
  const [busy, setBusy] = useState(false)

  const extra = parseJsonObject(extraBody)
  const caps = (() => {
    const out: Record<string, number> = {}
    for (const part of windowCaps.split(/[,，\s]+/).filter(Boolean)) {
      const m = part.match(/^([^=]+)=(\d+)$/)
      if (!m || Number(m[2]) > 100) return null
      out[m[1]] = Number(m[2])
    }
    return out
  })()
  const all = providers.data ?? []
  const usable = all.filter((p) => p.protocol && p.api)
  const picked = usable.find((p) => p.id === provider)
  const providerOptions = (list: CatalogProvider[]) =>
    list.map((p) => ({ value: p.id, label: p.name && p.name !== p.id ? `${p.name}（${p.id}）` : p.id, keywords: p.name, hint: p.api ?? undefined }))

  const save = async () => {
    setBusy(true)
    try {
      if (mode === 'provider' && isNew) {
        await api.post('/credentials/from-provider', { provider, api_key: apiKey || undefined, name: name || undefined })
      } else {
        const body: Record<string, unknown> = {
          name, protocol, base_url: baseUrl.trim(), headers: textToHeaders(headers), provider: pricingProvider,
          options: {
            responses_api: protocol === 'openai' && responsesApi ? true : null,
            plan: planKind ? {
              kind: planKind, reserve_pct: Number(reservePct) || 0,
              ...(caps && Object.keys(caps).length ? { window_caps: caps } : {}),
            } : null,
            think_tags: protocol === 'openai' && thinkSplit ? 'split' : null,
            prompt_cache: protocol === 'anthropic' && promptCache ? 'auto' : null,
            media_api: protocol === 'openai' && mediaApi === 'minimax' ? 'minimax' : null,
            extra_body: extra.value,
            max_concurrency: Number(maxConc) > 0 ? Math.floor(Number(maxConc)) : null,
            balance: balanceKind ? { kind: balanceKind, ...(alertBelow.trim() ? { alert_below: Number(alertBelow) } : {}) } : null,
            responses_base_url: protocol === 'openai' && responsesApi && responsesBase.trim() ? responsesBase.trim() : null,
          },
        }
        if (apiKey) body.api_key = apiKey
        if (isNew) await api.post('/credentials', body)
        else await api.put(`/credentials/${seg(credential.id)}`, body)
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

  const valid = mode === 'provider' && isNew ? provider !== null : name.trim() !== '' && baseUrl.trim() !== '' && extra.ok && caps !== null

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className='max-h-[90svh] gap-5 overflow-y-auto sm:max-w-2xl'>
        <DialogHeader>
          <DialogTitle>{isNew ? '添加凭证' : `编辑凭证：${credential.name}`}</DialogTitle>
        </DialogHeader>
        {isNew && (
          <Tabs value={mode} onValueChange={(v) => setMode(v as 'provider' | 'manual')}>
            <TabsList>
              <TabsTrigger value='provider'>从模型目录选择</TabsTrigger>
              <TabsTrigger value='manual'>手动填写</TabsTrigger>
            </TabsList>
          </Tabs>
        )}
        {mode === 'provider' && isNew ? (
          <div className='grid gap-4'>
            <Field label='供应商' hint={picked ? `${picked.protocol} · ${picked.api}` : '只列出协议可自动识别的供应商；其他请手动填写'}>
              <Combobox value={provider} onChange={setProvider} options={providerOptions(usable)} placeholder='选择供应商' />
            </Field>
            <Field label='名称（可选）'>
              <Input value={name} onChange={(e) => setName(e.target.value)} placeholder={provider ?? ''} />
            </Field>
            <Field label='API Key' hint='加密存储，之后只显示末 4 位'>
              <Input type='password' autoComplete='off' value={apiKey} onChange={(e) => setApiKey(e.target.value)} />
            </Field>
          </div>
        ) : (
          <div className='grid gap-5'>
            <div className='grid gap-4 sm:grid-cols-2'>
              <Field label='名称' required>
                <Input value={name} onChange={(e) => setName(e.target.value)} />
              </Field>
              <Field label='协议'>
                <SimpleSelect value={protocol} onChange={(v) => setProtocol(v as 'openai' | 'anthropic')} options={[
                  { value: 'openai', label: 'OpenAI 兼容（/chat/completions）' },
                  { value: 'anthropic', label: 'Anthropic（/v1/messages）' },
                ]} />
              </Field>
              <Field label='Base URL' required className='sm:col-span-2'>
                <Input className='font-mono text-[13px]' value={baseUrl} onChange={(e) => setBaseUrl(e.target.value)}
                  placeholder={protocol === 'openai' ? 'https://api.openai.com/v1' : 'https://api.anthropic.com'} />
              </Field>
              <Field label='API Key' className='sm:col-span-2'
                hint={isNew ? '加密存储，之后只显示末 4 位' : `当前：${credential.api_key_hint ?? '无'}；留空保持不变`}>
                <Input type='password' autoComplete='off' value={apiKey} onChange={(e) => setApiKey(e.target.value)} />
              </Field>
              <Field label='目录供应商（用于计费）' hint='按「目录供应商 / 上游模型」在模型目录中查找价格；留空则不计费' className='sm:col-span-2'>
                <Combobox value={pricingProvider} onChange={setPricingProvider} options={providerOptions(all)} placeholder='不计费' clearable />
              </Field>
            </div>

            <Group title='协议能力'>
              {protocol === 'openai' && (
                <>
                  <CheckRow checked={responsesApi} onChange={setResponsesApi}
                    label='上游原生支持 Responses API' hint='/v1/responses 直接透传；否则转换为 Chat Completions' />
                  {responsesApi && (
                    <Field label='Responses 基址（可选）' hint='与上面的地址不同时填写，如智谱 Chat 在 /api/paas/v4、Responses 在 /api/v1'>
                      <Input className='font-mono text-[13px]' value={responsesBase} placeholder={baseUrl} onChange={(e) => setResponsesBase(e.target.value)} />
                    </Field>
                  )}
                  <CheckRow checked={thinkSplit} onChange={setThinkSplit} label='拆分 content 中的 <think>…</think> 为思考内容' hint='如 MiniMax 的 OpenAI 接口' />
                  <Field label='图片 / 语音接口格式' hint='用于 /v1/images/generations 与 /v1/audio/speech'>
                    <SimpleSelect value={mediaApi} onChange={(v) => setMediaApi(v as 'openai' | 'minimax')} options={[
                      { value: 'openai', label: 'OpenAI 兼容（/images/generations、/audio/speech）' },
                      { value: 'minimax', label: 'MiniMax（/image_generation、/t2a_v2）' },
                    ]} />
                  </Field>
                </>
              )}
              {protocol === 'anthropic' && (
                <CheckRow checked={promptCache} onChange={setPromptCache} label='自动提示缓存'
                  hint='客户端未设置 cache_control 时，给系统提示、工具定义与最后一条用户消息加缓存标记' />
              )}
            </Group>

            <Group title='计费与额度'>
              <div className='grid gap-4 sm:grid-cols-3'>
                <Field label='订阅套餐' className='sm:col-span-2' hint='套餐凭证会定期查询剩余额度，路由据此避让'>
                  <SimpleSelect value={planKind} onChange={(v) => setPlanKind(v as PlanKind | '')}
                    options={[{ value: '', label: '无（按量计费）' }, ...Object.entries(PLAN_KINDS).map(([k, l]) => ({ value: k, label: l }))]} />
                </Field>
                {planKind && (
                  <Field label='保留比例 %' hint='剩余低于此比例时排到其他目标之后'>
                    <Input type='number' min={0} max={100} value={reservePct} onChange={(e) => setReservePct(e.target.value)} />
                  </Field>
                )}
                {planKind && (
                  <Field label='窗口使用上限' className='sm:col-span-3'
                    error={caps === null ? '格式：窗口名=百分比，逗号分隔' : undefined}
                    hint='按窗口设已用比例上限，超过即排到其他目标之后；窗口名见凭证列表的额度条（如 5h、week）'>
                    <Input value={windowCaps} placeholder='5h=50, week=40' onChange={(e) => setWindowCaps(e.target.value)} aria-invalid={caps === null} />
                  </Field>
                )}
                <Field label='余额查询' className='sm:col-span-2'
                  hint={balanceKind ? '定期查询余额，显示在用量页；余额为 0 时暂停使用该凭证'
                    : credential?.balance_suggest ? `建议：${BALANCE_KINDS[credential.balance_suggest]}` : '按量付费 Key 可查询余额'}>
                  <SimpleSelect value={balanceKind} onChange={(v) => setBalanceKind(v as BalanceKind | '')}
                    options={[{ value: '', label: '不查询' }, ...Object.entries(BALANCE_KINDS).map(([k, l]) => ({ value: k, label: l }))]} />
                </Field>
                {balanceKind && (
                  <Field label='告警线' hint='低于此金额时告警'>
                    <Input type='number' min={0} value={alertBelow} onChange={(e) => setAlertBelow(e.target.value)} />
                  </Field>
                )}
              </div>
            </Group>

            <Group title='高级'>
              <Field label='并发上限' hint='同时发往这个凭证的请求数上限（所有模型合计），留空或 0 为不限；满了时先换其他目标，没有其他目标时排队'>
                <Input type='number' min={0} className='w-40' value={maxConc} onChange={(e) => setMaxConc(e.target.value)} />
              </Field>
              <Field label='附加请求体（JSON）' error={extra.ok ? undefined : '必须是 JSON 对象'}
                hint='合并进每个发往上游的请求体，如 {"reasoning_split": true}；不能覆盖 model、messages、stream'>
                <JsonTextarea rows={3} value={extraBody} onChange={setExtraBody} invalid={!extra.ok} />
              </Field>
              <Field label='额外请求头' hint='每行一个，格式 Name: value'>
                <Textarea rows={2} className='font-mono text-[13px]' value={headers} onChange={(e) => setHeaders(e.target.value)} />
              </Field>
            </Group>
          </div>
        )}
        <DialogFooter>
          <Button variant='outline' onClick={onClose}>取消</Button>
          <Button onClick={save} disabled={busy || !valid}>保存</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
