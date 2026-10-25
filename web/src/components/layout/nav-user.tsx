import { useState } from 'react'
import { ChevronsUpDown, KeyRound, LogOut, UserRound } from 'lucide-react'
import { useAuth } from '@/context/auth-context'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import { SidebarMenu, SidebarMenuButton, SidebarMenuItem, useSidebar } from '@/components/ui/sidebar'
import { PasswordDialog } from '@/components/password-dialog'

/** 侧栏底部：当前用户；开启控制台登录时可修改密码、退出 */
export function NavUser() {
  const { user, logout } = useAuth()
  const { isMobile } = useSidebar()
  const [pwOpen, setPwOpen] = useState(false)
  if (!user) return null
  const authEnabled = user.auth_enabled !== false
  const role = user.role === 'admin' ? '管理员' : '用户'
  const name = authEnabled ? user.username : '本机管理员'

  return (
    <>
      <SidebarMenu>
        <SidebarMenuItem>
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <SidebarMenuButton size='lg' className='data-[state=open]:bg-sidebar-accent'>
                <div className='flex size-8 shrink-0 items-center justify-center rounded-lg bg-secondary text-subtle-foreground'>
                  <UserRound className='size-4' />
                </div>
                <div className='grid flex-1 text-start leading-tight'>
                  <span className='truncate font-medium'>{name}</span>
                  <span className='truncate text-xs text-muted-foreground'>{authEnabled ? role : '未开启控制台登录'}</span>
                </div>
                <ChevronsUpDown className='ms-auto size-4 text-muted-foreground' />
              </SidebarMenuButton>
            </DropdownMenuTrigger>
            <DropdownMenuContent className='min-w-52 rounded-lg' side={isMobile ? 'bottom' : 'right'} align='end' sideOffset={4}>
              <DropdownMenuLabel className='font-normal text-muted-foreground'>
                {name}（{role}）
              </DropdownMenuLabel>
              {authEnabled && (
                <>
                  <DropdownMenuSeparator />
                  <DropdownMenuItem onClick={() => setPwOpen(true)}>
                    <KeyRound /> 修改密码
                  </DropdownMenuItem>
                  <DropdownMenuItem variant='destructive' onClick={() => logout()}>
                    <LogOut /> 退出登录
                  </DropdownMenuItem>
                </>
              )}
            </DropdownMenuContent>
          </DropdownMenu>
        </SidebarMenuItem>
      </SidebarMenu>
      <PasswordDialog open={pwOpen} onOpenChange={setPwOpen} />
    </>
  )
}
