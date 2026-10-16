import { useEffect, useRef, useState } from 'react'
import { ArrowUp, Eraser, ImagePlus, Square, X } from 'lucide-react'
import { toast } from 'sonner'
import { api, seg, type LogEntry, type Route, type RouteCaps } from '@/lib/api'
import { fmtTokens } from '@/lib/format'
import { useGet } from '@/lib/query'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Switch } from '@/components/ui/switch'
import { Textarea } from '@/components/ui/textarea'
import { Field } from '@/components/form-field'
import { Combobox, SimpleSelect } from '@/components/form-controls'
import { PageHeader } from '@/components/page'
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip'
import { AssistantTurn, CapsCard, QuestionsEditor } from './playground-parts'
import { AutoTextarea } from './chat-parts'
import {
  applyCaps, applyEvent, BUDGET, buildBody, curlFor, DECISION_SUGGESTIONS, FORMATS, forStorage, readImage, STORE,
  isChat, loadSaved, parseSync, questionsError, SUGGESTIONS,
  type Effort, type Format, type Meta, type Settings, type Turn,
} from './playground-model'

export function Playground() {
  const routes = useGet<Route[]>('/routes')
  const [saved] = useState(() => loadSaved())
  const [s, setS] = useState<Settings>(saved.settings)
  const [turns, setTurns] = useState<Turn[]>(saved.turns)
  const [input, setInput] = useState('')
  const [attachments, setAttachments] = useState<string[]>([])
  const [raw, setRaw] = useState<number | null>(null)
  const fileInput = useRef<HTMLInputElement>(null)
  const caps = useGet<RouteCaps>(s.route ? `/routes/${seg(s.route)}/capabilities` : null, { retry: false })
  // 已按能力填过参数的路由：页面加载时恢复的设置不覆盖，切换路由后填一次，之后可手动修改
  const filled = useRef(saved.settings.route)
  const abort = useRef<AbortController | null>(null)
  const scroller = useRef<HTMLDivElement>(null)
  const content = useRef<HTMLDivElement>(null)
  // 停在底部附近时跟随新内容（流式输出、Markdown 渲染后的高度变化）；往上翻看时不打扰
  const stick = useRef(true)
  const busy = turns.some((t) => t.pending)

  useEffect(() => {
    try {
      localStorage.setItem(STORE, JSON.stringify({ settings: s, turns: turns.filter((t) => !t.pending).map(forStorage) }))
    } catch { /* 本地存储不可用时不保存 */ }
  }, [s, turns])
  useEffect(() => {
    const el = scroller.current
    if (!el || !content.current) return
    const follow = () => { if (stick.current) el.scrollTop = el.scrollHeight }
    const ro = new ResizeObserver(follow)
    ro.observe(content.current)
    follow()
    return () => ro.disconnect()
  }, [])
  useEffect(() => {
    const c = caps.data
    if (!c || !s.route || filled.current === s.route) return
    filled.current = s.route
    setS((p) => applyCaps(p, c))
  }, [caps.data, s.route])

  const attach = async (files: Iterable<File>) => {
    const imgs = [...files].filter((f) => f.type.startsWith('image/'))
    if (!imgs.length) return
    try {
      const urls = await Promise.all(imgs.map(readImage))
      setAttachments((a) => [...a, ...urls].slice(0, 8))
    } catch {
      toast.error('图片读取失败')
    }
  }

  const set = <K extends keyof Settings>(k: K, v: Settings[K]) => setS((p) => ({ ...p, [k]: v }))
  const updateLast = (f: (t: Turn) => Turn) => setTurns((ts) => [...ts.slice(0, -1), f(ts[ts.length - 1])])

  const fetchLog = async (id: string) => {
    for (let i = 0; i < 8; i++) {
      await new Promise((r) => setTimeout(r, 250))
      try {
        const log = await api.get<LogEntry>(`/logs/${seg(id)}`)
        updateLast((t) => (t.meta ? { ...t, meta: { ...t.meta, log } } : t))
        return
      } catch { /* 日志异步写入，稍后重试 */ }
    }
  }

  const send = async () => {
    const text = input.trim()
    const atts = isChat(s.format) ? attachments : []
    if ((!text && !atts.length) || !s.route || busy) return
    const user: Turn = { role: 'user', text, attachments: atts.length ? atts : undefined }
    const history: Turn[] = [...turns.filter((t) => !t.error), user]
    const body = buildBody(s, history)
    const format = s.format
    setInput('')
    setAttachments([])
    stick.current = true
    setTurns([...turns, user, { role: 'assistant', text: '', pending: true, request: body, raw: '' }])
    const ctrl = new AbortController()
    abort.current = ctrl
    let id: string | null = null
    try {
      const res = await fetch(`/api/playground/${format}`, {
        method: 'POST', credentials: 'same-origin', signal: ctrl.signal,
        headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
      })
      id = res.headers.get('x-request-id')
      const target = res.headers.get('x-litegate-target')
      const meta: Meta = {
        id, target: target ? decodeURIComponent(target) : null,
        attempts: res.headers.get('x-litegate-attempts'), cacheHit: res.headers.get('x-litegate-cache') === 'hit',
      }
      const isSse = res.headers.get('content-type')?.includes('text/event-stream')
      if (res.ok && format === 'speech') {
        const blob = await res.blob()
        updateLast((t) => ({ ...t, meta, pending: false, audio: URL.createObjectURL(blob), raw: `[${blob.type}，${blob.size} 字节]` }))
      } else if (res.ok && format === 'systemone') {
        const txt = await res.text()
        const j = JSON.parse(txt)
        updateLast((t) => ({ ...t, meta, pending: false, decision: j.answers ?? {}, raw: txt.slice(0, 50000) }))
      } else if (res.ok && format === 'images') {
        const txt = await res.text()
        const j = JSON.parse(txt)
        const images = (j.data ?? []).map((d: { url?: string; b64_json?: string }) =>
          d.url ?? (d.b64_json ? `data:image/png;base64,${d.b64_json}` : '')).filter(Boolean)
        updateLast((t) => ({ ...t, meta, pending: false, images, raw: txt.slice(0, 5000) }))
      } else if (!res.ok || !isSse) {
        const txt = await res.text()
        let j: any = null
        try { j = JSON.parse(txt) } catch { /* 非 JSON 响应 */ }
        updateLast((t) => ({
          ...t, ...(res.ok ? parseSync(format, j) : {}), meta, raw: txt, pending: false,
          error: res.ok ? undefined : `${res.status} ${j?.error?.message ?? res.statusText}`,
        }))
      } else {
        updateLast((t) => ({ ...t, meta }))
        const reader = res.body!.getReader()
        const dec = new TextDecoder()
        let buf = ''
        for (;;) {
          const { done, value } = await reader.read()
          if (done) break
          const chunk = dec.decode(value, { stream: true })
          buf += chunk
          const blocks = buf.split('\n\n')
          buf = blocks.pop() ?? ''
          const events = blocks.map((b) => {
            let event: string | null = null
            const data: string[] = []
            for (const line of b.split('\n')) {
              if (line.startsWith('event:')) event = line.slice(6).trim()
              else if (line.startsWith('data:')) data.push(line.slice(5).trimStart())
            }
            return { event, data: data.join('\n') }
          }).filter((e) => e.data && e.data !== '[DONE]')
          updateLast((t) => {
            let n: Turn = { ...t, raw: (t.raw ?? '') + chunk }
            for (const e of events) {
              try { n = applyEvent(format, n, e.event, JSON.parse(e.data)) } catch { /* 跳过无法解析的事件 */ }
            }
            return n
          })
        }
        updateLast((t) => ({ ...t, pending: false }))
      }
    } catch (e) {
      const stopped = (e as Error).name === 'AbortError'
      updateLast((t) => ({ ...t, pending: false, error: stopped ? '已停止' : (e as Error).message }))
    } finally {
      abort.current = null
    }
    if (id) fetchLog(id)
  }

  const copyCurl = async (body: unknown) => {
    try {
      await navigator.clipboard.writeText(curlFor(s.format, body))
      toast.success('已复制（请把 $LITEGATE_API_KEY 换成网关 Key）')
    } catch {
      toast.error('复制失败')
    }
  }

  const routeNames = (routes.data ?? []).filter((r) => r.enabled).map((r) => r.name)
  const sum = caps.data?.summary
  const overLimit = !!sum?.output && Number(s.maxTokens) > sum.output
  const effortHint = sum?.reasoning === 'none' ? '该路由的模型不支持推理'
    : sum?.reasoning === 'some' ? '部分上游不支持推理，会忽略此参数'
    : s.format === 'messages' && s.effort ? `thinking 预算 ${BUDGET[s.effort]} token` : undefined
  const canAttach = isChat(s.format)
  const qErr = s.format === 'systemone' ? questionsError(s.questions) : undefined

  return (
    <>
      <PageHeader title='Playground' subtitle='以控制台身份走完整路由链路调试模型'
        actions={<Button variant='ghost' disabled={busy || turns.length === 0} onClick={() => { setTurns([]); setRaw(null) }}><Eraser /> 清空对话</Button>} />
      <div className='grid gap-4 lg:grid-cols-[280px_minmax(0,1fr)]'>
        <div className='grid h-fit gap-4 rounded-xl border bg-card p-4'>
          <Field label='模型（路由名）' required hint='通配路由请填完整模型名，如 openrouter/xxx'>
            <Combobox mono allowCustom value={s.route || null} onChange={(v) => set('route', v ?? '')} placeholder='选择或输入'
              options={routeNames.map((n) => ({ value: n, label: n }))} />
          </Field>
          {s.route && isChat(s.format) && <CapsCard caps={caps.data} loading={caps.isLoading} error={!!caps.error} />}
          <Field label='接口格式'>
            <SimpleSelect value={s.format} onChange={(v) => set('format', v as Format)}
              options={Object.entries(FORMATS).map(([k, f]) => ({ value: k, label: f.label }))} />
          </Field>
          {s.format === 'images' && (
            <div className='grid grid-cols-[1fr_72px] gap-2'>
              <Field label='尺寸'>
                <SimpleSelect value={s.size} onChange={(v) => set('size', v)}
                  options={['1024x1024', '1792x1024', '1024x1792', '1536x1024', '1024x1536'].map((x) => ({ value: x, label: x }))} />
              </Field>
              <Field label='张数'>
                <SimpleSelect value={s.n} onChange={(v) => set('n', v)} options={['1', '2', '3', '4'].map((x) => ({ value: x, label: x }))} />
              </Field>
            </div>
          )}
          {s.format === 'speech' && (
            <div className='grid grid-cols-[1fr_80px] gap-2'>
              <Field label='音色' hint='如 tongtong；留空用默认'><Input value={s.voice} onChange={(e) => set('voice', e.target.value)} /></Field>
              <Field label='格式'>
                <SimpleSelect value={s.audioFormat} onChange={(v) => set('audioFormat', v)} options={['mp3', 'wav', 'flac'].map((x) => ({ value: x, label: x }))} />
              </Field>
            </div>
          )}
          {s.format === 'systemone' && <QuestionsEditor value={s.questions} onChange={(v) => set('questions', v)} error={qErr} />}
          {isChat(s.format) && (
            <>
              <Field label='系统提示'><Textarea rows={3} value={s.system} onChange={(e) => set('system', e.target.value)} /></Field>
              <div className='grid grid-cols-2 gap-2'>
                <Field label='temperature' hint={sum?.locked_sampling ? '部分上游锁定采样，网关会去掉' : undefined}>
                  <Input value={s.temperature} placeholder='默认' onChange={(e) => set('temperature', e.target.value)} />
                </Field>
                <Field label='最大输出' error={overLimit ? `超过上限 ${fmtTokens(sum!.output!)}` : undefined}
                  hint={sum?.output ? `上限 ${fmtTokens(sum.output)}` : undefined}>
                  <Input value={s.maxTokens} onChange={(e) => set('maxTokens', e.target.value)} />
                </Field>
              </div>
              <Field label='推理强度' hint={effortHint}>
                <SimpleSelect value={s.effort} onChange={(v) => set('effort', v as Effort)} disabled={sum?.reasoning === 'none'}
                  options={[{ value: '', label: '不指定' }, { value: 'low', label: 'low' }, { value: 'medium', label: 'medium' }, { value: 'high', label: 'high' }]} />
              </Field>
              <label className='flex items-center gap-2 text-sm'><Switch checked={s.stream} onCheckedChange={(v) => set('stream', v)} /> 流式输出</label>
            </>
          )}
        </div>
        {/* 对话：消息区与输入框在同一张卡片里；内容限宽居中（参考 happy 的 AG-UI 对话） */}
        <div className='flex min-h-[480px] min-w-0 flex-col overflow-hidden rounded-xl border bg-card lg:h-[calc(100svh-180px)]'>
          <div ref={scroller} className='min-h-0 flex-1 overflow-y-auto px-4'
            onScroll={(e) => { const el = e.currentTarget; stick.current = el.scrollHeight - el.scrollTop - el.clientHeight < 80 }}>
            <div ref={content} className='flex min-h-full flex-col'>
            {turns.length === 0 ? (
              <div className='mx-auto flex max-w-3xl flex-1 flex-col items-center justify-center gap-4 py-12 text-center'>
                <p className='text-base leading-relaxed'>{s.route ? <>向 <span className='font-mono'>{s.route}</span> 发一条消息试试</> : '先在左侧选择模型（路由），再开始对话'}</p>
                <p className='text-xs text-muted-foreground'>
                  {s.format === 'systemone' ? '输入待判断的内容（state），决策模型按左侧问题表一次作答，返回每道题的结果与概率'
                    : '请求走完整的网关路由链路，回答下方会显示命中的上游、耗时、用量与路由决策'}
                </p>
                {s.route && (isChat(s.format) || s.format === 'systemone') && (
                  <div className='flex flex-wrap justify-center gap-2'>
                    {(s.format === 'systemone' ? DECISION_SUGGESTIONS : SUGGESTIONS).map((q) => (
                      <button key={q} type='button' onClick={() => setInput(q)}
                        className='rounded-full border bg-background px-3 py-1.5 text-sm hover:bg-muted'>{q}</button>
                    ))}
                  </div>
                )}
              </div>
            ) : (
              <div className='mx-auto flex w-full max-w-3xl flex-col gap-4 py-5'>
                {turns.map((t, i) => t.role === 'user' ? (
                  <div key={i} className='flex max-w-[85%] flex-col items-end gap-1.5 self-end'>
                    {!!t.attachments?.length && (
                      <div className='flex flex-wrap justify-end gap-1.5'>
                        {t.attachments.map((u, j) => <img key={j} src={u} alt={`图片 ${j + 1}`} className='h-24 max-w-40 rounded-lg border object-cover' />)}
                      </div>
                    )}
                    {!t.attachments?.length && !!t.attachmentCount && <span className='text-xs text-muted-foreground'>[{t.attachmentCount} 张图片，未保存在本地]</span>}
                    {t.text && (
                      <div className='rounded-[14px] rounded-br-[4px] border border-primary/20 bg-primary-soft px-3.5 py-2.5 text-sm leading-relaxed whitespace-pre-wrap break-words'>
                        {t.text}
                      </div>
                    )}
                  </div>
                ) : (
                  <AssistantTurn key={i} turn={t} showRaw={raw === i} onRaw={() => setRaw(raw === i ? null : i)} onCurl={() => copyCurl(t.request)} />
                ))}
              </div>
            )}
            </div>
          </div>
          {/* 输入：胶囊外框（焦点时边框变色），附图条在上方 */}
          <div className='shrink-0 px-4 pt-2 pb-3'>
            <div className='mx-auto max-w-3xl'>
              {canAttach && attachments.length > 0 && (
                <div className='mb-2 flex flex-wrap items-center gap-2'>
                  {attachments.map((u, i) => (
                    <div key={i} className='relative'>
                      <img src={u} alt={`待发送图片 ${i + 1}`} className='size-14 rounded-lg border object-cover' />
                      <button type='button' aria-label='移除图片' onClick={() => setAttachments((a) => a.filter((_, j) => j !== i))}
                        className='absolute -end-1.5 -top-1.5 rounded-full border bg-background p-0.5 text-muted-foreground hover:text-foreground'>
                        <X className='size-3' />
                      </button>
                    </div>
                  ))}
                  {sum?.images === 'none' && <span className='text-xs text-warning'>该路由的模型不支持图片输入</span>}
                  {sum?.images === 'some' && <span className='text-xs text-muted-foreground'>部分上游不支持图片，带图请求是否可用取决于路由规则</span>}
                </div>
              )}
              <div className='flex items-end gap-1 rounded-[26px] border bg-background px-2 py-1 shadow-sm transition-colors focus-within:border-ring'>
                {canAttach && (
                  <>
                    <input ref={fileInput} type='file' accept='image/*' multiple hidden
                      onChange={(e) => { if (e.target.files) attach(e.target.files); e.target.value = '' }} />
                    <Tooltip>
                      <TooltipTrigger asChild>
                        <button type='button' aria-label='添加图片' onClick={() => fileInput.current?.click()}
                          className='mb-0.5 flex size-[34px] shrink-0 items-center justify-center rounded-full text-muted-foreground hover:bg-muted hover:text-foreground'>
                          <ImagePlus className='size-[18px]' />
                        </button>
                      </TooltipTrigger>
                      <TooltipContent>添加图片（也可以直接粘贴）</TooltipContent>
                    </Tooltip>
                  </>
                )}
                <AutoTextarea value={input} onChange={setInput}
                  placeholder={!s.route ? '先选择模型' : busy ? '正在生成…' : s.format === 'systemone' ? '输入 state（待判断的内容，可以是 JSON 对象）…' : '输入消息…'}
                  onPaste={(e) => {
                    const files = [...e.clipboardData.files]
                    if (canAttach && files.some((f) => f.type.startsWith('image/'))) { e.preventDefault(); attach(files) }
                  }}
                  onKeyDown={(e) => {
                    // Enter 发送、Shift+Enter 换行；输入法组字时的 Enter 不发送
                    if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) { e.preventDefault(); send() }
                  }} />
                {busy ? (
                  <button type='button' aria-label='停止' onClick={() => abort.current?.abort()}
                    className='mb-0.5 flex size-[34px] shrink-0 items-center justify-center rounded-[10px] bg-destructive text-white active:translate-y-px'>
                    <Square className='size-4 fill-current' />
                  </button>
                ) : (
                  <button type='button' aria-label='发送' onClick={send}
                    disabled={(!input.trim() && !(canAttach && attachments.length)) || !s.route || !!qErr}
                    className='mb-0.5 flex size-[34px] shrink-0 items-center justify-center rounded-[10px] bg-primary text-primary-foreground active:translate-y-px disabled:opacity-40'>
                    <ArrowUp className='size-[18px]' />
                  </button>
                )}
              </div>
              <p className='mt-1.5 text-center text-[11px] text-muted-foreground'>Enter 发送 · Shift + Enter 换行{canAttach ? ' · 可直接粘贴图片' : ''} · 对话只保存在本浏览器</p>
            </div>
          </div>
        </div>
      </div>
    </>
  )
}
