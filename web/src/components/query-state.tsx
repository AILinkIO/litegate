import { type ReactNode } from 'react'
import { AlertCircle } from 'lucide-react'
import { Alert, AlertDescription } from '@/components/ui/alert'
import { Skeleton } from '@/components/ui/skeleton'

/** 查询的加载 / 出错占位；数据就绪后渲染 children */
export function QueryState<T>({ query, children, skeleton }: {
  query: { data: T | undefined; error: Error | null; isPending: boolean }
  children: (data: T) => ReactNode
  skeleton?: ReactNode
}) {
  if (query.error) return <ErrorAlert message={query.error.message} />
  if (query.isPending || query.data === undefined) return <>{skeleton ?? <Skeleton className='h-40 w-full rounded-xl' />}</>
  return <>{children(query.data)}</>
}

export function ErrorAlert({ message }: { message: string }) {
  return (
    <Alert variant='destructive' className='mb-4'>
      <AlertCircle />
      <AlertDescription>{message}</AlertDescription>
    </Alert>
  )
}

/** 空状态 */
export function Empty({ children }: { children: ReactNode }) {
  return <div className='py-10 text-center text-sm text-muted-foreground'>{children}</div>
}
