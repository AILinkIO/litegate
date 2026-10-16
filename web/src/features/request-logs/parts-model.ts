import type { LogEntry } from '@/lib/api'

export const ENDPOINT: Record<LogEntry['format'], string> = {
  openai: '/v1/chat/completions',
  anthropic: '/v1/messages',
  embeddings: '/v1/embeddings',
  responses: '/v1/responses',
  images: '/v1/images/generations',
  speech: '/v1/audio/speech',
  systemone: '/v1/systemone',
}

export function affinityLabel(a: string): string {
  if (a === 'hit') return '命中'
  if (a === 'miss') return '新会话'
  const why: Record<string, string> = {
    cache_cold: '缓存已冷，重新选择', cooling: '原目标冷却中', plan_window_full: '原目标套餐窗口将满',
    concurrency_full: '原目标并发已满', target_gone: '原目标已不在路由中',
  }
  return a.startsWith('broken:') ? `放弃（${why[a.slice(7)] ?? a.slice(7)}）` : a
}

/** 消息 content 可能是字符串或内容块数组 */
export function contentText(c: unknown): string {
  if (typeof c === 'string') return c
  if (Array.isArray(c)) {
    return c.map((p) => {
      const part = p as Record<string, unknown>
      if (typeof part.text === 'string') return part.text
      if (part.type === 'tool_result') return `[tool_result] ${contentText(part.content)}`
      if (part.type === 'tool_use') return `[tool_use ${part.name}] ${JSON.stringify(part.input)}`
      return `[${String(part.type)}]`
    }).join('\n')
  }
  return c === null || c === undefined ? '' : JSON.stringify(c)
}
