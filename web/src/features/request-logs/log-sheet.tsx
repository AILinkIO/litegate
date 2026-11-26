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
import { t } from '@/i18n'

/** 日志详情抽屉：基本信息、路由决策、上下文占用、对话 */
export function LogSheet({ id, onClose }: { id: string | null; onClose: () => void }) {
  const q = useGet<LogEntry>(id ? `/logs/${seg(id)}` : null)
  const names = useNames()
  const log = q.data
  return (
    <Sheet open={id !== null} onOpenChange={(o) => !o && onClose()}>
      <SheetContent className='w-full gap-0 overflow-y-auto overscroll-contain sm:w-2/3 sm:max-w-none'>
        <SheetHeader className='border-b'>
          <SheetTitle className='flex items-center gap-2'>{t('请求详情')} {log && <StatusBadge log={log} />}</SheetTitle>
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
        <Row label={t('时间')}>{fmtTime(log.ts)}</Row>
        <Row label={t('接口')}>{ENDPOINT[log.format]}{log.stream ? t('（流式）') : ''}</Row>
        <Row label={t('路由')}>
          <code className='text-[13px]'>{log.route}</code>
          {log.model && log.model !== log.route && <span className='text-muted-foreground'>{t('（请求')} <code className='text-[13px]'>{log.model}</code>{t('）')}</span>}
        </Row>
        <Row label={t('上游')}>
          <span className='inline-flex items-center gap-1.5'>
            {log.credential && <VendorLogo hints={[cred?.provider, cred?.base_url, log.upstream_model]} />}
            {log.credential ? names.credName(log.credential) : '—'} → <code className='text-[13px]'>{log.upstream_model ?? '—'}</code>
          </span>
        </Row>
        <Row label='API Key'>{names.key(log.key_id)}</Row>
        {log.client && (
          <Row label={t('客户端')}>
            <span className='inline-flex items-center gap-1.5'><VendorLogo hints={[log.client]} fallback={log.client} />{clientLabel(log.client)}</span>
            {log.user_agent && <div className='text-xs text-muted-foreground'>{log.user_agent}</div>}
          </Row>
        )}
        {!!log.tags?.length && (
          <Row label={t('标签')}><div className='flex flex-wrap gap-1'>{log.tags.map((x) => <Badge key={x} variant='muted'>{x}</Badge>)}</div></Row>
        )}
        {log.error && <Row label={t('错误')}><span className='text-destructive'>{log.error.message ?? JSON.stringify(log.error.detail ?? log.error.kind)}</span></Row>}
        <Row label={t('结束原因')}>{log.finish_reason ?? '—'}{log.loop_detected && <Badge variant='warning' className='ms-2'>{t('复读，提前结束')}</Badge>}</Row>
        {log.usage && log.format === 'images' && <Row label={t('图片')}>{t('{n} 张', { n: log.usage.images ?? 0 })}</Row>}
        {log.usage && log.format === 'speech' && <Row label={t('字符数')}>{fmtTokens(log.usage.chars ?? 0)}</Row>}
        {log.usage && log.format !== 'images' && log.format !== 'speech' && (
          <Row label='Token'>
            <span className='num'>{t('输入 {input} · 缓存读 {cr} · 缓存写 {cw} · 输出 {output}', { input: fmtTokens(log.usage.input), cr: fmtTokens(log.usage.cache_read), cw: fmtTokens(log.usage.cache_write), output: fmtTokens(log.usage.output) })}</span>
          </Row>
        )}
        <Row label={t('费用')}>
          <span className='num'>{fmtCost(log.cost)}</span>
          {log.cache_hit && t('（缓存命中，节省 {usd}）', { usd: fmtCost(log.saved_usd) })}
          {log.plan && (log.plan_usd ? t('（订阅套餐，等价 {usd}）', { usd: fmtCost(log.plan_usd) }) : t('（订阅套餐）'))}
        </Row>
        <Row label={t('耗时')}>
          <span className='num'>{fmtMs(log.duration_ms)}</span>
          {log.stream && log.ttft_ms != null && t('（首 token {ms}）', { ms: fmtMs(log.ttft_ms) })}
          {!!log.queued_ms && t('（排队 {ms}）', { ms: fmtMs(log.queued_ms) })}
          {log.attempts > 1 && t('，尝试 {n} 次', { n: log.attempts })}
        </Row>
        {!!log.redacted && <Row label={t('脱敏')}>{t('{n} 处敏感信息以占位符发往上游，下方对话为脱敏后的内容', { n: log.redacted })}</Row>}
        {log.session && (
          <Row label={t('会话')}>
            <Link to='/sessions' search={{ id: log.session }} className='font-mono text-[13px] text-primary hover:underline'>{log.session}</Link>
            {log.affinity && <span className='text-muted-foreground'>{t(' · 粘性 {label}', { label: affinityLabel(log.affinity) })}</span>}
          </Row>
        )}
      </div>
      {(!!log.narrative?.length || log.plan_trace || (log.attempt_list?.length ?? 0) > 1 || log.rule !== undefined) && (
        <Section title={t('路由决策')}>
          {!!log.narrative?.length && <div className='mb-2'><Narrative lines={log.narrative} /></div>}
          <DecisionDetail log={log} credName={names.credName} />
        </Section>
      )}
      {log.context && (
        <Section title={t('上下文占用')}><ContextUsage ctx={log.context} usage={log.usage} /></Section>
      )}
      <Section title={t('对话')}>
        {!log.messages && (
          <p className='text-sm text-muted-foreground'>
            {log.format === 'embeddings' ? t('embeddings 请求不记录内容') : t('未记录对话内容（运行参数 record_messages 关闭）')}
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
                <img src={u} alt={t('生成的图片')} className='size-40 rounded-lg border object-cover' />
              </a>
            ))}
          </div>
        ) : log.messages && log.format !== 'speech' && <Bubble role='assistant' text={log.messages.response} />}
      </Section>
    </>
  )
}
