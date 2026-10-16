import { createFileRoute } from '@tanstack/react-router'
import { AdminOnly } from '@/components/admin-only'
import { Health } from '@/features/health'

export const Route = createFileRoute('/_authenticated/health')({
  component: () => <AdminOnly><Health /></AdminOnly>,
})
