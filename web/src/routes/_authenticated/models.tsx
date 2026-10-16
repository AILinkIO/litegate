import { createFileRoute } from '@tanstack/react-router'
import { AdminOnly } from '@/components/admin-only'
import { Models } from '@/features/models'

export const Route = createFileRoute('/_authenticated/models')({
  component: () => <AdminOnly><Models /></AdminOnly>,
})
