import { useCallback } from 'react'
import { useNavigate } from '@tanstack/react-router'
import { Laptop, Moon, Sun } from 'lucide-react'
import { useAuth } from '@/context/auth-context'
import { useSearch } from '@/context/search-provider'
import { useTheme } from '@/context/theme-provider'
import {
  CommandDialog,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
  CommandSeparator,
} from '@/components/ui/command'
import { visibleNav } from './layout/nav'
import { t } from '@/i18n'

/** 命令面板（Ctrl / ⌘ + K）：跳转页面、切换明暗 */
export function CommandMenu() {
  const navigate = useNavigate()
  const { setTheme } = useTheme()
  const { open, setOpen } = useSearch()
  const { user } = useAuth()
  const groups = visibleNav(user?.role === 'admin', user?.auth_enabled !== false)

  const run = useCallback((fn: () => unknown) => {
    setOpen(false)
    fn()
  }, [setOpen])

  return (
    <CommandDialog modal open={open} onOpenChange={setOpen} title={t('命令面板')} description={t('搜索页面或操作')}>
      <CommandInput placeholder={t('输入页面名称…')} />
      <CommandList>
        <CommandEmpty>{t('没有匹配的页面')}</CommandEmpty>
        {groups.map((g) => (
          <CommandGroup key={g.title} heading={t(g.title)}>
            {g.items.map((i) => (
              <CommandItem key={i.url} value={`${t(g.title)} ${t(i.title)} ${i.url}`} onSelect={() => run(() => navigate({ to: i.url }))}>
                <i.icon className='text-muted-foreground' />
                {t(i.title)}
              </CommandItem>
            ))}
          </CommandGroup>
        ))}
        <CommandSeparator />
        <CommandGroup heading={t('外观')}>
          <CommandItem value={`${t('浅色')} light`} onSelect={() => run(() => setTheme('light'))}><Sun /> {t('浅色')}</CommandItem>
          <CommandItem value={`${t('深色')} dark`} onSelect={() => run(() => setTheme('dark'))}><Moon /> {t('深色')}</CommandItem>
          <CommandItem value={`${t('跟随系统')} system`} onSelect={() => run(() => setTheme('system'))}><Laptop /> {t('跟随系统')}</CommandItem>
        </CommandGroup>
      </CommandList>
    </CommandDialog>
  )
}
