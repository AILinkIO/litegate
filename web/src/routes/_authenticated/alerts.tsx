import { createFileRoute } from '@tanstack/react-router'
import { AdminOnly } from '@/components/admin-only'
import { Alerts } from '@/features/alerts'

export const Route = createFileRoute('/_authenticated/alerts')({
  component: () => <AdminOnly><Alerts /></AdminOnly>,
})
