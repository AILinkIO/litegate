import { ChevronLeft, ChevronRight } from 'lucide-react'
import { fmtInt } from '@/lib/format'
import { Button } from '@/components/ui/button'
import { SimpleSelect } from '@/components/form-controls'
import { t } from '@/i18n'

/** 偏移分页：共几条、每页条数、上一页 / 下一页 */
export function Pager({ total, page, size, onPage, onSize, sizes = [25, 50, 100] }: {
  total: number
  page: number
  size: number
  onPage: (p: number) => void
  onSize: (s: number) => void
  sizes?: number[]
}) {
  const pages = Math.max(1, Math.ceil(total / size))
  return (
    <div className='flex items-center justify-end gap-3 border-t px-4 py-2 text-sm text-muted-foreground'>
      <span>{t('共 {n} 条', { n: fmtInt(total) })}</span>
      <span className='flex items-center gap-1.5'>{t('每页')}
        <SimpleSelect className='h-8 w-20' value={String(size)} onChange={(v) => onSize(Number(v))}
          options={sizes.map((s) => ({ value: String(s), label: String(s) }))} />
      </span>
      <span className='num'>{page + 1} / {pages}</span>
      <Button variant='ghost' size='icon' className='size-8' disabled={page === 0} onClick={() => onPage(page - 1)} aria-label={t('上一页')}><ChevronLeft /></Button>
      <Button variant='ghost' size='icon' className='size-8' disabled={page + 1 >= pages} onClick={() => onPage(page + 1)} aria-label={t('下一页')}><ChevronRight /></Button>
    </div>
  )
}
