import { createFileRoute } from '@tanstack/react-router'
import { AdminOnly } from '@/components/admin-only'
import { Routes } from '@/features/routes'

// ?provider=&model= 从模型目录跳转过来时预填新路由
export const Route = createFileRoute('/_authenticated/routes')({
  validateSearch: (s: Record<string, unknown>): { provider?: string; model?: string } => ({
    ...(typeof s.provider === 'string' ? { provider: s.provider } : {}),
    ...(typeof s.model === 'string' ? { model: s.model } : {}),
  }),
  component: () => <AdminOnly><Routes /></AdminOnly>,
})
