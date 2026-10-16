import type { LogEntry, RouteCaps } from '@/lib/api'

type Format = 'chat' | 'messages' | 'responses' | 'images' | 'speech' | 'systemone'

const FORMATS: Record<Format, { label: string; gateway: string }> = {
  chat: { label: 'OpenAI Chat Completions', gateway: '/v1/chat/completions' },
  messages: { label: 'Anthropic Messages', gateway: '/v1/messages' },
  responses: { label: 'OpenAI Responses', gateway: '/v1/responses' },
  images: { label: '图片生成', gateway: '/v1/images/generations' },
  speech: { label: '语音合成', gateway: '/v1/audio/speech' },
  systemone: { label: '决策模型（System One）', gateway: '/v1/systemone' },
}

const isMedia = (f: Format) => f === 'images' || f === 'speech'
// 对话类接口：带历史、系统提示与采样参数；图片 / 语音 / 决策只用本次输入
const isChat = (f: Format) => !isMedia(f) && f !== 'systemone'

// 空对话时的示例问题（点击填入输入框）
const SUGGESTIONS = ['用三句话介绍一下你自己', '写一个 Python 快速排序并解释', '比较 TCP 和 UDP 的区别', '把「你好，世界」翻译成英文和日文']
// 决策模型的示例 state（配合默认问题表）
const DECISION_SUGGESTIONS = ['订单支付后超过 24 小时仍未到账', '接入 SDK 后调用接口一直返回 500', '想了解一下企业版的价格']

// 决策模型（System One）的问题：choice 单选（criteria 每行「key: 说明」）、noul 是非、score 有序打分（criteria 每行一个等级，从低到高）
type QuestionType = 'choice' | 'noul' | 'score'
interface Question { id: string; type: QuestionType; instructions: string; criteria: string }
const QUESTION_TYPES: Record<QuestionType, string> = { choice: '单选', noul: '是非', score: '打分' }
const DEFAULT_QUESTIONS: Question[] = [
  { id: 'department', type: 'choice', instructions: '应该由哪个团队处理？',
    criteria: 'billing: 支付、退款和账单问题\ntechnical: 产品故障和集成问题\nsales: 购买、报价与合作咨询' },
  { id: 'escalate', type: 'noul', instructions: '是否需要立即通知值班人员？', criteria: '' },
  { id: 'severity', type: 'score', instructions: '这个问题有多严重？', criteria: '轻微问题\n部分功能受影响\n核心功能不可用\n严重业务影响' },
]

// 决策模型的回答（/v1/systemone 响应 answers 里的一项）
interface Answer {
  type: string
  choice?: string
  noul?: number
  score?: number
  confidence?: number
  probabilities?: Record<string, number>
  legend?: Record<string, string>  // score：等级序号 → 等级说明
}

// Anthropic thinking 预算
const BUDGET = { low: 1024, medium: 4096, high: 16384 } as const
type Effort = '' | keyof typeof BUDGET

interface Settings {
  route: string
  format: Format
  system: string
  temperature: string
  maxTokens: string
  effort: Effort
  stream: boolean
  size: string
  n: string
  voice: string
  audioFormat: string
  questions: Question[]
}

interface ToolCall { name: string; args: string }

interface Meta {
  id: string | null
  target: string | null
  attempts: string | null
  cacheHit: boolean
  log?: LogEntry
}

interface Turn {
  role: 'user' | 'assistant'
  text: string
  thinking?: string
  tools?: ToolCall[]
  meta?: Meta
  error?: string
  pending?: boolean
  request?: unknown
  raw?: string
  images?: string[]     // 图片地址或 data URI
  attachments?: string[] // 用户消息附带的图片（data URI，不保存到本地存储）
  attachmentCount?: number // 本地存储里去掉图片后记下的张数
  audio?: string        // 音频 object URL（只在当前页面有效，不保存）
  decision?: Record<string, Answer> // 决策模型的回答
}

const STORE = 'lg.playground'
const DEFAULTS: Settings = { route: '', format: 'chat', system: '', temperature: '', maxTokens: '1024', effort: '', stream: true,
                             size: '1024x1024', n: '1', voice: '', audioFormat: 'mp3', questions: DEFAULT_QUESTIONS }

function loadSaved(): { settings: Settings; turns: Turn[] } {
  try {
    const v = JSON.parse(localStorage.getItem(STORE) ?? 'null')
    if (v && v.settings) {
      return { settings: { ...DEFAULTS, ...v.settings },
               turns: (v.turns ?? []).filter((t: Turn) => !t.pending).map(forStorage) }
    }
  } catch { /* 忽略损坏或不可用的本地存储 */ }
  return { settings: DEFAULTS, turns: [] }
}

// 本地存储不保存音频与附带的图片（体积大），只记图片张数
function forStorage(t: Turn): Turn {
  return { ...t, audio: undefined, attachments: undefined, attachmentCount: t.attachments?.length || t.attachmentCount }
}

// 用户消息内容：带图片时按接口格式组成多段内容
function content(format: Format, t: Turn): unknown {
  const imgs = t.role === 'user' ? t.attachments ?? [] : []
  if (!imgs.length) return t.text
  const text = t.text ? [t.text] : []
  if (format === 'messages') {
    return [...imgs.map((u) => {
      const [, mediaType, data] = /^data:([^;]+);base64,(.*)$/s.exec(u) ?? []
      return { type: 'image', source: { type: 'base64', media_type: mediaType, data } }
    }), ...text.map((x) => ({ type: 'text', text: x }))]
  }
  if (format === 'responses') {
    return [...text.map((x) => ({ type: 'input_text', text: x })), ...imgs.map((u) => ({ type: 'input_image', image_url: u }))]
  }
  return [...text.map((x) => ({ type: 'text', text: x })), ...imgs.map((u) => ({ type: 'image_url', image_url: { url: u } }))]
}

// 读取图片为 data URI；长边超过 MAX_SIDE 或文件较大时缩放并转 JPEG，控制请求体大小
const MAX_SIDE = 1568
async function readImage(file: File): Promise<string> {
  const url = await new Promise<string>((ok, fail) => {
    const r = new FileReader()
    r.onload = () => ok(r.result as string)
    r.onerror = () => fail(r.error)
    r.readAsDataURL(file)
  })
  const img = new Image()
  img.src = url
  await img.decode()
  const scale = Math.min(1, MAX_SIDE / Math.max(img.width, img.height))
  if (scale === 1 && file.size <= 1.5 * 1024 * 1024) return url
  const c = document.createElement('canvas')
  c.width = Math.round(img.width * scale)
  c.height = Math.round(img.height * scale)
  c.getContext('2d')!.drawImage(img, 0, 0, c.width, c.height)
  return c.toDataURL('image/jpeg', 0.9)
}

// 切换路由时按能力自动填参数：不支持推理清空推理强度、支持时默认 medium（保留已选档位）；
// 最大输出取各上游上限的最小值（最多 8192）
function applyCaps(p: Settings, c: RouteCaps): Settings {
  const r = c.summary.reasoning
  return {
    ...p,
    effort: r === 'none' ? '' : r === 'unknown' ? p.effort : p.effort || 'medium',
    maxTokens: c.summary.output ? String(Math.min(c.summary.output, 8192)) : p.maxTokens,
  }
}

// 问题表的非空行
const lines = (q: Question) => q.criteria.split('\n').map((l) => l.trim()).filter(Boolean)

// 问题表 → /v1/systemone 的 questions；choice 的 criteria 行「key: 说明」（没有说明时 key 即说明），score 的 criteria 为等级数组
function buildQuestions(qs: Question[]): Record<string, unknown> {
  const out: Record<string, unknown> = {}
  for (const q of qs) {
    const id = q.id.trim()
    if (!id) continue
    const base = { type: q.type, instructions: q.instructions.trim() }
    if (q.type === 'choice') {
      const criteria: Record<string, string> = {}
      for (const l of lines(q)) {
        const m = /^([^:：]+)[:：]\s*(.*)$/.exec(l)
        if (m) criteria[m[1].trim()] = m[2].trim() || m[1].trim()
        else criteria[l] = l
      }
      out[id] = { ...base, criteria }
    } else if (q.type === 'score') {
      out[id] = { ...base, criteria: lines(q) }
    } else {
      out[id] = base
    }
  }
  return out
}

function questionsError(qs: Question[]): string | undefined {
  if (!qs.length) return '至少要有一个问题'
  const ids = new Set<string>()
  for (const q of qs) {
    const id = q.id.trim()
    if (!id) return '问题 id 不能为空'
    if (ids.has(id)) return `问题 id 重复：${id}`
    ids.add(id)
    if (!q.instructions.trim()) return `${id}：问题描述不能为空`
    const n = lines(q).length
    if (q.type === 'choice' && n < 2) return `${id}：单选至少两个选项`
    if (q.type === 'score' && n < 2) return `${id}：打分至少两个等级`
  }
  return undefined
}

// state：输入是 JSON 对象时按对象发送，否则按文本
function parseState(text: string): unknown {
  try {
    const v = JSON.parse(text)
    if (v && typeof v === 'object' && !Array.isArray(v)) return v
  } catch { /* 不是 JSON，按文本 */ }
  return text
}

// 按客户端格式构造请求体（历史带文本与用户附带的图片；图片生成 / 语音 / 决策只用本次输入）
function buildBody(s: Settings, history: Turn[]): Record<string, unknown> {
  const last = history[history.length - 1]?.text ?? ''
  if (s.format === 'systemone') {
    return { model: s.route, state: parseState(last), questions: buildQuestions(s.questions) }
  }
  if (s.format === 'images') {
    return { model: s.route, prompt: last, n: Number(s.n) || 1, size: s.size, response_format: 'url' }
  }
  if (s.format === 'speech') {
    return { model: s.route, input: last, voice: s.voice || undefined, response_format: s.audioFormat }
  }
  const max = Number(s.maxTokens) || 1024
  const temp = s.temperature.trim() === '' ? undefined : Number(s.temperature)
  const msgs = history.filter((t) => (t.text || t.attachments?.length) && !t.images && !t.audio && !t.decision)
    .map((t) => ({ role: t.role, content: content(s.format, t) }))
  if (s.format === 'chat') {
    return {
      model: s.route, max_tokens: max, temperature: temp, stream: s.stream,
      reasoning_effort: s.effort || undefined,
      stream_options: s.stream ? { include_usage: true } : undefined,
      messages: [...(s.system ? [{ role: 'system', content: s.system }] : []), ...msgs],
    }
  }
  if (s.format === 'messages') {
    const budget = s.effort ? BUDGET[s.effort] : 0
    return {
      model: s.route, system: s.system || undefined, temperature: budget ? undefined : temp, stream: s.stream,
      max_tokens: budget ? Math.max(max, budget + 1024) : max,
      thinking: budget ? { type: 'enabled', budget_tokens: budget } : undefined,
      messages: msgs,
    }
  }
  return {
    model: s.route, instructions: s.system || undefined, max_output_tokens: max, temperature: temp, stream: s.stream,
    reasoning: s.effort ? { effort: s.effort } : undefined,
    input: msgs,
  }
}

// 非流式响应 → 文本、思考、工具调用
function parseSync(format: Format, j: any): Partial<Turn> {
  if (format === 'chat') {
    const m = j?.choices?.[0]?.message ?? {}
    return {
      text: m.content ?? '', thinking: m.reasoning_content ?? '',
      tools: (m.tool_calls ?? []).map((c: any) => ({ name: c.function?.name, args: c.function?.arguments ?? '' })),
    }
  }
  if (format === 'messages') {
    const blocks: any[] = j?.content ?? []
    return {
      text: blocks.filter((b) => b.type === 'text').map((b) => b.text).join(''),
      thinking: blocks.filter((b) => b.type === 'thinking').map((b) => b.thinking).join(''),
      tools: blocks.filter((b) => b.type === 'tool_use').map((b) => ({ name: b.name, args: JSON.stringify(b.input) })),
    }
  }
  const out: any[] = j?.output ?? []
  return {
    text: out.filter((o) => o.type === 'message').flatMap((o) => o.content ?? [])
      .filter((c: any) => c.type === 'output_text').map((c: any) => c.text).join(''),
    thinking: out.filter((o) => o.type === 'reasoning')
      .flatMap((o) => [...(o.content ?? []), ...(o.summary ?? [])]).map((c: any) => c.text ?? '').join(''),
    tools: out.filter((o) => o.type === 'function_call').map((o) => ({ name: o.name, args: o.arguments ?? '' })),
  }
}

// 流式事件增量更新
function applyEvent(format: Format, t: Turn, event: string | null, data: any): Turn {
  const tools = [...(t.tools ?? [])]
  const add = (k: 'text' | 'thinking', v: unknown) => (typeof v === 'string' && v ? { ...t, [k]: (t[k] ?? '') + v } : t)
  if (data?.error && (format !== 'responses' || event === 'error')) {
    return { ...t, error: data.error.message ?? JSON.stringify(data.error) }
  }
  if (format === 'chat') {
    const d = data?.choices?.[0]?.delta
    if (!d) return t
    let n = add('text', d.content)
    n = { ...n, thinking: (n.thinking ?? '') + (d.reasoning_content ?? '') }
    for (const c of d.tool_calls ?? []) {
      const i = c.index ?? 0
      tools[i] = { name: tools[i]?.name || c.function?.name || '', args: (tools[i]?.args ?? '') + (c.function?.arguments ?? '') }
    }
    return { ...n, tools }
  }
  if (format === 'messages') {
    if (event === 'error') return { ...t, error: data?.error?.message ?? '上游错误' }
    if (event === 'content_block_start' && data.content_block?.type === 'tool_use') {
      return { ...t, tools: [...tools, { name: data.content_block.name, args: '' }] }
    }
    if (event === 'content_block_delta') {
      const d = data.delta ?? {}
      if (d.type === 'text_delta') return add('text', d.text)
      if (d.type === 'thinking_delta') return add('thinking', d.thinking)
      if (d.type === 'input_json_delta' && tools.length) {
        tools[tools.length - 1] = { ...tools[tools.length - 1], args: tools[tools.length - 1].args + d.partial_json }
        return { ...t, tools }
      }
    }
    return t
  }
  switch (data?.type) {
    case 'response.output_text.delta': return add('text', data.delta)
    case 'response.reasoning_text.delta':
    case 'response.reasoning_summary_text.delta': return add('thinking', data.delta)
    case 'response.output_item.added':
      return data.item?.type === 'function_call' ? { ...t, tools: [...tools, { name: data.item.name, args: '' }] } : t
    case 'response.function_call_arguments.delta':
      if (!tools.length) return t
      tools[tools.length - 1] = { ...tools[tools.length - 1], args: tools[tools.length - 1].args + data.delta }
      return { ...t, tools }
    case 'error': return { ...t, error: data.message ?? '上游错误' }
    default: return t
  }
}

function curlFor(format: Format, body: unknown) {
  const auth = format === 'messages' ? `-H "x-api-key: $LITEGATE_API_KEY" -H "anthropic-version: 2023-06-01"`
    : `-H "Authorization: Bearer $LITEGATE_API_KEY"`
  const json = JSON.stringify(body, null, 2).replace(/'/g, `'\\''`)
  return `curl ${location.origin}${FORMATS[format].gateway} ${auth} -H "Content-Type: application/json" -d '${json}'`
}

export type {
  Answer,
  Effort,
  Format,
  Meta,
  Question,
  QuestionType,
  Settings,
  ToolCall,
  Turn,
}

export {
  applyCaps,
  applyEvent,
  BUDGET,
  buildBody,
  curlFor,
  DECISION_SUGGESTIONS,
  DEFAULT_QUESTIONS,
  FORMATS,
  forStorage,
  isChat,
  loadSaved,
  parseSync,
  readImage,
  QUESTION_TYPES,
  questionsError,
  STORE,
  SUGGESTIONS,
}
