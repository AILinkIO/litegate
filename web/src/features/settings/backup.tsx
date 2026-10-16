import { useState } from 'react'
import { Download, Save, Trash2, Upload } from 'lucide-react'
import { toast } from 'sonner'
import { api, seg } from '@/lib/api'
import { fmtBytes, fmtTime } from '@/lib/format'
import { useGet, useInvalidate } from '@/lib/query'
import { Alert, AlertDescription } from '@/components/ui/alert'
import { Button } from '@/components/ui/button'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { Field } from '@/components/form-field'
import { Segmented } from '@/components/segmented'

type Stats = Record<string, { new: number; overwritten: number; deleted: number }>

const LABEL: Record<string, string> = {
  credentials: '上游凭证', routes: '路由', api_keys: 'API Key', limits: '限额', budgets: '预算',
  model_overlays: '模型目录覆盖', settings: '运行参数', users: '用户', alert_channels: '告警渠道', alert_rules: '告警规则',
  middleware: '中间件',
}

function ExportDialog({ onClose }: { onClose: () => void }) {
  const [pass, setPass] = useState('')
  const [pass2, setPass2] = useState('')
  const [busy, setBusy] = useState(false)
  const run = async () => {
    setBusy(true)
    try {
      const data = await api.post<unknown>('/config/export', { passphrase: pass })
      const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' })
      const a = document.createElement('a')
      a.href = URL.createObjectURL(blob)
      a.download = `litegate-config-${new Date().toISOString().slice(0, 10)}.json`
      a.click()
      URL.revokeObjectURL(a.href)
      toast.success('已导出')
      onClose()
    } catch (e) {
      toast.error((e as Error).message)
    } finally {
      setBusy(false)
    }
  }
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className='sm:max-w-sm'>
        <DialogHeader>
          <DialogTitle>导出配置</DialogTitle>
          <DialogDescription>上游 API Key 会用该口令加密后写入文件，导入时需要同一口令。请妥善保管口令，丢失后文件中的 Key 无法恢复。</DialogDescription>
        </DialogHeader>
        <div className='grid gap-4'>
          <Field label='口令' hint='至少 8 位'><Input type='password' autoFocus value={pass} onChange={(e) => setPass(e.target.value)} /></Field>
          <Field label='确认口令' error={pass2 !== '' && pass !== pass2 ? '两次输入不一致' : undefined}>
            <Input type='password' value={pass2} onChange={(e) => setPass2(e.target.value)} />
          </Field>
        </div>
        <DialogFooter>
          <Button variant='outline' onClick={onClose}>取消</Button>
          <Button onClick={run} disabled={busy || pass.length < 8 || pass !== pass2}>导出</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function ImportDialog({ onClose }: { onClose: () => void }) {
  const [data, setData] = useState<unknown>(null)
  const [fileName, setFileName] = useState('')
  const [pass, setPass] = useState('')
  const [mode, setMode] = useState<'merge' | 'replace'>('merge')
  const [preview, setPreview] = useState<Stats | null>(null)
  const [busy, setBusy] = useState(false)

  const pick = async (f: File | undefined) => {
    setPreview(null)
    if (!f) return
    try {
      setData(JSON.parse(await f.text()))
      setFileName(f.name)
    } catch {
      toast.error('文件不是有效的 JSON')
    }
  }

  const call = async (dryRun: boolean) => {
    setBusy(true)
    try {
      const stats = await api.post<Stats>('/config/import', { data, passphrase: pass, mode, dry_run: dryRun })
      if (dryRun) {
        setPreview(stats)
      } else {
        toast.success('导入完成')
        onClose()
        setTimeout(() => window.location.reload(), 300)
      }
    } catch (e) {
      toast.error((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className='sm:max-w-lg'>
        <DialogHeader><DialogTitle>导入配置</DialogTitle></DialogHeader>
        <div className='grid gap-4'>
          <div className='flex items-center gap-3'>
            <Button variant='outline' asChild>
              <label className='cursor-pointer'>
                <Upload /> 选择文件
                <input hidden type='file' accept='application/json,.json' onChange={(e) => pick(e.target.files?.[0])} />
              </label>
            </Button>
            <span className='truncate text-sm text-muted-foreground'>{fileName || '未选择'}</span>
          </div>
          <Field label='口令'><Input type='password' value={pass} onChange={(e) => { setPass(e.target.value); setPreview(null) }} /></Field>
          <Field label='方式' hint={mode === 'merge' ? '同 id / 名称覆盖，保留本地其他配置' : '清空本地配置后导入'}>
            <Segmented value={mode} onChange={(v) => { setMode(v); setPreview(null) }}
              options={[{ value: 'merge', label: '合并' }, { value: 'replace', label: '替换' }]} />
          </Field>
          {mode === 'replace' && (
            <Alert variant='destructive'><AlertDescription>替换会删除本地所有凭证、路由、API Key、限额、预算、目录覆盖与运行参数（文件中没有用户时保留现有用户）。</AlertDescription></Alert>
          )}
          {preview && (
            <Table>
              <TableHeader>
                <TableRow className='[&>th]:text-xs [&>th]:text-muted-foreground'>
                  <TableHead>对象</TableHead><TableHead className='text-end'>新增</TableHead><TableHead className='text-end'>覆盖</TableHead><TableHead className='text-end'>删除</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {Object.entries(preview).map(([k, v]) => (
                  <TableRow key={k} className='num'>
                    <TableCell>{LABEL[k] ?? k}</TableCell>
                    <TableCell className='text-end'>{v.new}</TableCell>
                    <TableCell className='text-end'>{v.overwritten}</TableCell>
                    <TableCell className={v.deleted ? 'text-end text-destructive' : 'text-end'}>{v.deleted}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </div>
        <DialogFooter>
          <Button variant='outline' onClick={onClose}>取消</Button>
          {preview
            ? <Button variant={mode === 'replace' ? 'destructive' : 'default'} onClick={() => call(false)} disabled={busy}>确认导入</Button>
            : <Button onClick={() => call(true)} disabled={busy || !data || pass.length < 8}>预览</Button>}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

export function ConfigBackup() {
  const [open, setOpen] = useState<'export' | 'import' | null>(null)
  return (
    <div className='flex flex-wrap items-center gap-4 rounded-xl border bg-card px-5 py-4'>
      <div className='min-w-0 flex-1 basis-72'>
        <div className='font-semibold'>手动导出 / 导入</div>
        <p className='text-sm text-muted-foreground'>导出凭证、路由、API Key、限额、预算、目录覆盖、运行参数、用户与告警配置，用于备份或迁移到另一台机器（日志与用量不在其中）</p>
      </div>
      <div className='flex gap-2'>
        <Button variant='outline' onClick={() => setOpen('export')}><Download /> 导出</Button>
        <Button variant='outline' onClick={() => setOpen('import')}><Upload /> 导入</Button>
      </div>
      {open === 'export' && <ExportDialog onClose={() => setOpen(null)} />}
      {open === 'import' && <ImportDialog onClose={() => setOpen(null)} />}
    </div>
  )
}

interface BackupFile { file: string; size: number; mtime: number }
interface BackupsStatus {
  backups: BackupFile[]
  status: { at: number; ok: boolean; file?: string; size?: number; error?: string } | null
  enabled: boolean
}

export function AutoBackupCard() {
  const q = useGet<BackupsStatus>('/backups')
  const invalidate = useInvalidate()
  const [busy, setBusy] = useState(false)
  const run = async () => {
    setBusy(true)
    try {
      const r = await api.post<{ file: string; size: number }>('/backups', {})
      toast.success(`已备份：${r.file}（${fmtBytes(r.size)}）`)
      await invalidate('/backups')
    } catch (e) {
      toast.error((e as Error).message)
    } finally {
      setBusy(false)
    }
  }
  const del = async (file: string) => {
    try {
      await api.del(`/backups/${seg(file)}`)
      await invalidate('/backups')
    } catch (e) {
      toast.error((e as Error).message)
    }
  }
  const s = q.data?.status
  return (
    <div className='rounded-xl border bg-card'>
      <div className='flex flex-wrap items-center justify-between gap-3 px-5 py-4'>
        <div className='min-w-0 flex-1 basis-72'>
          <div className='font-semibold'>自动备份</div>
          <p className='text-sm text-muted-foreground'>
            定期把配置（含加密的 Key）快照到服务器的 backups/ 目录；间隔与保留份数在「参数 → 配置备份」中设置，
            口令建议用环境变量 LITEGATE_BACKUP_PASSPHRASE 配置
          </p>
        </div>
        <Button variant='outline' onClick={run} disabled={busy}><Save /> {busy ? '备份中…' : '立即备份'}</Button>
      </div>
      <Table>
        <TableHeader>
          <TableRow className='[&>th]:h-9 [&>th]:text-xs [&>th]:text-muted-foreground'>
            <TableHead className='ps-5'>文件</TableHead><TableHead className='text-end'>大小</TableHead>
            <TableHead className='text-end'>时间</TableHead><TableHead className='pe-5'></TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {(q.data?.backups ?? []).map((b) => (
            <TableRow key={b.file} className='num'>
              <TableCell className='ps-5 font-mono text-[13px]'>{b.file}</TableCell>
              <TableCell className='text-end'>{fmtBytes(b.size)}</TableCell>
              <TableCell className='text-end'>{fmtTime(b.mtime)}</TableCell>
              <TableCell className='pe-5 text-end'>
                <Button variant='ghost' size='icon' aria-label='删除备份' onClick={() => del(b.file)}><Trash2 className='size-4' /></Button>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
      <p className='border-t px-5 py-3 text-sm text-muted-foreground'>
        {!q.data?.enabled
          ? '自动备份未开启：在「参数 → 配置备份」中打开 backup_enabled 并设置口令'
          : s
            ? s.ok
              ? `最近备份：${fmtTime(s.at)}，${s.file}（${fmtBytes(s.size ?? 0)}）`
              : `最近备份失败：${fmtTime(s.at)} · ${s.error}`
            : '尚未备份'}
      </p>
    </div>
  )
}
