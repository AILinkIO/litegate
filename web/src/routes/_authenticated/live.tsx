import { createFileRoute } from '@tanstack/react-router'
import { AdminOnly } from '@/components/admin-only'
import { Live } from '@/features/live'

export const Route = createFileRoute('/_authenticated/live')({
  component: () => <AdminOnly><Live /></AdminOnly>,
})
