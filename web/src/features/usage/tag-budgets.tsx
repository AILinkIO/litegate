import { useState } from 'react'
import { Plus, Trash2 } from 'lucide-react'
import { toast } from 'sonner'
import { api, type BudgetStatus } from '@/lib/api'
import { fmtCost, fmtTime } from '@/lib/format'
import { useGet, useInvalidate } from '@/lib/query'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { PERIOD_LABEL } from '@/lib/limits'
import { Meter } from '@/components/meter'

interface TagBudget {
  scope: { type: string; tag?: string }
  period: BudgetStatus['period']
  max_usd: number
  status: BudgetStatus | null
}

/** 标签预算：请求的任一标签超出本期预算即 429（周期按 UTC） */
export function TagBudgets() {
  const { data } = useGet<TagBudget[]>('/budgets')
  const invalidate = useInvalidate()
  const rows = (data ?? []).filter((b) => b.scope.type === 'tag')
  const [tag, setTag] = useState('')
  const [period, setPeriod] = useState<BudgetStatus['period']>('month')
  const [max, setMax] = useState('')

  const put = async (t: string, body: Record<string, unknown>) => {
    try {
      await api.put('/budgets', { scope: { type: 'tag', tag: t }, ...body })
      await invalidate('/budgets')
      return true
    } catch (e) {
      toast.error((e as Error).message)
      return false
    }
  }

  return (
    <Card className='mt-6'>
      <CardHeader>
        <CardTitle className='text-sm'>标签预算</CardTitle>
        <CardDescription>
          带该标签的请求累计花费超出本期上限后返回 429，直到下个周期（UTC）；标签来自请求头 X-LiteGate-Tags、metadata.tags 或 Key 的默认标签
        </CardDescription>
      </CardHeader>
      <CardContent className='grid gap-4'>
        {rows.length > 0 && (
          <Table>
            <TableHeader>
              <TableRow className='[&>th]:text-xs [&>th]:text-muted-foreground'>
                <TableHead>标签</TableHead><TableHead>周期</TableHead><TableHead>本期已用 / 上限</TableHead><TableHead>重置</TableHead><TableHead />
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((b) => {
                const spent = b.status?.spent_usd ?? 0
                return (
                  <TableRow key={b.scope.tag}>
                    <TableCell className='font-mono text-[13px]'>{b.scope.tag}</TableCell>
                    <TableCell>{PERIOD_LABEL[b.period]}</TableCell>
                    <TableCell className='min-w-44'>
                      <span className='num'>{fmtCost(spent)} / {fmtCost(b.max_usd)}</span>
                      <Meter className='mt-1' pct={(spent / b.max_usd) * 100} />
                    </TableCell>
                    <TableCell className='text-muted-foreground'>{fmtTime(b.status?.resets_at)}</TableCell>
                    <TableCell className='text-end'>
                      <Button variant='ghost' size='icon' aria-label='删除' onClick={() => put(b.scope.tag!, { max_usd: null })}>
                        <Trash2 />
                      </Button>
                    </TableCell>
                  </TableRow>
                )
              })}
            </TableBody>
          </Table>
        )}
        <div className='flex flex-wrap items-center gap-2'>
          <Input className='w-40' placeholder='标签' value={tag} onChange={(e) => setTag(e.target.value)} />
          <Select value={period} onValueChange={(v) => setPeriod(v as BudgetStatus['period'])}>
            <SelectTrigger className='w-24'><SelectValue /></SelectTrigger>
            <SelectContent>{Object.entries(PERIOD_LABEL).map(([k, v]) => <SelectItem key={k} value={k}>{v}</SelectItem>)}</SelectContent>
          </Select>
          <Input className='w-36' type='number' placeholder='上限（美元）' value={max} onChange={(e) => setMax(e.target.value)} />
          <Button variant='outline' disabled={!tag.trim() || !(Number(max) > 0)}
            onClick={async () => { if (await put(tag.trim(), { period, max_usd: Number(max) })) { setTag(''); setMax('') } }}>
            <Plus /> 设置
          </Button>
        </div>
      </CardContent>
    </Card>
  )
}
