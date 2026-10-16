import { type ReactNode, useEffect, useLayoutEffect, useRef, useState } from 'react'
import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import { Check, ChevronRight, Copy, Route as RouteIcon, Wrench } from 'lucide-react'
import { cn } from '@/lib/utils'

/** 助手回复的 Markdown（GFM：表格、删除线、任务列表）；代码块带语言名与复制按钮 */
export function Markdown({ text }: { text: string }) {
  return (
    <div className='chat-md'>
      <ReactMarkdown remarkPlugins={[remarkGfm]}
        components={{
          pre: ({ children }) => <CodeBlock>{children}</CodeBlock>,
          a: ({ children, href }) => <a href={href} target='_blank' rel='noopener noreferrer'>{children}</a>,
        }}>
        {text}
      </ReactMarkdown>
    </div>
  )
}

function CodeBlock({ children }: { children: ReactNode }) {
  const ref = useRef<HTMLPreElement>(null)
  const [copied, setCopied] = useState(false)
  const code = (children as { props?: { className?: string } } | undefined)?.props
  const lang = /language-([\w+-]+)/.exec(code?.className ?? '')?.[1]
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(ref.current?.innerText ?? '')
      setCopied(true)
      setTimeout(() => setCopied(false), 1500)
    } catch { /* 剪贴板不可用时忽略 */ }
  }
  return (
    <div className='code-block group/code'>
      <div className='absolute end-1.5 top-1.5 flex items-center gap-1.5 opacity-0 transition-opacity group-hover/code:opacity-100'>
        {lang && <span className='text-[10px] tracking-wide text-muted-foreground uppercase'>{lang}</span>}
        <button type='button' onClick={copy}
          className='flex items-center gap-1 rounded-md border bg-background px-2 py-0.5 text-[11px] text-muted-foreground hover:text-foreground'>
          {copied ? <Check className='size-3' /> : <Copy className='size-3' />}{copied ? '已复制' : '复制'}
        </button>
      </div>
      <pre ref={ref}>{children}</pre>
    </div>
  )
}

/** 思考过程：无边框的折叠开关，生成中默认展开、文字流光；结束后默认收起 */
export function ThinkingBlock({ text, streaming }: { text: string; streaming: boolean }) {
  const [open, setOpen] = useState<boolean | null>(null)
  const shown = open ?? streaming
  return (
    <div>
      <button type='button' onClick={() => setOpen(!shown)}
        className='-ms-2 inline-flex items-center gap-1.5 rounded-md px-2 py-1 text-xs font-medium text-muted-foreground hover:bg-muted-foreground/10'>
        <ChevronRight className={cn('size-3.5 transition-transform duration-200', shown && 'rotate-90')} />
        <span className={cn(streaming && 'shimmer-text')}>{streaming ? '思考中…' : '思考过程'}</span>
        <span className='num opacity-75'>{text.length} 字</span>
      </button>
      {shown && <p className='ps-6 pt-1 pb-1 text-xs leading-relaxed whitespace-pre-wrap break-words text-muted-foreground'>{text}</p>}
    </div>
  )
}

/** 工具调用：左侧色条的卡片，函数名等宽，参数折行显示 */
export function ToolCallCard({ name, args }: { name: string; args: string }) {
  let pretty = args
  try { pretty = JSON.stringify(JSON.parse(args), null, 2) } catch { /* 流式中途或非 JSON，原样显示 */ }
  return (
    <div className='overflow-hidden rounded-lg border border-s-[3px] border-s-primary bg-muted-foreground/5'>
      <div className='flex items-center gap-2 px-3 py-2'>
        <Wrench className='size-3.5 shrink-0 text-muted-foreground' />
        <span className='truncate font-mono text-[0.8125rem]'>{name || '(未命名工具)'}</span>
        <span className='text-xs text-muted-foreground'>工具调用</span>
      </div>
      {pretty && (
        <pre className='max-h-60 overflow-auto border-t bg-background/60 px-3 py-2 font-mono text-xs whitespace-pre-wrap break-all text-muted-foreground'>{pretty}</pre>
      )}
    </div>
  )
}

/** 可折叠分组（路由决策）：标题行 + 左侧细竖线的内容区 */
export function Collapsible({ title, defaultOpen = true, children }: { title: ReactNode; defaultOpen?: boolean; children: ReactNode }) {
  const [open, setOpen] = useState(defaultOpen)
  return (
    <div>
      <button type='button' onClick={() => setOpen(!open)}
        className='-ms-2 inline-flex items-center gap-1.5 rounded-md px-2 py-1 text-xs font-medium text-muted-foreground hover:bg-muted-foreground/10'>
        <RouteIcon className='size-3.5 text-primary' />
        {title}
        <ChevronRight className={cn('size-3.5 transition-transform duration-200', open && 'rotate-90')} />
      </button>
      {open && <div className='ms-[7px] mt-1 border-s ps-3.5'>{children}</div>}
    </div>
  )
}

/** 随内容自动增高的输入框（36–180px），透明背景，边框由外层胶囊提供 */
export function AutoTextarea({ value, onChange, ...rest }: { value: string; onChange: (v: string) => void }
  & Omit<React.TextareaHTMLAttributes<HTMLTextAreaElement>, 'value' | 'onChange'>) {
  const ref = useRef<HTMLTextAreaElement>(null)
  useLayoutEffect(() => {
    const el = ref.current
    if (!el) return
    el.style.height = 'auto'
    el.style.height = `${Math.min(180, Math.max(36, el.scrollHeight))}px`
  }, [value])
  useEffect(() => { ref.current?.focus() }, [])
  return (
    <textarea ref={ref} rows={1} value={value} onChange={(e) => onChange(e.target.value)}
      className='min-h-9 flex-1 resize-none bg-transparent px-1 py-2 text-sm leading-normal outline-none placeholder:text-muted-foreground disabled:opacity-60'
      {...rest} />
  )
}
