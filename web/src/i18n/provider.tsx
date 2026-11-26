import { Fragment, useEffect, type ReactNode } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { subscribeLang } from '@/i18n'
import { useLang } from '@/i18n/use-lang'

/** 语言切换后重挂子树（所有 t() 重新求值），并让查询重新拉取（后端叙述、接口文档按语言返回） */
export function I18nProvider({ children }: { children: ReactNode }) {
  const [lang] = useLang()
  const qc = useQueryClient()
  useEffect(() => subscribeLang(() => void qc.invalidateQueries()), [qc])
  return <Fragment key={lang}>{children}</Fragment>
}
