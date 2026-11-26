import { useSyncExternalStore } from 'react'
import { getLang, setLang, subscribeLang, type Lang } from '@/i18n'

/** 当前界面语言（随切换重渲染）与切换函数 */
export function useLang(): [Lang, (l: Lang) => void] {
  return [useSyncExternalStore(subscribeLang, getLang, getLang), setLang]
}
