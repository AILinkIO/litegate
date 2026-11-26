import { Separator } from '@/components/ui/separator'
import { SidebarTrigger } from '@/components/ui/sidebar'
import { Search } from '@/components/search'
import { ThemeSwitch } from '@/components/theme-switch'
import { LanguageSwitch } from '@/components/language-switch'
import { t } from '@/i18n'

/** 顶栏：折叠侧栏、命令面板入口、语言与明暗切换 */
export function Header() {
  return (
    <header className='sticky top-0 z-40 flex h-14 shrink-0 items-center gap-3 border-b bg-background/85 px-4 backdrop-blur-md'>
      <SidebarTrigger className='-ms-1' />
      <Separator orientation='vertical' className='h-5' />
      <Search placeholder={t('搜索页面…')} />
      <div className='ms-auto flex items-center gap-1'>
        <LanguageSwitch />
        <ThemeSwitch />
      </div>
    </header>
  )
}
