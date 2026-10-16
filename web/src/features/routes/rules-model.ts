import { type RouteRule } from '@/lib/api'
import { hoursOk, rangeOk } from '@/lib/rules'

export { hoursOk, rangeOk }

/** 编辑中的规则：数字以字符串保存，保存时再转换 */
export interface RuleDraft {
  min_tokens: string
  max_tokens: string
  images: '' | 'true' | 'false'
  thinking: '' | 'true' | 'false'
  client: string[]
  tool: string[]
  tags: string[]
  hours: string
  intent: string
  action: 'use' | 'skip'
  use: string
  skip: string[]
}

export function ruleDraft(r: RouteRule): RuleDraft {
  const w = r.when ?? {}
  return {
    min_tokens: w.min_tokens?.toString() ?? '', max_tokens: w.max_tokens?.toString() ?? '',
    images: w.images === undefined ? '' : (String(w.images) as 'true' | 'false'),
    thinking: w.thinking === undefined ? '' : (String(w.thinking) as 'true' | 'false'),
    client: w.client ?? [], tool: w.tool ?? [], tags: w.tags ?? [], hours: w.hours ?? '', intent: w.intent ?? '',
    action: r.skip ? 'skip' : 'use', use: r.use ?? '', skip: r.skip ?? [],
  }
}

export const emptyRule = (): RuleDraft => ruleDraft({ use: '' })

export function ruleFromDraft(d: RuleDraft): RouteRule {
  const when: RouteRule['when'] = {}
  if (d.min_tokens.trim()) when.min_tokens = Number(d.min_tokens)
  if (d.max_tokens.trim()) when.max_tokens = Number(d.max_tokens)
  if (d.images) when.images = d.images === 'true'
  if (d.thinking) when.thinking = d.thinking === 'true'
  if (d.client.length) when.client = d.client as ('openai' | 'anthropic' | 'responses')[]
  if (d.tool.length) when.tool = d.tool
  if (d.tags.length) when.tags = d.tags
  if (d.hours.trim()) when.hours = d.hours.trim()
  if (d.intent.trim()) when.intent = d.intent.trim()
  return d.action === 'use' ? { when, use: d.use } : { when, skip: d.skip }
}

const intOk = (s: string) => s.trim() === '' || (Number.isInteger(Number(s)) && Number(s) >= 0)

export function ruleValid(d: RuleDraft): boolean {
  return intOk(d.min_tokens) && intOk(d.max_tokens) && (d.hours.trim() === '' || hoursOk(d.hours))
    && (d.action === 'use' ? d.use !== '' : d.skip.length > 0)
}
