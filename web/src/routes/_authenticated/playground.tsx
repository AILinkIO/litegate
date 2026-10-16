import { createFileRoute } from '@tanstack/react-router'
import { AdminOnly } from '@/components/admin-only'
import { Playground } from '@/features/playground'

export const Route = createFileRoute('/_authenticated/playground')({
  component: () => <AdminOnly><Playground /></AdminOnly>,
})
