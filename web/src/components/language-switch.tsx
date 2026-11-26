import { Check, Languages } from 'lucide-react'
import { cn } from '@/lib/utils'
import { LANGS, t } from '@/i18n'
import { useLang } from '@/i18n/use-lang'
import { Button } from '@/components/ui/button'
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from '@/components/ui/dropdown-menu'

/** 界面语言切换（存 localStorage，缺省跟随浏览器） */
export function LanguageSwitch() {
  const [lang, setLang] = useLang()
  return (
    <DropdownMenu modal={false}>
      <DropdownMenuTrigger asChild>
        <Button variant='ghost' size='icon' className='scale-95 rounded-full' title={t('界面语言')}>
          <Languages className='size-[1.2rem]' />
          <span className='sr-only'>{t('界面语言')}</span>
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align='end'>
        {LANGS.map((l) => (
          <DropdownMenuItem key={l.value} onClick={() => setLang(l.value)}>
            {l.label}
            <Check size={14} className={cn('ms-auto', lang !== l.value && 'hidden')} />
          </DropdownMenuItem>
        ))}
      </DropdownMenuContent>
    </DropdownMenu>
  )
}
