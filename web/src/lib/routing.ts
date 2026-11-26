// 路由方式的显示名与说明（路由编辑与实时路由页共用）
import type { Affinity, Strategy } from './api'
import { tk } from '@/i18n'

export const STRATEGY_LABEL: Record<Strategy, string> = {
  weighted: tk('按权重随机'), order: tk('按顺序'), rotate: tk('轮流'), usage: tk('用得少的优先'), smart: tk('额度：先重置的优先'), pace: tk('额度：周进度'),
}

export const STRATEGY_HELP: Record<Strategy, string> = {
  weighted: tk('按目标的权重随机分流'),
  order: tk('按目标顺序，第一个一直用到失败或额度用尽'),
  rotate: tk('新会话分给最近 30 分钟承载会话最少的目标'),
  usage: tk('套餐窗口已用比例低的优先，其次是最近发出 token 少的'),
  smart: tk('套餐凭证中先重置的优先（重置时浪费最少），≥ 90% 的排后；普通 Key 排在套餐之后'),
  pace: tk('套餐凭证按「周剩余 ÷ 距重置小时数」高的优先；普通 Key 排在套餐之后'),
}

export const AFFINITY_HELP: Record<Affinity, string> = {
  auto: tk('同一段对话留在最先回答它的目标上以命中提示词缓存：一轮之内始终保留；新的一轮在上次读到 ≥ 1024 缓存 token 且 5 分钟内回答过时保留'),
  session: tk('整个会话留在同一目标（目标冷却、套餐窗口 ≥ 98% 时除外）'),
  off: tk('每个请求按正常顺序选择目标'),
}

