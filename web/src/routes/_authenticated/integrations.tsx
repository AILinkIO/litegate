import { createFileRoute } from '@tanstack/react-router'
import { Integrations } from '@/features/integrations'

export const Route = createFileRoute('/_authenticated/integrations')({
  component: Integrations,
})
