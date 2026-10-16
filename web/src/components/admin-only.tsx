import { type ReactNode } from 'react'
import { Navigate } from '@tanstack/react-router'
import { useAuth } from '@/context/auth-context'

/** 仅管理员可访问的页面：其他用户回到仪表盘 */
export function AdminOnly({ children }: { children: ReactNode }) {
  const { user } = useAuth()
  return user?.role === 'admin' ? children : <Navigate to='/' replace />
}
