import { useId, type ReactElement, type ReactNode, cloneElement } from 'react'
import { cn } from '@/lib/utils'
import { Label } from '@/components/ui/label'

/** 表单项：标签 + 控件 + 说明 / 错误（控件自动关联 id） */
export function Field({ label, hint, error, children, className, required }: {
  label?: ReactNode
  hint?: ReactNode
  error?: ReactNode
  children: ReactElement<{ id?: string }>
  className?: string
  required?: boolean
}) {
  const id = useId()
  return (
    <div className={cn('grid content-start gap-1.5', className)}>
      {label && (
        <Label htmlFor={id} className='text-subtle-foreground'>
          {label}
          {required && <span className='text-destructive'>*</span>}
        </Label>
      )}
      {cloneElement(children, { id })}
      {error ? <p className='text-xs text-destructive'>{error}</p> : hint ? <p className='text-xs text-muted-foreground'>{hint}</p> : null}
    </div>
  )
}
