import {
  Activity,
  BellRing,
  BookOpen,
  ChartNoAxesCombined,
  HeartPulse,
  KeyRound,
  LayoutDashboard,
  type LucideIcon,
  MessagesSquare,
  Network,
  PlugZap,
  Puzzle,
  Route,
  ScrollText,
  Server,
  SlidersHorizontal,
  Users,
  Waypoints,
} from 'lucide-react'
import { tk } from '@/i18n'

export interface NavItem {
  title: string
  url: string
  icon: LucideIcon
  admin?: boolean // 仅管理员
  auth?: boolean // 仅开启控制台登录时
}

export interface NavGroup {
  title: string
  items: NavItem[]
}

/** 侧栏与命令面板共用的导航（title 是 tk() 标记的原文，渲染时 t(title)） */
export const navGroups: NavGroup[] = [
  {
    title: tk('概览'),
    items: [
      { title: tk('仪表盘'), url: '/', icon: LayoutDashboard },
      { title: tk('路由视图'), url: '/live', icon: Waypoints, admin: true },
      { title: 'Playground', url: '/playground', icon: MessagesSquare, admin: true },
    ],
  },
  {
    title: tk('网关配置'),
    items: [
      { title: tk('模型目录'), url: '/models', icon: Network, admin: true },
      { title: tk('上游凭证'), url: '/credentials', icon: Server, admin: true },
      { title: tk('路由表'), url: '/routes', icon: Route, admin: true },
      { title: tk('上游健康'), url: '/health', icon: HeartPulse, admin: true },
      { title: tk('中间件'), url: '/middleware', icon: Puzzle, admin: true },
      { title: tk('告警'), url: '/alerts', icon: BellRing, admin: true },
      { title: 'API Key', url: '/keys', icon: KeyRound },
      { title: tk('接入指南'), url: '/integrations', icon: PlugZap },
    ],
  },
  {
    title: tk('数据'),
    items: [
      { title: tk('请求日志'), url: '/logs', icon: ScrollText },
      { title: tk('会话'), url: '/sessions', icon: Activity },
      { title: tk('用量'), url: '/usage', icon: ChartNoAxesCombined },
    ],
  },
  {
    title: tk('系统'),
    items: [
      { title: tk('用户'), url: '/users', icon: Users, admin: true, auth: true },
      { title: tk('运行参数'), url: '/settings', icon: SlidersHorizontal, admin: true },
      { title: tk('接口文档'), url: '/docs', icon: BookOpen },
    ],
  },
]

/** 当前用户可见的导航 */
export function visibleNav(isAdmin: boolean, authEnabled: boolean): NavGroup[] {
  return navGroups
    .map((g) => ({ ...g, items: g.items.filter((i) => (!i.admin || isAdmin) && (!i.auth || authEnabled)) }))
    .filter((g) => g.items.length > 0)
}

