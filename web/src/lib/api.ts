// 控制台 API 客户端：会话 cookie 由浏览器自动携带
export class ApiError extends Error {
  status: number
  code: string
  constructor(status: number, code: string, message: string) {
    super(message)
    this.status = status
    this.code = code
  }
}

let onUnauthorized: () => void = () => {}
export function setUnauthorizedHandler(fn: () => void) {
  onUnauthorized = fn
}

async function request<T>(method: string, path: string, body?: unknown): Promise<T> {
  const res = await fetch(`/api${path}`, {
    method,
    credentials: 'same-origin',
    headers: body === undefined ? {} : { 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const data = res.status === 204 ? null : await res.json().catch(() => null)
  if (!res.ok) {
    if (res.status === 401 && path !== '/auth/login') onUnauthorized()
    const err = data?.error ?? {}
    throw new ApiError(res.status, err.code ?? 'error', err.message ?? res.statusText)
  }
  return data as T
}

export const api = {
  get: <T>(path: string) => request<T>('GET', path),
  post: <T>(path: string, body?: unknown) => request<T>('POST', path, body ?? {}),
  put: <T>(path: string, body: unknown) => request<T>('PUT', path, body),
  del: <T = { ok: boolean }>(path: string) => request<T>('DELETE', path),
}

// 路径段编码（路由名、模型 id 可能含 /）
export const seg = encodeURIComponent

export function qs(params: Record<string, string | number | boolean | undefined | null>) {
  const p = new URLSearchParams()
  for (const [k, v] of Object.entries(params)) {
    if (v !== undefined && v !== null && v !== '') p.set(k, String(v))
  }
  const s = p.toString()
  return s ? `?${s}` : ''
}

// ---- 类型 ----

export interface VersionInfo {
  version: string
  commit: string
}

export type Role = 'admin' | 'user'

export interface User {
  id: string
  username: string
  role: Role
  enabled: boolean
  created_at: number
  budget?: BudgetStatus | null
  auth_enabled?: boolean   // 仅 /auth/me 返回：false 为单机免登录模式
  insecure_exposed?: boolean // 仅 /auth/me 返回：免登录且 HTTP 绑定非 loopback
}

export interface CatalogProvider {
  id: string
  name: string
  npm?: string | null
  api?: string | null
  protocol?: 'openai' | 'anthropic' | null
  source: 'synced' | 'custom'
}

export interface CatalogModel {
  provider: string
  id: string
  name?: string
  family?: string
  source: 'synced' | 'overridden' | 'custom'
  limit?: { context?: number; output?: number }
  cost?: { input?: number; output?: number; cache_read?: number; cache_write?: number; image?: number; tts?: number }
  modalities?: { input?: string[]; output?: string[] }
  reasoning?: boolean
  tool_call?: boolean
  release_date?: string
  overlay?: Record<string, unknown> | null
  [k: string]: unknown
}

export interface Credential {
  id: string
  name: string
  protocol: 'openai' | 'anthropic'
  base_url: string
  api_key_hint: string | null
  headers: Record<string, string>
  provider: string | null
  options: CredentialOptions
  enabled: boolean
  created_at: number
  updated_at: number
  plan_status: PlanStatus | null
  balance_status: BalanceStatus | null
  balance_suggest: BalanceKind | null
}

export type PlanKind = 'minimax' | 'glm' | 'kimi'

export type BalanceKind = 'deepseek' | 'moonshot' | 'openrouter' | 'newapi'

export const BALANCE_KINDS: Record<BalanceKind, string> = {
  deepseek: 'DeepSeek', moonshot: 'Kimi（Moonshot 开放平台）', openrouter: 'OpenRouter', newapi: 'New API / One API 中转站',
}

export interface BalanceStatus {
  credential: string
  credential_name: string
  kind: BalanceKind
  amount: number | null
  currency: string | null
  details: { currency: string; amount: number }[]
  alert_below: number | null
  fetched_at: number | null
  checked_at: number | null
  error: string | null
}

export interface PlanConfig {
  kind: PlanKind
  reserve_pct?: number
  window_caps?: Record<string, number>
}

export interface PlanWindow {
  name: string
  used_pct: number
  resets_at: number | null
}

export interface PlanStatus {
  credential: string
  credential_name: string
  kind: PlanKind
  reserve_pct: number
  state: 'normal' | 'reserve' | 'exhausted'
  level?: string | null
  windows?: PlanWindow[]
  fetched_at?: number | null
  checked_at?: number
  error?: string | null
}

export type Affinity = 'auto' | 'session' | 'off'
export type Strategy = 'weighted' | 'order' | 'rotate' | 'usage' | 'smart' | 'pace'

export interface RouteRule {
  when?: {
    min_tokens?: number
    max_tokens?: number
    images?: boolean
    thinking?: boolean
    client?: ('openai' | 'anthropic' | 'responses')[]
    tool?: string[]
    tags?: string[]
    hours?: string
    intent?: string
  }
  use?: string
  skip?: string[]
}

/** 意图判断方式：llm 由 classifier 路由判断；laya 由本地 Laya 服务判断；systemone 由决策模型路由
 * （decision_route，如百炼 decision-model-preview）判断。后两者以 classifier 为失败时的后备 */
export type IntentEngine = 'llm' | 'laya' | 'systemone'

/** 决策模型问法：choice 一道单选题（含「以上都不是」，默认）；noul 每条意图一道是非题 */
export type DecisionStyle = 'noul' | 'choice'

export interface RouteOptions {
  cache_ttl_s?: number
  affinity?: Affinity
  strategy?: Strategy
  rules?: RouteRule[]
  classifier?: string
  intent_engine?: IntentEngine
  decision_route?: string
  decision_style?: DecisionStyle
  loop_guard?: boolean
  redact?: boolean
}

export interface CredentialOptions {
  responses_api?: boolean
  plan?: PlanConfig
  extra_body?: Record<string, unknown>
  think_tags?: 'split'
  prompt_cache?: 'auto'
  media_api?: 'openai' | 'minimax'
  max_concurrency?: number
  responses_base_url?: string
  balance?: { kind: BalanceKind; alert_below?: number }
}

export interface RouteTarget {
  /** 嵌套路由目标：另一条路由（此时 credential / upstream_model 不使用） */
  route?: string
  credential: string
  upstream_model: string
  model_ref: [string, string] | null
  weight: number
  priority: number
  enabled: boolean
}

export interface Route {
  name: string
  targets: RouteTarget[]
  fallbacks: string[]
  aliases: string[]
  access: 'all' | string[]
  options: RouteOptions
  enabled: boolean
  created_at: number
  updated_at: number
  limit?: LimitValues | null
  key_limits?: (LimitValues & { key_id: string })[]
}

export interface LimitValues {
  rpm: number | null
  tpm: number | null
  max_parallel: number | null
}

export interface BudgetStatus {
  period: 'day' | 'week' | 'month'
  max_usd: number
  spent_usd: number
  resets_at: number
}

export type LimitScope =
  | { type: 'key'; key_id: string }
  | { type: 'route'; route: string }
  | { type: 'key_route'; key_id: string; route: string }
  | { type: 'user'; user_id: string }

export interface ApiKey {
  id: string
  prefix: string
  name: string
  user_id: string | null
  allowed_routes: 'all' | string[]
  max_tokens: number | null
  enabled: boolean
  expires_at: number | null
  tags: string[]
  options?: { redact?: boolean }
  created_at: number
  key?: string
  limit?: LimitValues | null
  budget?: BudgetStatus | null
}

export interface Usage {
  input: number
  output: number
  cache_read: number
  cache_write: number
  reasoning?: number
  images?: number
  chars?: number
}

/** 提示词构成（估算 token） */
export interface ContextBreakdown {
  system: number
  tools: number
  history: number
  input: number
  images: number
  total: number
  messages: number
  tool_list: { name: string; tokens: number }[]
}

/** 会话汇总（按会话标识聚合的请求） */
export interface SessionSummary {
  id: string
  first_ts: number
  last_ts: number
  requests: number
  turns: number
  errors: number
  input: number
  output: number
  cache_read: number
  cache_write: number
  cost: number
  plan_usd: number
  duration_ms: number
  routes: string[]
  models: string[]
  client?: string
  key_id?: string
  user_id?: string
  session_source?: 'explicit' | 'derived'
}

export interface LogEntry {
  id: string
  ts: number
  format: 'openai' | 'anthropic' | 'embeddings' | 'responses' | 'images' | 'speech' | 'systemone'
  stream: boolean
  status: number
  route: string
  model?: string   // 客户端请求的模型名（通配路由时与 route 不同）
  key_id: string
  user_id: string | null
  credential?: string
  upstream_model?: string
  model_ref?: [string, string]
  usage?: Usage
  cost?: number
  duration_ms: number
  ttft_ms?: number
  cache_hit?: boolean
  saved_usd?: number
  plan?: boolean
  plan_usd?: number
  source?: 'gateway' | 'playground'
  tags?: string[]
  attempts: number
  finish_reason?: string | null
  client_aborted?: boolean
  error?: { kind: string; message?: string; detail?: unknown }
  messages?: { request: Record<string, unknown>; response: string } | null
  score?: number
  session?: string
  client?: string             // 客户端工具（claude-code、codex、opencode、openai-sdk、anthropic-sdk、other、litegate 或自报名）
  user_agent?: string         // 识别为 other 时记录
  affinity?: string           // hit | miss | broken:<原因>
  rule?: number               // 命中的规则序号，0 = 有意图判断但没有规则命中
  routed_to?: string
  intent?: { answer: number; ms: number; reply?: string; error?: string; cached?: boolean }
  queued_ms?: number
  redacted?: number           // 脱敏替换的不同值个数
  new_turn?: boolean          // 本轮由用户输入开始（不是工具结果）
  context?: ContextBreakdown
  loop_detected?: boolean
  attempt_list?: LogAttempt[]
  plan_trace?: { route: string; credential: string; upstream_model: string; tier: string; note: string; via?: string[] }[]
  narrative?: NarrativeLine[]
}

export interface NarrativeLine {
  tone: 'info' | 'muted' | 'warn' | 'ok' | 'error'
  text: string
}

/** GET /api/routes/:name/capabilities：路由能到达的上游及其能力（lg_route_caps） */
export type CapLevel = 'all' | 'some' | 'none' | 'unknown'
export interface RouteCapTarget {
  credential: string
  credential_name: string
  upstream_model: string
  via: string[]
  known: boolean
  reasoning: boolean | null
  context: number | null
  output: number | null
  images: boolean | null
  locked_sampling: boolean
}
export interface RouteCaps {
  route: string
  targets: RouteCapTarget[]
  summary: { reasoning: CapLevel; images: CapLevel; context: number | null; output: number | null; locked_sampling: boolean; unknown: number }
}

export interface LogAttempt {
  route: string
  credential: string
  upstream_model: string
  started_at?: number
  duration_ms: number
  ok: boolean
  busy?: boolean
  kind?: string
  message?: string
}

export interface UsageRow {
  requests: number
  errors: number
  input: number
  output: number
  cache_read: number
  cache_write: number
  cost: number
  duration_ms: number
  streams?: number
  cache_hits?: number
  saved_usd?: number
  plan_requests?: number
  plan_usd?: number
  p50_ms?: number | null
  p95_ms?: number | null
  ttft_p50_ms?: number | null
  ttft_p95_ms?: number | null
  hour?: number
  day?: number
  route?: string | null
  key_id?: string | null
  user_id?: string | null
  credential?: string | null
  model?: string | null
  tag?: string | null
  client?: string | null
}

export interface SyncStatus {
  status: 'ok' | 'error' | 'never'
  at?: number
  source?: string
  providers?: number
  models?: number
  error?: string
  duration_ms?: number
}

export interface Overview {
  usage_24h: Partial<UsageRow>
  hourly: UsageRow[]
  counts?: { routes: number; credentials: number; keys: number; catalog_models: number }
  catalog_sync?: SyncStatus
}

export interface Setting {
  key: string
  value: string | number | boolean
  default: string | number | boolean
  source: 'runtime' | 'env' | 'app' | 'default'
  editable: boolean
}

// 按小时的用量行汇总到浏览器本地时区的天（键为当天零点毫秒）
export function byLocalDay(rows: UsageRow[]): Map<number, UsageRow> {
  const out = new Map<number, UsageRow>()
  for (const r of rows) {
    const d = new Date(r.hour ?? 0)
    d.setHours(0, 0, 0, 0)
    const k = d.getTime()
    const acc = out.get(k)
    if (!acc) {
      out.set(k, { ...r })
    } else {
      for (const f of ['requests', 'errors', 'input', 'output', 'cache_read', 'cache_write', 'cost', 'duration_ms'] as const) {
        acc[f] += r[f]
      }
    }
  }
  return out
}

export interface StoreStatus {
  casks: { cask: string; keys: number; bytes: number; needs_merge: boolean }[]
  cleanup: {
    at: number
    duration_ms: number
    logs: number
    index: number
    usage: number
    merged: string[]
    log_retention_days: number
    usage_retention_days: number
  } | null
}

export interface HealthTarget {
  credential: string
  credential_name: string
  protocol: 'openai' | 'anthropic'
  upstream_model: string
  ok: number
  errors: number
  error_kinds: Record<string, number>
  success_rate: number | null
  avg_ms: number | null
  cooldown_ms: number
  concurrency: { inflight: number; queued: number; max: number } | null
  cooldown: { remaining_ms: number; kind: string; reason: string; streak: number; scope: 'target' | 'credential' } | null
  plan_state: 'normal' | 'reserve' | 'exhausted' | null
  last_error: { at: number; kind: string; message: string | null } | null
  last_ok_at: number | null
}

export interface ProbeResult {
  credential: string
  at: number
  result: string            // ok 或错误类型
  message: string | null
  latency_ms: number
}

export interface HealthStatus {
  targets: HealthTarget[]
  probes: ProbeResult[]
  probe_interval_ms: number
}

export type ChannelType = 'webhook' | 'feishu' | 'dingtalk' | 'wecom'
export type AlertEvent = 'budget' | 'upstream_down' | 'plan_quota' | 'catalog_sync_failed' | 'balance_low'

export interface AlertChannel {
  id: string
  name: string
  type: ChannelType
  url_hint: string
  has_secret: boolean
  enabled: boolean
  created_at: number
  updated_at: number
}

export interface AlertRule {
  id: string
  event: AlertEvent
  threshold: number | null
  channels: string[]
  enabled: boolean
  created_at: number
  updated_at: number
}

export interface AlertRecord {
  id: string
  ts: number
  event: AlertEvent | 'test'
  level: 'info' | 'warning' | 'critical'
  title: string
  text: string
  data?: Record<string, unknown>
  deliveries: { channel: string; channel_name: string; status: 'pending' | 'ok' | 'error'; error?: string }[]
}

/** 客户端工具的显示名（未知的自报名原样显示） */
export const CLIENT_LABEL: Record<string, string> = {
  'claude-code': 'Claude Code', codex: 'Codex', opencode: 'opencode', 'openai-sdk': 'OpenAI SDK',
  'anthropic-sdk': 'Anthropic SDK', other: '其他', litegate: '网关内部（意图判断）',
}
export const clientLabel = (c?: string | null) => (c ? CLIENT_LABEL[c] ?? c : '—')

// ---- 实时路由视图（/api/live/state、/api/live/stream） ----

export interface LiveClient {
  client: string | null
  key_name: string | null
  requests: number
  active: number
}

export interface LiveRoute {
  route: string
  requests: number
  reroutes: number
  errors: number
  active: number
  clients: LiveClient[]
}

export interface LiveActive {
  request_id: string
  route: string
  client: string | null
  key_name: string | null
  started_at: number
  stream: boolean
  state: 'waiting' | 'attempting'
  credential?: string
  upstream_model?: string
}

export interface LiveTarget {
  route: string
  credential: string
  credential_name: string
  upstream_model: string
  via?: string[]
  tier: string
  state: 'idle' | 'answering' | 'cooling' | 'exhausted'
  answering: number
  cooldown: { remaining_ms: number; kind: string; reason: string; scope: string; streak: number } | null
  concurrency: { inflight: number; queued: number; max: number } | null
  note: string
}

export interface LiveState {
  routes: LiveRoute[]
  active: LiveActive[]
  selected: string | null
  targets: LiveTarget[]
  window_ms: number
  last: { route: string; narrative: NarrativeLine[]; ts: number } | null
}

// ---- 网关中间件（/api/middleware） ----

export interface MiddlewareImpl {
  impl: string
  title: string
  description: string
  hooks: ('on_request' | 'on_event' | 'on_response')[]
  options_example: Record<string, unknown>
  source: 'builtin' | 'plugin'
  file: string | null          // 插件的 .beam 路径
}

/** 重新扫描插件目录的结果 */
export interface PluginScan {
  dir: string
  files: { module: string; file: string; result: { status: 'loaded' | 'library' | 'error'; impl?: string; message?: string } }[]
}

/** 试运行结果 */
export interface MiddlewareTest {
  result: { kind: 'continue' | 'ok' | 'reject' | 'error' | 'no_hook' | 'bad_return'; body?: Record<string, unknown>;
            state?: string; status?: number; message?: string }
  us: number
  timeout_ms?: number
}

export interface MiddlewareItem {
  id: string
  name: string
  impl: string
  options: Record<string, unknown>
  routes: 'all' | string[]
  position: number
  enabled: boolean
  stats: { calls: number; failures: number; slow: number; avg_us: number;
           last_error: { at: number; hook: string; message: string } | null } | null
  missing_impl?: boolean       // 实现不存在（插件被删掉），不在调用链里
  hooks?: ('on_request' | 'on_event' | 'on_response')[]   // 按这条配置实际启用的点位
}

// ---- 已学到的上游参数限制（/api/unfit） ----
export interface UnfitItem {
  credential: string
  credential_name: string
  upstream_model: string
  feature: string
  message: string
  learned_at: number
}
