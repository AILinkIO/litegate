import { useRouter } from '@tanstack/react-router'
import { Button } from '@/components/ui/button'

export function NotFoundError() {
  const { history, navigate } = useRouter()
  return (
    <div className='flex min-h-[60svh] flex-col items-center justify-center gap-2 text-center'>
      <h1 className='text-6xl font-bold'>404</h1>
      <p className='text-muted-foreground'>页面不存在</p>
      <div className='mt-4 flex gap-3'>
        <Button variant='outline' onClick={() => history.go(-1)}>返回</Button>
        <Button onClick={() => navigate({ to: '/' })}>回到首页</Button>
      </div>
    </div>
  )
}
