import { createFileRoute } from '@tanstack/react-router'
import { ApiDocs } from '@/features/docs'

export const Route = createFileRoute('/_authenticated/docs')({
  component: ApiDocs,
})
