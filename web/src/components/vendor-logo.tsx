import { cn } from '@/lib/utils'

// 构建时把图标 SVG 作为文本内联（单色图标用 currentColor，随明暗切换）
const svgs = import.meta.glob('../assets/vendors/*.svg', { query: '?raw', import: 'default', eager: true }) as Record<string, string>
const icon = (name: string) => svgs[`../assets/vendors/${name}.svg`]

// 按顺序匹配：凭证的 provider、base_url 主机、模型名、客户端名中出现的关键词 → 图标
const RULES: [RegExp, string, string][] = [
  [/claude[-_ ]?code/i, 'claudecode-color', 'Claude Code'],
  [/codex/i, 'codex-color', 'Codex'],
  [/opencode/i, 'opencode', 'OpenCode'],
  [/gemini[-_ ]?cli/i, 'geminicli-color', 'Gemini CLI'],
  [/cline/i, 'cline', 'Cline'],
  [/cursor/i, 'cursor', 'Cursor'],
  [/deepseek/i, 'deepseek-color', 'DeepSeek'],
  [/minimax|minimaxi/i, 'minimax-color', 'MiniMax'],
  [/bigmodel|zhipu|z\.ai|\bglm/i, 'zhipu-color', '智谱'],
  [/kimi/i, 'kimi', 'Kimi'],
  [/moonshot/i, 'moonshot', 'Moonshot'],
  [/dashscope|bailian|maas\.aliyuncs|token-plan/i, 'bailian-color', '百炼'],
  [/qwen/i, 'qwen-color', 'Qwen'],
  [/aliyun|alibaba/i, 'alibabacloud-color', '阿里云'],
  [/openrouter/i, 'openrouter', 'OpenRouter'],
  [/siliconflow|siliconcloud/i, 'siliconcloud-color', 'SiliconFlow'],
  [/volces|volcengine|ark\./i, 'volcengine-color', '火山引擎'],
  [/doubao/i, 'doubao-color', '豆包'],
  [/anthropic|claude/i, 'anthropic', 'Anthropic'],
  [/openai|gpt-|\bo[1-9]\b/i, 'openai', 'OpenAI'],
  [/gemini|googleapis|google/i, 'gemini-color', 'Gemini'],
  [/mistral/i, 'mistral-color', 'Mistral'],
  [/x\.ai|grok/i, 'grok', 'Grok'],
  [/groq/i, 'groq', 'Groq'],
  [/ollama/i, 'ollama', 'Ollama'],
  [/new-?api|one-?api/i, 'newapi-color', 'New API'],
]

/** 从若干线索（provider、base_url、模型名、客户端名）找图标 */
function vendorOf(...hints: (string | null | undefined)[]): { icon: string; name: string } | null {
  const text = hints.filter(Boolean).join(' ')
  for (const [re, name, label] of RULES) if (re.test(text)) return { icon: icon(name), name: label }
  return null
}

/** 厂商 / 客户端图标；找不到时显示首字母圆点 */
export function VendorLogo({ hints, fallback, className }: {
  hints: (string | null | undefined)[]
  fallback?: string
  className?: string
}) {
  const v = vendorOf(...hints)
  if (!v) {
    const ch = (fallback ?? hints.find(Boolean) ?? '?').trim().charAt(0).toUpperCase()
    return (
      <span className={cn('inline-flex size-4 shrink-0 items-center justify-center rounded-full bg-secondary text-[9px] font-semibold text-subtle-foreground', className)}>
        {ch}
      </span>
    )
  }
  return (
    <span title={v.name} className={cn('inline-flex size-4 shrink-0 items-center justify-center [&>svg]:size-full', className)}
      dangerouslySetInnerHTML={{ __html: v.icon }} />
  )
}
