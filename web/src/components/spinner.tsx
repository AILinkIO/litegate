import { Loader2 } from 'lucide-react'
import { cn } from '@/lib/utils'

export function Spinner({ className }: { className?: string }) {
  return (
    <div className={cn('flex justify-center py-8 text-muted-foreground', className)}>
      <Loader2 className='size-6 animate-spin' />
    </div>
  )
}
