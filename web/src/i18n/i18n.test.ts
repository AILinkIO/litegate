/// <reference types="node" />
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { en, setLang, t } from '@/i18n'

// 抽取检查：源码里的中文必须都包在 t('…') / tk('…') 里，且每个键都有英文译文。
const SRC = join(__dirname, '..')
const CJK = /[㐀-鿿＀-￯　-〿]/
const SKIP = [/^i18n\//, /\.test\.tsx?$/, /^routeTree\.gen\.ts$/, /^assets\/vendors\//]
const CALL = /\btk?\(\s*(['"`])((?:\\.|(?!\1)[^\\])*)\1/g

function files(dir: string): string[] {
  return readdirSync(dir).flatMap((f) => {
    const p = join(dir, f)
    if (statSync(p).isDirectory()) return files(p)
    return /\.tsx?$/.test(f) ? [p] : []
  })
}

/** 去掉注释（行注释只认行首或空白后的 //，避开 URL） */
function stripComments(src: string) {
  return src.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' ')).replace(/(^|\s)\/\/.*$/gm, '$1')
}

const sources = files(SRC)
  .map((p) => ({ path: relative(SRC, p), code: stripComments(readFileSync(p, 'utf8')) }))
  .filter((f) => !SKIP.some((re) => re.test(f.path)))

describe('i18n 抽取', () => {
  it('中文都在 t()/tk() 里', () => {
    const bad: string[] = []
    for (const f of sources) {
      f.code.split('\n').forEach((line, i) => {
        if (CJK.test(line.replace(CALL, ''))) bad.push(`${f.path}:${i + 1}: ${line.trim()}`)
      })
    }
    expect(bad).toEqual([])
  })

  it('每个键都有英文译文，且不用 ${} 拼接', () => {
    const bad: string[] = []
    for (const f of sources) {
      for (const m of f.code.matchAll(CALL)) {
        const key = m[2].replace(/\\(['"`\\])/g, '$1').replace(/\\n/g, '\n')
        if (!CJK.test(key)) continue
        if (m[1] === '`' && key.includes('${')) bad.push(`${f.path}: 模板插值 ${key}`)
        else if (!(key in en)) bad.push(`${f.path}: 缺译文 ${JSON.stringify(key)}`)
      }
    }
    expect(bad).toEqual([])
  })

  it('同一个键在各词典文件里译文一致', () => {
    const seen = new Map<string, Set<string>>()
    for (const [file, mod] of Object.entries(import.meta.glob<{ default: Record<string, unknown> }>('./en/*.ts', { eager: true }))) {
      for (const [k, v] of Object.entries(mod.default)) {
        if (typeof v !== 'string') continue
        if (!seen.has(k)) seen.set(k, new Set())
        seen.get(k)!.add(`${v}（${file}）`)
      }
    }
    const bad = [...seen].filter(([, vs]) => new Set([...vs].map((x) => x.replace(/（[^（]*）$/, ''))).size > 1).map(([k, vs]) => `${k}: ${[...vs].join(' / ')}`)
    expect(bad).toEqual([])
  })

  it('译文里的占位符与原文一致', () => {
    const names = (s: string) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort().join(',')
    const bad = Object.entries(en)
      .filter(([k, v]) => typeof v === 'string' && names(k) !== names(v))
      .map(([k, v]) => `${k} → ${v as string}`)
    expect(bad).toEqual([])
  })
})

describe('t()', () => {
  afterEach(() => setLang('zh'))
  it('中文原样 + 插值，英文查表，缺译文回退', () => {
    expect(t('共 {n} 条', { n: 3 })).toBe('共 3 条')
    setLang('en')
    expect(t('界面语言')).toBe('Language')
    expect(t('没有这个键 {x}', { x: 1 })).toBe('没有这个键 1')
    expect(t('关闭@@off')).toBe('Off')
    expect(t('关闭')).toBe('Close')
    expect(t('没有这个键@@ctx')).toBe('没有这个键')
    setLang('zh')
    expect(t('关闭@@off')).toBe('关闭')
  })
})
