import { createFileRoute } from '@tanstack/react-router'
import { Usage } from '@/features/usage'

export const Route = createFileRoute('/_authenticated/usage')({
  component: Usage,
})
