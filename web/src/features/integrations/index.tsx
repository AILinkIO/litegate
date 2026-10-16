import { useState } from 'react'
import { Copy } from 'lucide-react'
import { toast } from 'sonner'
import { useGet } from '@/lib/query'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Field } from '@/components/form-field'
import { Combobox } from '@/components/form-controls'
import { PageHeader } from '@/components/page'
import { Segmented } from '@/components/segmented'
import { VendorLogo } from '@/components/vendor-logo'

interface Snippet { title: string; lang: string; code: string; note?: string }
type Tool = 'claude' | 'codex' | 'opencode' | 'openai' | 'anthropic' | 'curl'

const TOOLS: Record<Tool, string> = {
  claude: 'Claude Code', codex: 'Codex CLI', opencode: 'opencode',
  openai: 'OpenAI SDK', anthropic: 'Anthropic SDK', curl: 'curl',
}

// 按所选工具生成配置片段（Key 只在本页使用，不会保存或发送到服务端）
function snippets(tool: Tool, base: string, key: string, model: string): Snippet[] {
  switch (tool) {
    case 'claude':
      return [{
        title: '环境变量', lang: 'sh',
        code: `export ANTHROPIC_BASE_URL=${base}\nexport ANTHROPIC_AUTH_TOKEN=${key}\nunset ANTHROPIC_API_KEY\n` +
          `# 子代理 / 后台任务使用的小模型\nexport ANTHROPIC_DEFAULT_HAIKU_MODEL=${model}\n\nclaude --model ${model}`,
        note: '不想每次指定 --model：建一个 claude-* 通配路由，或给路由加别名（如 claude-sonnet-4-5）接住 Claude Code 默认的模型名。开启思考：MAX_THINKING_TOKENS=4000。',
      }]
    case 'codex':
      return [{
        title: '~/.codex/config.toml', lang: 'toml',
        code: `model = "${model}"\nmodel_provider = "litegate"\n\n[model_providers.litegate]\nname = "LiteGate"\n` +
          `base_url = "${base}/v1"\nenv_key = "LITEGATE_API_KEY"\nwire_api = "responses"`,
      }, {
        title: '运行', lang: 'sh',
        code: `export LITEGATE_API_KEY=${key}\ncodex\n# 非交互：codex exec -s workspace-write "..." < /dev/null`,
        note: '上游是 Chat 协议时网关转换 Responses（含思考、custom / namespace 工具）；凭证开启「原生 Responses」时直接转发。',
      }]
    case 'opencode':
      return [{
        title: '~/.config/opencode/opencode.json', lang: 'json',
        code: JSON.stringify({
          $schema: 'https://opencode.ai/config.json',
          provider: {
            litegate: {
              npm: '@ai-sdk/openai-compatible', name: 'LiteGate',
              options: { baseURL: `${base}/v1`, apiKey: key },
              models: { [model]: { name: `${model} via LiteGate` } },
            },
          },
        }, null, 2),
      }, { title: '运行', lang: 'sh', code: `opencode -m litegate/${model}` }]
    case 'openai':
      return [{
        title: 'Python', lang: 'python',
        code: `from openai import OpenAI\n\nclient = OpenAI(base_url="${base}/v1", api_key="${key}")\n` +
          `r = client.chat.completions.create(\n    model="${model}",\n    messages=[{"role": "user", "content": "你好"}],\n)\nprint(r.choices[0].message.content)\n\n` +
          `# Responses API\nr = client.responses.create(model="${model}", input="你好")\nprint(r.output_text)`,
      }]
    case 'anthropic':
      return [{
        title: 'Python', lang: 'python',
        code: `from anthropic import Anthropic\n\nclient = Anthropic(base_url="${base}", api_key="${key}")\n` +
          `r = client.messages.create(\n    model="${model}", max_tokens=1024,\n    messages=[{"role": "user", "content": "你好"}],\n)\nprint(r.content[0].text)`,
      }]
    case 'curl':
      return [{
        title: 'OpenAI 格式', lang: 'sh',
        code: `curl ${base}/v1/chat/completions \\\n  -H "Authorization: Bearer ${key}" -H "Content-Type: application/json" \\\n` +
          `  -d '{"model": "${model}", "messages": [{"role": "user", "content": "你好"}]}'`,
      }, {
        title: 'Anthropic 格式', lang: 'sh',
        code: `curl ${base}/v1/messages \\\n  -H "x-api-key: ${key}" -H "anthropic-version: 2023-06-01" -H "Content-Type: application/json" \\\n` +
          `  -d '{"model": "${model}", "max_tokens": 1024, "messages": [{"role": "user", "content": "你好"}]}'`,
      }]
  }
}

export function Integrations() {
  // 普通用户无权读取路由表时为空，可直接填写
  const routes = useGet<{ name: string; aliases?: string[] }[]>('/routes', { retry: false })
  const [tool, setTool] = useState<Tool>('claude')
  const [model, setModel] = useState('')
  const [key, setKey] = useState('')
  const names = (routes.data ?? []).flatMap((r) => [r.name, ...(r.aliases ?? [])]).filter((n) => !n.endsWith('*'))
  const base = location.origin
  const list = snippets(tool, base, key.trim() || 'lgk-你的网关Key', model.trim() || names[0] || '<路由名>')

  const copy = async (code: string) => {
    try {
      await navigator.clipboard.writeText(code)
      toast.success('已复制')
    } catch {
      toast.error('复制失败')
    }
  }

  return (
    <>
      <PageHeader title='接入指南' subtitle='为常用编码工具与 SDK 生成连接本网关的配置' />
      <div className='mb-4 grid gap-3 sm:grid-cols-2'>
        <Field label='模型（路由名或别名）'>
          <Combobox mono allowCustom value={model || null} onChange={(v) => setModel(v ?? '')} placeholder={names[0] ?? '输入路由名'}
            className='bg-card' options={names.map((n) => ({ value: n, label: n }))} />
        </Field>
        <Field label='API Key' hint='粘贴网关 Key 以生成完整配置；只在本页使用，不保存'>
          <Input type='password' autoComplete='off' className='bg-card' value={key} onChange={(e) => setKey(e.target.value)} />
        </Field>
      </div>
      <div className='mb-4 overflow-x-auto'>
        <Segmented value={tool} onChange={setTool} options={Object.entries(TOOLS).map(([k, label]) => ({ value: k as Tool, label }))} />
      </div>
      <div className='grid gap-4'>
        {list.map((s) => (
          <div key={s.title} className='overflow-hidden rounded-xl border bg-card'>
            <div className='flex items-center gap-2 border-b px-4 py-2'>
              <VendorLogo hints={[tool === 'claude' ? 'claude-code' : tool]} fallback={TOOLS[tool]} />
              <span className='flex-1 text-sm font-semibold'>{s.title}</span>
              <Button variant='ghost' size='icon' className='size-8' aria-label='复制' onClick={() => copy(s.code)}><Copy /></Button>
            </div>
            <pre className='overflow-x-auto bg-secondary/40 p-4 font-mono text-[13px] leading-relaxed'>{s.code}</pre>
            {s.note && <p className='border-t px-4 py-2.5 text-sm text-muted-foreground'>{s.note}</p>}
          </div>
        ))}
      </div>
    </>
  )
}
