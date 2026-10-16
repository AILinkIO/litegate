import { Link, useLocation } from '@tanstack/react-router'
import { useAuth } from '@/context/auth-context'
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarGroupLabel,
  SidebarHeader,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarRail,
  useSidebar,
} from '@/components/ui/sidebar'
import { Logo } from '@/assets/logo'
import { visibleNav } from './nav'
import { NavUser } from './nav-user'

export function AppSidebar() {
  const { user } = useAuth()
  const { setOpenMobile } = useSidebar()
  const pathname = useLocation({ select: (l) => l.pathname })
  const groups = visibleNav(user?.role === 'admin', user?.auth_enabled !== false)
  const active = (url: string) => (url === '/' ? pathname === '/' : pathname === url || pathname.startsWith(`${url}/`))

  return (
    <Sidebar collapsible='icon' variant='sidebar'>
      <SidebarHeader>
        <SidebarMenu>
          <SidebarMenuItem>
            <SidebarMenuButton size='lg' asChild className='hover:bg-transparent'>
              <Link to='/'>
                <div className='flex aspect-square size-8 items-center justify-center rounded-lg bg-primary text-primary-foreground'>
                  <Logo className='size-5' />
                </div>
                <div className='grid flex-1 text-start leading-tight'>
                  <span className='truncate text-[15px] font-semibold'>LiteGate</span>
                  <span className='truncate text-xs text-muted-foreground'>LLM 网关</span>
                </div>
              </Link>
            </SidebarMenuButton>
          </SidebarMenuItem>
        </SidebarMenu>
      </SidebarHeader>
      <SidebarContent>
        {groups.map((g) => (
          <SidebarGroup key={g.title}>
            <SidebarGroupLabel>{g.title}</SidebarGroupLabel>
            <SidebarMenu>
              {g.items.map((i) => (
                <SidebarMenuItem key={i.url}>
                  <SidebarMenuButton asChild isActive={active(i.url)} tooltip={i.title}>
                    <Link to={i.url} onClick={() => setOpenMobile(false)}>
                      <i.icon />
                      <span>{i.title}</span>
                    </Link>
                  </SidebarMenuButton>
                </SidebarMenuItem>
              ))}
            </SidebarMenu>
          </SidebarGroup>
        ))}
      </SidebarContent>
      <SidebarFooter>
        <NavUser />
      </SidebarFooter>
      <SidebarRail />
    </Sidebar>
  )
}
