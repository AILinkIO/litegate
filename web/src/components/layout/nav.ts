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

/** 侧栏与命令面板共用的导航 */
export const navGroups: NavGroup[] = [
  {
    title: '概览',
    items: [
      { title: '仪表盘', url: '/', icon: LayoutDashboard },
      { title: '路由视图', url: '/live', icon: Waypoints, admin: true },
      { title: 'Playground', url: '/playground', icon: MessagesSquare, admin: true },
    ],
  },
  {
    title: '网关配置',
    items: [
      { title: '模型目录', url: '/models', icon: Network, admin: true },
      { title: '上游凭证', url: '/credentials', icon: Server, admin: true },
      { title: '路由表', url: '/routes', icon: Route, admin: true },
      { title: '上游健康', url: '/health', icon: HeartPulse, admin: true },
      { title: '中间件', url: '/middleware', icon: Puzzle, admin: true },
      { title: '告警', url: '/alerts', icon: BellRing, admin: true },
      { title: 'API Key', url: '/keys', icon: KeyRound },
      { title: '接入指南', url: '/integrations', icon: PlugZap },
    ],
  },
  {
    title: '数据',
    items: [
      { title: '请求日志', url: '/logs', icon: ScrollText },
      { title: '会话', url: '/sessions', icon: Activity },
      { title: '用量', url: '/usage', icon: ChartNoAxesCombined },
    ],
  },
  {
    title: '系统',
    items: [
      { title: '用户', url: '/users', icon: Users, admin: true, auth: true },
      { title: '运行参数', url: '/settings', icon: SlidersHorizontal, admin: true },
      { title: '接口文档', url: '/docs', icon: BookOpen },
    ],
  },
]

/** 当前用户可见的导航 */
export function visibleNav(isAdmin: boolean, authEnabled: boolean): NavGroup[] {
  return navGroups
    .map((g) => ({ ...g, items: g.items.filter((i) => (!i.admin || isAdmin) && (!i.auth || authEnabled)) }))
    .filter((g) => g.items.length > 0)
}

