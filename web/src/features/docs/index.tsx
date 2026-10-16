import { useMemo, useState } from 'react'
import { ChevronRight, ExternalLink, Search } from 'lucide-react'
import { useGet } from '@/lib/query'
import { cn } from '@/lib/utils'
import { Badge } from '@/components/ui/badge'
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from '@/components/ui/collapsible'
import { Input } from '@/components/ui/input'
import { Skeleton } from '@/components/ui/skeleton'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { PageHeader } from '@/components/page'
import { Empty, ErrorAlert } from '@/components/query-state'

interface Param { name: string; in: 'path' | 'query'; required?: boolean; schema?: { type?: string }; description?: string }
interface Operation {
  tags?: string[]
  summary?: string
  description?: string
  parameters?: Param[]
  requestBody?: { content: Record<string, { example?: unknown }> }
  responses?: Record<string, { description?: string; content?: Record<string, { example?: unknown }> }>
  security?: unknown[]
}
interface OpenApi {
  info: { title: string; version: string; description?: string }
  tags?: { name: string }[]
  paths: Record<string, Record<string, Operation>>
}
interface Endpoint { method: string; path: string; op: Operation }

const METHOD: Record<string, string> = {
  get: 'bg-success-soft text-success', post: 'bg-primary-soft text-primary', put: 'bg-warning-soft text-warning', delete: 'bg-destructive-soft text-destructive',
}

/** 接口文档：GET /api/openapi.json（手写 OpenAPI 3.1），按分组渲染 */
export function ApiDocs() {
  const q = useGet<OpenApi>('/openapi.json')
  const [term, setTerm] = useState('')
  const data = q.data
  const groups = useMemo(() => {
    if (!data) return []
    const all: Endpoint[] = Object.entries(data.paths).flatMap(([path, ops]) => Object.entries(ops).map(([method, op]) => ({ method, path, op })))
    const t = term.trim().toLowerCase()
    const hit = (e: Endpoint) => !t || `${e.method} ${e.path} ${e.op.summary ?? ''} ${e.op.description ?? ''}`.toLowerCase().includes(t)
    return (data.tags ?? []).map((g) => ({ tag: g.name, items: all.filter((e) => e.op.tags?.[0] === g.name && hit(e)) })).filter((g) => g.items.length > 0)
  }, [data, term])

  return (
    <>
      <PageHeader title='接口文档' subtitle={data?.info.description ?? 'LiteGate 网关与管理接口'}
        actions={<a href='/api/openapi.json' target='_blank' rel='noopener' className='flex items-center gap-1 text-sm text-primary hover:underline'>openapi.json <ExternalLink className='size-3.5' /></a>} />
      <div className='relative mb-4'>
        <Search className='absolute start-2.5 top-1/2 size-4 -translate-y-1/2 text-muted-foreground' />
        <Input className='bg-card ps-8' placeholder='搜索路径、说明…' value={term} onChange={(e) => setTerm(e.target.value)} />
      </div>
      {q.error && <ErrorAlert message={q.error.message} />}
      {!data && !q.error && <Skeleton className='h-96 rounded-xl' />}
      {groups.map((g) => (
        <section key={g.tag} className='mb-6'>
          <h2 className='mb-2 text-sm font-semibold text-subtle-foreground'>{g.tag}</h2>
          <div className='overflow-hidden rounded-xl border bg-card'>
            {g.items.map((e, i) => <EndpointView key={`${e.method} ${e.path}`} e={e} first={i === 0} />)}
          </div>
        </section>
      ))}
      {data && groups.length === 0 && <div className='rounded-xl border bg-card'><Empty>没有匹配的接口</Empty></div>}
    </>
  )
}

function EndpointView({ e, first }: { e: Endpoint; first: boolean }) {
  const { method, path, op } = e
  const reqExample = op.requestBody?.content['application/json']?.example
  const ok = op.responses?.['200']
  const respExample = ok?.content?.['application/json']?.example
  const streams = !!ok?.content?.['text/event-stream']
  const noAuth = Array.isArray(op.security) && op.security.length === 0
  return (
    <Collapsible className={cn(!first && 'border-t')}>
      <CollapsibleTrigger className='group flex w-full flex-wrap items-center gap-x-3 gap-y-1 px-4 py-2.5 text-start hover:bg-accent/40'>
        <ChevronRight className='size-4 shrink-0 text-muted-foreground transition-transform group-data-[state=open]:rotate-90' />
        <span className={cn('w-16 shrink-0 rounded-md py-0.5 text-center font-mono text-xs font-semibold', METHOD[method] ?? 'bg-secondary')}>{method.toUpperCase()}</span>
        <code className='text-[13px] break-all'>{path}</code>
        <span className='text-sm text-muted-foreground'>{op.summary}</span>
        {streams && <Badge variant='outline'>SSE</Badge>}
        {noAuth && <Badge variant='outline'>无需鉴权</Badge>}
      </CollapsibleTrigger>
      <CollapsibleContent className='CollapsibleContent'>
        <div className='grid gap-3 border-t bg-secondary/20 px-4 py-3 ps-11'>
          {op.description && <p className='text-sm'>{op.description}</p>}
          {!!op.parameters?.length && (
            <div className='overflow-x-auto rounded-lg border bg-card'>
              <Table>
                <TableHeader>
                  <TableRow className='[&>th]:h-8 [&>th]:text-xs [&>th]:text-muted-foreground'><TableHead>参数</TableHead><TableHead>位置</TableHead><TableHead>类型</TableHead><TableHead>说明</TableHead></TableRow>
                </TableHeader>
                <TableBody>
                  {op.parameters.map((p) => (
                    <TableRow key={`${p.in}-${p.name}`}>
                      <TableCell className='font-mono text-[13px]'>{p.name}{p.required && ' *'}</TableCell>
                      <TableCell>{p.in === 'path' ? '路径' : '查询'}</TableCell>
                      <TableCell className='font-mono text-[13px]'>{p.schema?.type ?? ''}</TableCell>
                      <TableCell>{p.description ?? ''}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )}
          {reqExample !== undefined && <Example title='请求体示例' value={reqExample} />}
          {respExample !== undefined && <Example title='响应示例' value={respExample} />}
        </div>
      </CollapsibleContent>
    </Collapsible>
  )
}

function Example({ title, value }: { title: string; value: unknown }) {
  return (
    <div>
      <div className='mb-1 text-xs text-muted-foreground'>{title}</div>
      <pre className='overflow-x-auto rounded-lg border bg-card p-3 font-mono text-xs'>{typeof value === 'string' ? value : JSON.stringify(value, null, 2)}</pre>
    </div>
  )
}
