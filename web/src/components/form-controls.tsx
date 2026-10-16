import { type ReactNode, useState } from 'react'
import { Check, ChevronsUpDown, X } from 'lucide-react'
import { cn } from '@/lib/utils'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Checkbox } from '@/components/ui/checkbox'
import { Command, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList } from '@/components/ui/command'
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Textarea } from '@/components/ui/textarea'

export interface Option { value: string; label: ReactNode; keywords?: string; hint?: ReactNode }

// Radix Select 不允许空字符串作为值：用占位值表示「无」
const NONE = '__none__'

/** 简单下拉：options 中 value 为 '' 表示「无」 */
export function SimpleSelect({ value, onChange, options, placeholder, className, id, disabled }: {
  value: string
  onChange: (v: string) => void
  options: Option[]
  placeholder?: string
  className?: string
  id?: string
  disabled?: boolean
}) {
  return (
    <Select value={value === '' ? NONE : value} onValueChange={(v) => onChange(v === NONE ? '' : v)} disabled={disabled}>
      <SelectTrigger id={id} className={cn('w-full', className)}><SelectValue placeholder={placeholder} /></SelectTrigger>
      <SelectContent>
        {options.map((o) => <SelectItem key={o.value || NONE} value={o.value || NONE}>{o.label}</SelectItem>)}
      </SelectContent>
    </Select>
  )
}

/** 可搜索的单选（选项多时用，如供应商、凭证、模型）；allowCustom 时可直接用输入的文字 */
export function Combobox({ value, onChange, options, placeholder = '请选择', searchPlaceholder = '搜索…', empty = '没有匹配项',
  allowCustom, clearable, className, id, mono }: {
  value: string | null
  onChange: (v: string | null) => void
  options: Option[]
  placeholder?: string
  searchPlaceholder?: string
  empty?: string
  allowCustom?: boolean
  clearable?: boolean
  className?: string
  id?: string
  mono?: boolean
}) {
  const [open, setOpen] = useState(false)
  const [text, setText] = useState('')
  const current = options.find((o) => o.value === value)
  const pick = (v: string | null) => {
    onChange(v)
    setOpen(false)
    setText('')
  }
  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button id={id} type='button' variant='outline' role='combobox' aria-expanded={open}
          className={cn('w-full justify-between bg-transparent px-3 font-normal', !value && 'text-muted-foreground', className)}>
          <span className={cn('truncate', mono && value && 'font-mono text-[13px]')}>{current?.label ?? value ?? placeholder}</span>
          <span className='ms-2 flex shrink-0 items-center gap-1'>
            {clearable && value && (
              <X className='size-3.5 opacity-50 hover:opacity-100' onClick={(e) => { e.stopPropagation(); pick(null) }} />
            )}
            <ChevronsUpDown className='size-3.5 opacity-50' />
          </span>
        </Button>
      </PopoverTrigger>
      <PopoverContent className='w-(--radix-popover-trigger-width) min-w-64 p-0' align='start'>
        <Command>
          <CommandInput placeholder={searchPlaceholder} value={text} onValueChange={setText} />
          <CommandList>
            <CommandEmpty>
              {allowCustom && text.trim() ? (
                <button type='button' className='w-full px-2 text-start text-sm' onClick={() => pick(text.trim())}>
                  使用 <span className='font-mono'>{text.trim()}</span>
                </button>
              ) : empty}
            </CommandEmpty>
            <CommandGroup>
              {allowCustom && text.trim() && !options.some((o) => o.value === text.trim()) && (
                <CommandItem value={`__custom__ ${text}`} onSelect={() => pick(text.trim())}>
                  使用 <span className='font-mono'>{text.trim()}</span>
                </CommandItem>
              )}
              {options.map((o) => (
                <CommandItem key={o.value} value={`${o.value} ${o.keywords ?? ''} ${typeof o.label === 'string' ? o.label : ''}`}
                  onSelect={() => pick(o.value)}>
                  <Check className={cn('size-4', o.value === value ? 'opacity-100' : 'opacity-0')} />
                  <div className='min-w-0'>
                    <div className={cn('truncate', mono && 'font-mono text-[13px]')}>{o.label}</div>
                    {o.hint && <div className='truncate text-xs text-muted-foreground'>{o.hint}</div>}
                  </div>
                </CommandItem>
              ))}
            </CommandGroup>
          </CommandList>
        </Command>
      </PopoverContent>
    </Popover>
  )
}

/** 多值输入：回车或逗号添加；有 options 时可从中选择（freeSolo 时也可输入任意值） */
export function TagInput({ value, onChange, options, placeholder = '输入后回车', freeSolo = true, className, mono, id, normalize }: {
  value: string[]
  onChange: (v: string[]) => void
  options?: Option[]
  placeholder?: string
  freeSolo?: boolean
  className?: string
  mono?: boolean
  id?: string
  normalize?: (s: string) => string
}) {
  const [text, setText] = useState('')
  const [open, setOpen] = useState(false)
  const add = (raw: string) => {
    const v = (normalize ?? ((s: string) => s.trim()))(raw)
    if (v && !value.includes(v)) onChange([...value, v])
    setText('')
  }
  const label = (v: string) => options?.find((o) => o.value === v)?.label ?? v
  const avail = (options ?? []).filter((o) => !value.includes(o.value))
  const matches = avail.filter((o) => `${o.value} ${o.keywords ?? ''}`.toLowerCase().includes(text.trim().toLowerCase()))
  return (
    <Popover open={open && matches.length > 0} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <div className={cn('flex min-h-9 w-full flex-wrap items-center gap-1 rounded-md border border-input px-2 py-1 focus-within:border-ring focus-within:ring-[3px] focus-within:ring-ring/50', className)}
          onClick={() => setOpen(true)}>
          {value.map((v) => (
            <Badge key={v} variant='muted' className={cn('gap-0.5 pe-1', mono && 'font-mono')}>
              {label(v)}
              <button type='button' aria-label='移除' className='rounded-sm opacity-60 hover:opacity-100'
                onClick={(e) => { e.stopPropagation(); onChange(value.filter((x) => x !== v)) }}>
                <X className='size-3' />
              </button>
            </Badge>
          ))}
          <input id={id} value={text} placeholder={value.length ? '' : placeholder}
            className='min-w-24 flex-1 bg-transparent py-0.5 text-sm outline-none placeholder:text-muted-foreground'
            onFocus={() => setOpen(true)}
            onChange={(e) => {
              const t = e.target.value
              if (freeSolo && /[,，]$/.test(t)) add(t.slice(0, -1))
              else setText(t)
            }}
            onKeyDown={(e) => {
              if (e.key === 'Enter') {
                e.preventDefault()
                if (freeSolo) add(text)
                else if (matches[0]) add(matches[0].value)
              } else if (e.key === 'Backspace' && !text && value.length) {
                onChange(value.slice(0, -1))
              }
            }} />
        </div>
      </PopoverTrigger>
      <PopoverContent className='max-h-64 w-(--radix-popover-trigger-width) overflow-y-auto p-1' align='start'
        onOpenAutoFocus={(e) => e.preventDefault()}>
        {matches.map((o) => (
          <button type='button' key={o.value} className='flex w-full items-center rounded-sm px-2 py-1.5 text-start text-sm hover:bg-accent'
            onClick={() => add(o.value)}>
            <span className={cn('truncate', mono && 'font-mono text-[13px]')}>{o.label}</span>
            {o.hint && <span className='ms-auto ps-2 text-xs text-muted-foreground'>{o.hint}</span>}
          </button>
        ))}
      </PopoverContent>
    </Popover>
  )
}

export function JsonTextarea({ value, onChange, invalid, rows = 4, id, placeholder }: {
  value: string
  onChange: (v: string) => void
  invalid?: boolean
  rows?: number
  id?: string
  placeholder?: string
}) {
  return (
    <Textarea id={id} rows={rows} value={value} placeholder={placeholder} aria-invalid={invalid} spellCheck={false}
      onChange={(e) => onChange(e.target.value)} className='font-mono text-[13px] leading-relaxed' />
  )
}

/** 复选框 + 说明（整行可点） */
export function CheckRow({ checked, onChange, label, hint, disabled }: {
  checked: boolean
  onChange: (v: boolean) => void
  label: ReactNode
  hint?: ReactNode
  disabled?: boolean
}) {
  return (
    <label className={cn('flex cursor-pointer items-start gap-2.5 py-0.5', disabled && 'cursor-not-allowed opacity-60')}>
      <Checkbox className='mt-0.5' checked={checked} disabled={disabled} onCheckedChange={(v) => onChange(v === true)} />
      <span className='text-sm leading-snug'>
        {label}
        {hint && <span className='block text-xs text-muted-foreground'>{hint}</span>}
      </span>
    </label>
  )
}
