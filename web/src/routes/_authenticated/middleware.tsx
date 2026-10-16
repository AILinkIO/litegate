import { createFileRoute } from '@tanstack/react-router'
import { AdminOnly } from '@/components/admin-only'
import { Middleware } from '@/features/middleware'

export const Route = createFileRoute('/_authenticated/middleware')({
  component: () => <AdminOnly><Middleware /></AdminOnly>,
})
