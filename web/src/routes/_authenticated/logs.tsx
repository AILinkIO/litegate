import { createFileRoute } from '@tanstack/react-router'
import { Logs } from '@/features/request-logs'

// ?id= 直接打开某条日志的详情（Playground、会话页跳转用）
export const Route = createFileRoute('/_authenticated/logs')({
  validateSearch: (s: Record<string, unknown>): { id?: string } => (typeof s.id === 'string' ? { id: s.id } : {}),
  component: Logs,
})
