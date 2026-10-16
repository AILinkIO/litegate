/** JSON 对象编辑框：parse 返回 { ok, value }（空文本为 null） */
export function parseJsonObject(text: string): { ok: boolean; value: Record<string, unknown> | null } {
  if (!text.trim()) return { ok: true, value: null }
  try {
    const v = JSON.parse(text)
    return v && typeof v === 'object' && !Array.isArray(v) ? { ok: true, value: v } : { ok: false, value: null }
  } catch {
    return { ok: false, value: null }
  }
}
