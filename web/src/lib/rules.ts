// 规则编辑器的纯校验逻辑。语义必须与后端 lg_rules.erl 保持一致：
// hoursOk 与 lg_rules:parse_hours/1 的语义保持一致，改任一端时对照测试另一端。

const HOURS_RE = /^\d{1,2}:\d{2}-\d{1,2}:\d{2}$/

/** 时段格式与范围：起始小时 0-23，结束小时 0-24（24 仅允许 24:00 作排他结束界），分钟 0-59 */
export function hoursOk(s: string): boolean {
  const m = HOURS_RE.exec(s.trim())
  if (!m) return false
  const [a, b, c, d] = s.trim().split(/[-:]/).map(Number)
  return a < 24 && c <= 24 && b < 60 && d < 60 && (c < 24 || d === 0)
}

/** tokens 范围：留空任一侧表示不限，否则下限 ≤ 上限 */
export function rangeOk(r: { min_tokens: string; max_tokens: string }): boolean {
  const min = r.min_tokens.trim()
  const max = r.max_tokens.trim()
  return min === '' || max === '' || Number(min) <= Number(max)
}
