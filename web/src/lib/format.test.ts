import { describe, expect, it } from 'vitest'
import { hoursOk, rangeOk } from '@/lib/rules'
import { fmtBytes, fmtCost, fmtMs, fmtTime, fmtTokens, fmtUntil } from '@/lib/format'

// hoursOk 与后端 lg_rules:parse_hours/1 的语义必须成对维护。
describe('hoursOk ↔ lg_rules:parse_hours/1', () => {
  it.each([
    ['09:00-18:00', true],
    ['00:00-24:00', true], // 24:00 作排他结束界 = 全天
    ['22:00-06:00', true], // 跨午夜
    ['0:00-24:00', true],
    ['09:00-24:30', false], // 结束带分钟数的 24 点
    ['24:30-02:00', false], // 起始 24 点
    ['24:00-24:00', false],
    ['09:60-12:00', false],
    ['99:99', false],
    ['9-18', false],
    ['', false],
    [' 09:00-18:00 ', true], // 容忍首尾空白
  ])('%s → %s', (s, want) => {
    expect(hoursOk(s)).toBe(want)
  })
})

describe('rangeOk', () => {
  it.each([
    ['', '', true],
    ['10', '', true],
    ['', '10', true],
    ['10', '20', true],
    ['20', '10', false], // 下限 > 上限
    ['10', '10', true],
  ])('%s ~ %s → %s', (min, max, want) => {
    expect(rangeOk({ min_tokens: min, max_tokens: max })).toBe(want)
  })
})

describe('format', () => {
  it('fmtTime：zh-CN 24 小时制，空值为 —', () => {
    expect(fmtTime(null)).toBe('—')
    expect(fmtTime(0)).toBe('—')
    // 固定时刻：2025-11-12 13:26:40 UTC
    expect(fmtTime(Date.UTC(2025, 10, 12, 13, 26, 40))).toMatch(/^\d{4}\/\d{1,2}\/\d{1,2} \d{2}:\d{2}:\d{2}$/)
  })

  it('fmtTokens 缩写', () => {
    expect(fmtTokens(0)).toBe('0')
    expect(fmtTokens(1500)).toBe('1,500') // 1e4 以下不缩写
    expect(fmtTokens(15_000)).toBe('15.0K')
    expect(fmtTokens(2_500_000)).toBe('2.50M')
    expect(fmtTokens(3_000_000_000)).toBe('3.00B')
  })

  it('fmtCost 去尾零', () => {
    expect(fmtCost(0)).toBe('$0')
    expect(fmtCost(10)).toBe('$10')
    expect(fmtCost(0.25)).toBe('$0.25')
    expect(fmtCost(0.001)).toBe('$0.001')
  })

  it('fmtMs / fmtBytes / fmtUntil', () => {
    expect(fmtMs(999)).toBe('999ms')
    expect(fmtMs(1500)).toBe('1.50s')
    expect(fmtBytes(512)).toBe('512 B')
    expect(fmtBytes(2048)).toBe('2.0 KB')
    const now = Date.UTC(2025, 0, 1, 0, 0, 0)
    expect(fmtUntil(now + 50 * 60000, now)).toBe('50分')
    expect(fmtUntil(now + 3 * 3600000 + 20 * 60000, now)).toBe('3小时20分')
    expect(fmtUntil(now + 51 * 1440 * 60000, now)).toBe('51天0小时')
    expect(fmtUntil(null, now)).toBe('—')
  })
})
