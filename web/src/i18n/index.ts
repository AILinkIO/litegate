// 界面多语言：源码里直接写中文原文作键（gettext 风格），英文译文放 i18n/en/*.ts。
//
//   t('共 {n} 条', { n })     渲染期翻译，{name} 占位符插值
//   tk('仪表盘')               只标记、不翻译（模块顶层常量用），渲染时再 t(label)
//   t('关闭@@off')            同一中文在不同语境要不同译文时加 @@语境，中文只显示 @@ 前的部分
//
// 规则：模块顶层不要调用 t()（语言切换后不会重新求值），常量表里用 tk() 标记原文。
// 切换语言时 I18nProvider 会重挂整棵树，所有 t() 按新语言重新求值。

export type Lang = 'zh' | 'en'
export const LANGS: { value: Lang; label: string }[] = [
  { value: 'zh', label: '简体中文' },
  { value: 'en', label: 'English' },
]

type Vars = Record<string, string | number>
/** 译文：字符串（可含 {name} 占位符），或按变量生成（处理英文复数等） */
export type Translation = string | ((v: Vars) => string)
export type Dict = Record<string, Translation>

const STORAGE_KEY = 'litegate-lang'

const modules = import.meta.glob<{ default: Dict }>('./en/*.ts', { eager: true })
export const en: Dict = Object.assign({}, ...Object.values(modules).map((m) => m.default))

function detect(): Lang {
  if (typeof window === 'undefined') return 'zh'
  try {
    const saved = window.localStorage.getItem(STORAGE_KEY)
    if (saved === 'zh' || saved === 'en') return saved
  } catch {
    /* 隐私模式下 localStorage 可能不可用 */
  }
  const nav = window.navigator?.languages?.[0] ?? window.navigator?.language ?? ''
  return nav.toLowerCase().startsWith('zh') ? 'zh' : 'en'
}

let current: Lang = detect()
const listeners = new Set<() => void>()

if (typeof document !== 'undefined') document.documentElement.lang = current === 'zh' ? 'zh-CN' : 'en'

export function getLang(): Lang {
  return current
}

export function setLang(lang: Lang) {
  if (lang === current) return
  current = lang
  try {
    window.localStorage.setItem(STORAGE_KEY, lang)
  } catch {
    /* 忽略 */
  }
  if (typeof document !== 'undefined') document.documentElement.lang = lang === 'zh' ? 'zh-CN' : 'en'
  listeners.forEach((fn) => fn())
}

export function subscribeLang(fn: () => void) {
  listeners.add(fn)
  return () => {
    listeners.delete(fn)
  }
}

/** toLocaleString 等用的 BCP 47 区域 */
export function locale() {
  return current === 'zh' ? 'zh-CN' : 'en-US'
}

/** 发给后端的 Accept-Language */
export function acceptLanguage() {
  return current === 'zh' ? 'zh-CN' : 'en'
}

function interpolate(s: string, vars?: Vars) {
  if (!vars) return s
  return s.replace(/\{(\w+)\}/g, (m, k: string) => (k in vars ? String(vars[k]) : m))
}

const missing = new Set<string>()

/** 翻译：中文原文作键；英文缺译文时回退原文（开发期在控制台提示一次） */
export function t(zh: string, vars?: Vars): string {
  const at = zh.indexOf('@@')
  const text = at < 0 ? zh : zh.slice(0, at)
  if (current === 'zh') return interpolate(text, vars)
  const tr = en[zh] ?? (at < 0 ? undefined : en[text])
  if (tr === undefined) {
    if (import.meta.env?.DEV && /[\u4e00-\u9fff]/.test(zh) && !missing.has(zh)) {
      missing.add(zh)
      console.warn('[i18n] missing en:', zh)
    }
    return interpolate(text, vars)
  }
  return typeof tr === 'function' ? tr(vars ?? {}) : interpolate(tr, vars)
}

/** 只标记待翻译原文（供抽取检查），原样返回；渲染时再 t() */
export function tk<S extends string>(zh: S): S {
  return zh
}
