import { createFileRoute } from '@tanstack/react-router'
import { Sessions } from '@/features/sessions'

// ?id= 打开会话详情
export const Route = createFileRoute('/_authenticated/sessions')({
  validateSearch: (s: Record<string, unknown>): { id?: string } => (typeof s.id === 'string' ? { id: s.id } : {}),
  component: Sessions,
})
