import { useRouter } from '@tanstack/react-router'
import { Button } from '@/components/ui/button'

export function GeneralError({ error }: { error?: unknown }) {
  const { history, navigate } = useRouter()
  return (
    <div className='flex min-h-[60svh] flex-col items-center justify-center gap-2 text-center'>
      <h1 className='text-5xl font-bold'>出错了</h1>
      <p className='max-w-md text-muted-foreground'>{error instanceof Error ? error.message : '页面渲染失败，请刷新重试'}</p>
      <div className='mt-4 flex gap-3'>
        <Button variant='outline' onClick={() => history.go(-1)}>返回</Button>
        <Button onClick={() => navigate({ to: '/' })}>回到首页</Button>
      </div>
    </div>
  )
}
