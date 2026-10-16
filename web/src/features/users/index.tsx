import { useState } from 'react'
import { KeySquare, Plus, Trash2, UserRound, Wallet } from 'lucide-react'
import { toast } from 'sonner'
import { api, seg, type Role, type User } from '@/lib/api'
import { fmtTime } from '@/lib/format'
import { useGet, useInvalidate } from '@/lib/query'
import { cn } from '@/lib/utils'
import { useAuth } from '@/context/auth-context'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Skeleton } from '@/components/ui/skeleton'
import { Switch } from '@/components/ui/switch'
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip'
import { ConfirmDialog } from '@/components/confirm-dialog'
import { Field } from '@/components/form-field'
import { SimpleSelect } from '@/components/form-controls'
import { BudgetBar, BudgetInputs } from '@/components/limits'
import { budgetDraft, budgetValid, saveBudget } from '@/lib/limits'
import { PageHeader } from '@/components/page'
import { ErrorAlert } from '@/components/query-state'

const ROLES = [{ value: 'admin', label: '管理员' }, { value: 'user', label: '用户' }]

export function Users() {
  const { user: me } = useAuth()
  const q = useGet<User[]>('/users')
  const invalidate = useInvalidate()
  const [creating, setCreating] = useState(false)
  const [resetting, setResetting] = useState<User | null>(null)
  const [deleting, setDeleting] = useState<User | null>(null)
  const [budgeting, setBudgeting] = useState<User | null>(null)

  const update = async (u: User, patch: Partial<User>) => {
    try {
      await api.put(`/users/${seg(u.id)}`, patch)
      await invalidate('/users')
    } catch (e) {
      toast.error((e as Error).message)
    }
  }

  const iconBtn = (label: string, icon: React.ReactNode, onClick: () => void, disabled?: boolean) => (
    <Tooltip>
      <TooltipTrigger asChild>
        <Button variant='ghost' size='icon' aria-label={label} onClick={onClick} disabled={disabled}>{icon}</Button>
      </TooltipTrigger>
      <TooltipContent>{label}</TooltipContent>
    </Tooltip>
  )

  return (
    <>
      <PageHeader title='用户' subtitle='控制台账号：管理员管理全部配置；普通用户只能管理自己的 API Key 并查看自己的用量'
        actions={<Button onClick={() => setCreating(true)}><Plus /> 添加用户</Button>} />
      {q.error && <ErrorAlert message={q.error.message} />}
      {!q.data && !q.error && <Skeleton className='h-40 rounded-xl' />}
      {q.data && (
        <div className='overflow-hidden rounded-xl border bg-card'>
          {q.data.map((u, i) => {
            const self = u.id === me?.id
            return (
              <div key={u.id} className={cn('flex flex-wrap items-center gap-x-6 gap-y-3 px-5 py-3.5', i > 0 && 'border-t', !u.enabled && 'opacity-60')}>
                <div className='flex min-w-0 flex-1 basis-56 items-center gap-3'>
                  <div className='flex size-9 items-center justify-center rounded-full bg-secondary text-subtle-foreground'><UserRound className='size-4' /></div>
                  <div>
                    <div className='font-semibold'>{u.username}{self && <Badge variant='info' className='ms-1.5'>你</Badge>}</div>
                    <div className='text-xs text-muted-foreground'>创建于 {fmtTime(u.created_at)}</div>
                  </div>
                </div>
                <SimpleSelect className='w-28' value={u.role} disabled={self} onChange={(v) => update(u, { role: v as Role })} options={ROLES} />
                <div className='w-48'>{u.budget ? <BudgetBar budget={u.budget} /> : <span className='text-sm text-muted-foreground'>预算不限</span>}</div>
                <div className='ms-auto flex items-center gap-1'>
                  <Switch checked={u.enabled} disabled={self} onCheckedChange={() => update(u, { enabled: !u.enabled })} aria-label='启用' />
                  <span className='ms-2' />
                  {iconBtn('预算（该用户全部 Key 合计）', <Wallet />, () => setBudgeting(u))}
                  {iconBtn('重置密码', <KeySquare />, () => setResetting(u))}
                  {iconBtn('删除', <Trash2 />, () => setDeleting(u), self)}
                </div>
              </div>
            )
          })}
        </div>
      )}
      {creating && <UserDialog onClose={() => setCreating(false)} onSaved={() => invalidate('/users')} />}
      {resetting && <UserDialog user={resetting} onClose={() => setResetting(null)} onSaved={() => invalidate('/users')} />}
      {budgeting && <BudgetDialog user={budgeting} onClose={() => setBudgeting(null)} onSaved={() => invalidate('/users')} />}
      <ConfirmDialog open={deleting !== null} onOpenChange={(o) => !o && setDeleting(null)} title='删除用户' destructive confirmText='删除'
        desc={`确定删除用户「${deleting?.username}」？其 API Key 不会被删除。`}
        handleConfirm={async () => {
          try {
            await api.del(`/users/${seg(deleting!.id)}`)
            toast.success('已删除')
            await invalidate('/users')
          } catch (e) {
            toast.error((e as Error).message)
          }
          setDeleting(null)
        }} />
    </>
  )
}

// 新建用户，或给已有用户重置密码
function UserDialog({ user, onClose, onSaved }: { user?: User; onClose: () => void; onSaved: () => void }) {
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [role, setRole] = useState<Role>('user')
  const [busy, setBusy] = useState(false)
  const save = async () => {
    setBusy(true)
    try {
      if (user) await api.put(`/users/${seg(user.id)}`, { password })
      else await api.post('/users', { username, password, role })
      toast.success(user ? '密码已重置，该用户需重新登录' : '已创建')
      onSaved()
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
        <DialogHeader><DialogTitle>{user ? `重置密码：${user.username}` : '添加用户'}</DialogTitle></DialogHeader>
        <div className='grid gap-4'>
          {!user && (
            <>
              <Field label='用户名' hint='字母、数字、_ . @ -，2–64 位'>
                <Input autoFocus value={username} onChange={(e) => setUsername(e.target.value)} />
              </Field>
              <Field label='角色'><SimpleSelect value={role} onChange={(v) => setRole(v as Role)} options={ROLES} /></Field>
            </>
          )}
          <Field label={user ? '新密码' : '密码'} hint='至少 8 位'>
            <Input type='password' autoComplete='new-password' value={password} onChange={(e) => setPassword(e.target.value)} />
          </Field>
        </div>
        <DialogFooter>
          <Button variant='outline' onClick={onClose}>取消</Button>
          <Button onClick={save} disabled={busy || password.length < 8 || (!user && !username)}>保存</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function BudgetDialog({ user, onClose, onSaved }: { user: User; onClose: () => void; onSaved: () => void }) {
  const [draft, setDraft] = useState(budgetDraft(user.budget))
  const [busy, setBusy] = useState(false)
  const save = async () => {
    setBusy(true)
    try {
      await saveBudget({ type: 'user', user_id: user.id }, draft)
      toast.success('已保存')
      onSaved()
      onClose()
    } catch (e) {
      toast.error((e as Error).message)
    } finally {
      setBusy(false)
    }
  }
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className='sm:max-w-md'>
        <DialogHeader>
          <DialogTitle>预算：{user.username}</DialogTitle>
          <DialogDescription>该用户名下全部 API Key 的花费合计；与 Key 自身的预算同时生效。上限留空即取消预算。</DialogDescription>
        </DialogHeader>
        <BudgetInputs value={draft} onChange={setDraft} />
        {user.budget && <BudgetBar budget={user.budget} />}
        <DialogFooter>
          <Button variant='outline' onClick={onClose}>取消</Button>
          <Button onClick={save} disabled={busy || !budgetValid(draft)}>保存</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
