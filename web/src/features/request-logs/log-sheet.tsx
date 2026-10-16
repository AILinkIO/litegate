import { Link } from '@tanstack/react-router'
import { clientLabel, seg, type LogEntry } from '@/lib/api'
import { fmtCost, fmtMs, fmtTime, fmtTokens } from '@/lib/format'
import { useNames } from '@/lib/names'
import { useGet } from '@/lib/query'
import { Badge } from '@/components/ui/badge'
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from '@/components/ui/sheet'
import { Skeleton } from '@/components/ui/skeleton'
import { Narrative } from '@/components/narrative'
import { ErrorAlert } from '@/components/query-state'
import { VendorLogo } from '@/components/vendor-logo'
import { Bubble, ContextUsage, DecisionDetail, Row, Section, StatusBadge } from './parts'
import { affinityLabel, contentText, ENDPOINT } from './parts-model'

/** 日志详情抽屉：基本信息、路由决策、上下文占用、对话 */
export function LogSheet({ id, onClose }: { id: string | null; onClose: () => void }) {
  const q = useGet<LogEntry>(id ? `/logs/${seg(id)}` : null)
  const names = useNames()
  const log = q.data
  return (
    <Sheet open={id !== null} onOpenChange={(o) => !o && onClose()}>
      <SheetContent className='w-full gap-0 overflow-y-auto overscroll-contain sm:w-2/3 sm:max-w-none'>
        <SheetHeader className='border-b'>
          <SheetTitle className='flex items-center gap-2'>请求详情 {log && <StatusBadge log={log} />}</SheetTitle>
          <SheetDescription className='font-mono text-xs'>{id}</SheetDescription>
        </SheetHeader>
        <div className='px-4 pb-6'>
          {q.error && <div className='pt-4'><ErrorAlert message={q.error.message} /></div>}
          {!log && !q.error && <Skeleton className='mt-4 h-64' />}
          {log && <Detail log={log} names={names} />}
        </div>
      </SheetContent>
    </Sheet>
  )
}

function Detail({ log, names }: { log: LogEntry; names: ReturnType<typeof useNames> }) {
  const cred = names.cred(log.credential)
  const req = log.messages?.request as { system?: unknown; messages?: { role: string; content: unknown }[]; questions?: unknown } | undefined
  return (
    <>
      <div className='py-3'>
        <Row label='时间'>{fmtTime(log.ts)}</Row>
        <Row label='接口'>{ENDPOINT[log.format]}{log.stream ? '（流式）' : ''}</Row>
        <Row label='路由'>
          <code className='text-[13px]'>{log.route}</code>
          {log.model && log.model !== log.route && <span className='text-muted-foreground'>（请求 <code className='text-[13px]'>{log.model}</code>）</span>}
        </Row>
        <Row label='上游'>
          <span className='inline-flex items-center gap-1.5'>
            {log.credential && <VendorLogo hints={[cred?.provider, cred?.base_url, log.upstream_model]} />}
            {log.credential ? names.credName(log.credential) : '—'} → <code className='text-[13px]'>{log.upstream_model ?? '—'}</code>
          </span>
        </Row>
        <Row label='API Key'>{names.key(log.key_id)}</Row>
        {log.client && (
          <Row label='客户端'>
            <span className='inline-flex items-center gap-1.5'><VendorLogo hints={[log.client]} fallback={log.client} />{clientLabel(log.client)}</span>
            {log.user_agent && <div className='text-xs text-muted-foreground'>{log.user_agent}</div>}
          </Row>
        )}
        {!!log.tags?.length && (
          <Row label='标签'><div className='flex flex-wrap gap-1'>{log.tags.map((t) => <Badge key={t} variant='muted'>{t}</Badge>)}</div></Row>
        )}
        {log.error && <Row label='错误'><span className='text-destructive'>{log.error.message ?? JSON.stringify(log.error.detail ?? log.error.kind)}</span></Row>}
        <Row label='结束原因'>{log.finish_reason ?? '—'}{log.loop_detected && <Badge variant='warning' className='ms-2'>复读，提前结束</Badge>}</Row>
        {log.usage && log.format === 'images' && <Row label='图片'>{log.usage.images ?? 0} 张</Row>}
        {log.usage && log.format === 'speech' && <Row label='字符数'>{fmtTokens(log.usage.chars ?? 0)}</Row>}
        {log.usage && log.format !== 'images' && log.format !== 'speech' && (
          <Row label='Token'>
            <span className='num'>输入 {fmtTokens(log.usage.input)} · 缓存读 {fmtTokens(log.usage.cache_read)} · 缓存写 {fmtTokens(log.usage.cache_write)} · 输出 {fmtTokens(log.usage.output)}</span>
          </Row>
        )}
        <Row label='费用'>
          <span className='num'>{fmtCost(log.cost)}</span>
          {log.cache_hit && `（缓存命中，节省 ${fmtCost(log.saved_usd)}）`}
          {log.plan && (log.plan_usd ? `（订阅套餐，等价 ${fmtCost(log.plan_usd)}）` : '（订阅套餐）')}
        </Row>
        <Row label='耗时'>
          <span className='num'>{fmtMs(log.duration_ms)}</span>
          {log.stream && log.ttft_ms != null && `（首 token ${fmtMs(log.ttft_ms)}）`}
          {!!log.queued_ms && `（排队 ${fmtMs(log.queued_ms)}）`}
          {log.attempts > 1 && `，尝试 ${log.attempts} 次`}
        </Row>
        {!!log.redacted && <Row label='脱敏'>{log.redacted} 处敏感信息以占位符发往上游，下方对话为脱敏后的内容</Row>}
        {log.session && (
          <Row label='会话'>
            <Link to='/sessions' search={{ id: log.session }} className='font-mono text-[13px] text-primary hover:underline'>{log.session}</Link>
            {log.affinity && <span className='text-muted-foreground'> · 粘性 {affinityLabel(log.affinity)}</span>}
          </Row>
        )}
      </div>
      {(!!log.narrative?.length || log.plan_trace || (log.attempt_list?.length ?? 0) > 1 || log.rule !== undefined) && (
        <Section title='路由决策'>
          {!!log.narrative?.length && <div className='mb-2'><Narrative lines={log.narrative} /></div>}
          <DecisionDetail log={log} credName={names.credName} />
        </Section>
      )}
      {log.context && (
        <Section title='上下文占用'><ContextUsage ctx={log.context} usage={log.usage} /></Section>
      )}
      <Section title='对话'>
        {!log.messages && (
          <p className='text-sm text-muted-foreground'>
            {log.format === 'embeddings' ? 'embeddings 请求不记录内容' : '未记录对话内容（运行参数 record_messages 关闭）'}
          </p>
        )}
        {req?.system !== undefined && <Bubble role='system' text={contentText(req.system)} />}
        {(req?.messages ?? []).map((m, i) => <Bubble key={i} role={m.role} text={contentText(m.content)} />)}
        {log.format === 'systemone' && req?.questions !== undefined && (
          <pre className='overflow-x-auto rounded-lg border bg-muted/40 p-3 text-xs'>{JSON.stringify(req.questions, null, 2)}</pre>
        )}
        {log.messages && log.format === 'images' ? (
          <div className='mt-1 flex flex-wrap gap-2'>
            {log.messages.response.split('\n').filter((u) => u.startsWith('http')).map((u) => (
              <a key={u} href={u} target='_blank' rel='noopener noreferrer'>
                {/* 上游图片地址有时效，过期后显示为破图 */}
                <img src={u} alt='生成的图片' className='size-40 rounded-lg border object-cover' />
              </a>
            ))}
          </div>
        ) : log.messages && log.format !== 'speech' && <Bubble role='assistant' text={log.messages.response} />}
      </Section>
    </>
  )
}
