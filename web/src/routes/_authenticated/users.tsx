import { createFileRoute } from '@tanstack/react-router'
import { AdminOnly } from '@/components/admin-only'
import { Users } from '@/features/users'

export const Route = createFileRoute('/_authenticated/users')({
  component: () => <AdminOnly><Users /></AdminOnly>,
})
