import { type SVGProps } from 'react'
import { cn } from '@/lib/utils'

/** LiteGate 标志：一道拱门，中间一条穿过的路径 */
export function Logo({ className, ...props }: SVGProps<SVGSVGElement>) {
  return (
    <svg viewBox='0 0 24 24' fill='none' stroke='currentColor' strokeWidth='2' strokeLinecap='round'
      strokeLinejoin='round' className={cn('size-6', className)} aria-hidden='true' {...props}>
      <path d='M4 21V10a8 8 0 0 1 16 0v11' />
      <path d='M8.5 21v-9a3.5 3.5 0 0 1 7 0v9' />
      <path d='M2 21h20' />
    </svg>
  )
}
