import { useMemo } from 'react'
import { useAuth } from '@/context/auth-context'
import type { ApiKey, Credential, User } from './api'
import { useGet } from './query'

/** id → 显示名：API Key、上游凭证（管理员）、用户（管理员且开启登录） */
export function useNames() {
  const { user } = useAuth()
  const isAdmin = user?.role === 'admin'
  const keys = useGet<ApiKey[]>('/keys')
  const creds = useGet<Credential[]>(isAdmin ? '/credentials' : null)
  const users = useGet<User[]>(isAdmin && user?.auth_enabled !== false ? '/users' : null)
  return useMemo(() => {
    const key = new Map<string, string>([...(keys.data ?? []).map((k): [string, string] => [k.id, k.name]),
      ['playground', 'Playground（控制台）']])
    const cred = new Map((creds.data ?? []).map((c) => [c.id, c]))
    const usr = new Map((users.data ?? []).map((u) => [u.id, u.username]))
    return {
      keys: keys.data ?? [],
      creds: creds.data ?? [],
      key: (id?: string | null) => (id ? key.get(id) ?? id : '—'),
      credName: (id?: string | null) => (id ? cred.get(id)?.name ?? id : '—'),
      cred: (id?: string | null) => (id ? cred.get(id) : undefined),
      user: (id?: string | null) => (id ? usr.get(id) ?? id : '—'),
    }
  }, [keys.data, creds.data, users.data])
}
