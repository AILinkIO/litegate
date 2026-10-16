import { createFileRoute } from '@tanstack/react-router'
import { AdminOnly } from '@/components/admin-only'
import { Credentials } from '@/features/credentials'

export const Route = createFileRoute('/_authenticated/credentials')({
  component: () => <AdminOnly><Credentials /></AdminOnly>,
})
