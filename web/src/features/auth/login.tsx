import { useState, type FormEvent } from 'react'
import { useAuth } from '@/context/auth-context'
import { Alert, AlertDescription } from '@/components/ui/alert'
import { Button } from '@/components/ui/button'
import { Card, CardContent } from '@/components/ui/card'
import { Field } from '@/components/form-field'
import { Input } from '@/components/ui/input'
import { Logo } from '@/assets/logo'

export function Login() {
  const { login } = useAuth()
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const submit = async (e: FormEvent) => {
    e.preventDefault()
    setBusy(true)
    setError(null)
    try {
      await login(username, password)
    } catch (err) {
      setError((err as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className='flex min-h-svh items-center justify-center p-4'>
      <div className='w-full max-w-sm'>
        <div className='mb-6 flex items-center justify-center gap-2.5'>
          <div className='flex size-9 items-center justify-center rounded-lg bg-primary text-primary-foreground'>
            <Logo className='size-5' />
          </div>
          <div className='leading-tight'>
            <div className='text-lg font-semibold'>LiteGate</div>
            <div className='text-xs text-muted-foreground'>LLM 网关控制台</div>
          </div>
        </div>
        <Card>
          <CardContent>
            <form onSubmit={submit} className='grid gap-4'>
              {error && (
                <Alert variant='destructive'>
                  <AlertDescription>{error}</AlertDescription>
                </Alert>
              )}
              <Field label='用户名'>
                <Input autoFocus autoComplete='username' value={username} onChange={(e) => setUsername(e.target.value)} />
              </Field>
              <Field label='密码'>
                <Input type='password' autoComplete='current-password' value={password} onChange={(e) => setPassword(e.target.value)} />
              </Field>
              <Button type='submit' className='mt-1 w-full' disabled={busy || !username || !password}>登录</Button>
            </form>
          </CardContent>
        </Card>
      </div>
    </div>
  )
}
