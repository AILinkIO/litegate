import { useState } from 'react'
import { toast } from 'sonner'
import { api } from '@/lib/api'
import { useAuth } from '@/context/auth-context'
import { Button } from '@/components/ui/button'
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Field } from '@/components/form-field'
import { Input } from '@/components/ui/input'

export function PasswordDialog({ open, onOpenChange }: { open: boolean; onOpenChange: (v: boolean) => void }) {
  const [pw, setPw] = useState('')
  const [pw2, setPw2] = useState('')
  const [busy, setBusy] = useState(false)
  const { logout } = useAuth()
  const mismatch = pw2 !== '' && pw !== pw2

  const save = async () => {
    setBusy(true)
    try {
      await api.put('/auth/password', { password: pw })
      toast.success('密码已修改，请重新登录')
      onOpenChange(false)
      await logout()
    } catch (e) {
      toast.error((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className='sm:max-w-sm'>
        <DialogHeader>
          <DialogTitle>修改密码</DialogTitle>
        </DialogHeader>
        <div className='grid gap-4'>
          <Field label='新密码' hint='至少 8 位'>
            <Input type='password' autoFocus value={pw} onChange={(e) => setPw(e.target.value)} />
          </Field>
          <Field label='确认新密码' error={mismatch ? '两次输入不一致' : undefined}>
            <Input type='password' value={pw2} onChange={(e) => setPw2(e.target.value)} aria-invalid={mismatch} />
          </Field>
        </div>
        <DialogFooter>
          <Button variant='outline' onClick={() => onOpenChange(false)}>取消</Button>
          <Button onClick={save} disabled={busy || pw.length < 8 || pw !== pw2}>保存</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
