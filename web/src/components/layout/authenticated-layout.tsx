import { Outlet } from '@tanstack/react-router'
import { getCookie } from '@/lib/cookies'
import { useAuth } from '@/context/auth-context'
import { SearchProvider } from '@/context/search-provider'
import { SidebarInset, SidebarProvider } from '@/components/ui/sidebar'
import { AppSidebar } from '@/components/layout/app-sidebar'
import { Header } from '@/components/layout/header'
import { SkipToMain } from '@/components/skip-to-main'
import { Spinner } from '@/components/spinner'
import { Login } from '@/features/auth/login'

/** 登录后的整体框架；未登录时显示登录页（单机免登录模式下 /auth/me 直接返回本机管理员） */
export function AuthenticatedLayout() {
  const { user, loading } = useAuth()
  if (loading) return <Spinner className='mt-24' />
  if (!user) return <Login />
  const defaultOpen = getCookie('sidebar_state') !== 'false'
  return (
    <SearchProvider>
      <SidebarProvider defaultOpen={defaultOpen}>
        <SkipToMain />
        <AppSidebar />
        <SidebarInset className='min-w-0 bg-background'>
          <Header />
          {user.insecure_exposed && (
            <div className='border-b border-warning/20 bg-warning-soft px-4 py-2 text-sm text-warning md:px-6'>
              控制台当前免登录且 HTTP 服务绑定到非 loopback 地址，任何能访问该地址的人都可管理网关。请开启登录或限制访问来源。
            </div>
          )}
          <main id='content' className='mx-auto w-full max-w-[1400px] flex-1 px-4 py-6 md:px-6'>
            <Outlet />
          </main>
        </SidebarInset>
      </SidebarProvider>
    </SearchProvider>
  )
}
