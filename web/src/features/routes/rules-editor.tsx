import { ArrowDown, ArrowUp, Plus, X } from 'lucide-react'
import { CLIENT_LABEL, type Credential, type DecisionStyle, type IntentEngine } from '@/lib/api'
import { emptyRule, hoursOk, rangeOk, type RuleDraft } from './rules-model'
import { t, tk } from '@/i18n'

const intOk = (s: string) => s.trim() === '' || (Number.isInteger(Number(s)) && Number(s) >= 0)
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Field } from '@/components/form-field'
import { SimpleSelect, TagInput } from '@/components/form-controls'
import { Segmented } from '@/components/segmented'

const TRI = [{ value: '', label: tk('不限') }, { value: 'true', label: tk('是') }, { value: 'false', label: tk('否') }]

export function RulesEditor({ rules, onChange, routes, classifierRoutes, credentials, classifier, onClassifier, engine, onEngine,
  decisionRoute, onDecisionRoute, decisionStyle, onDecisionStyle }: {
  rules: RuleDraft[]
  onChange: (rules: RuleDraft[]) => void
  routes: string[]
  classifierRoutes: string[]
  credentials: Credential[]
  classifier: string
  onClassifier: (v: string) => void
  engine: IntentEngine
  onEngine: (v: IntentEngine) => void
  decisionRoute: string
  onDecisionRoute: (v: string) => void
  decisionStyle: DecisionStyle
  onDecisionStyle: (v: DecisionStyle) => void
}) {
  const set = (i: number, patch: Partial<RuleDraft>) => onChange(rules.map((r, j) => (j === i ? { ...r, ...patch } : r)))
  const move = (i: number, d: number) => {
    const next = [...rules]
    const [r] = next.splice(i, 1)
    next.splice(i + d, 0, r)
    onChange(next)
  }
  const hasIntent = rules.some((r) => r.intent.trim())
  const routeOptions = routes.map((n) => ({ value: n, label: n }))
  const classifierOptions = classifierRoutes.map((n) => ({ value: n, label: n }))
  const tri = TRI.map((o) => ({ ...o, label: t(o.label) }))

  return (
    <div className='grid gap-3'>
      <p className='text-sm text-muted-foreground'>
        {t('每轮对话开始时从上往下检查，第一条条件全部满足的规则生效；同一轮的后续请求（工具调用）沿用判定。 「先发给」把请求先交给另一条路由，本路由的目标接在后面作为回退；「跳过凭证」用于高峰时段暂停某些凭证。')}
      </p>
      {rules.map((r, i) => (
        <div key={i} className='rounded-lg border bg-card p-4'>
          <div className='mb-3 flex items-center'>
            <span className='flex-1 text-sm font-semibold'>{t('规则 {n}', { n: i + 1 })}</span>
            <Button variant='ghost' size='icon' className='size-7' disabled={i === 0} onClick={() => move(i, -1)} aria-label={t('上移')}><ArrowUp /></Button>
            <Button variant='ghost' size='icon' className='size-7' disabled={i === rules.length - 1} onClick={() => move(i, 1)} aria-label={t('下移')}><ArrowDown /></Button>
            <Button variant='ghost' size='icon' className='size-7' onClick={() => onChange(rules.filter((_, j) => j !== i))} aria-label={t('删除')}><X /></Button>
          </div>
          <div className='grid gap-3 sm:grid-cols-4'>
            <Field label={t('意图（可选）')} hint={t('由意图判断模型读这一轮的用户消息，判断是否属于这类请求')} className='sm:col-span-4'>
              <Input value={r.intent} placeholder={t('如：writing or fixing tests、写测试或修测试')} onChange={(e) => set(i, { intent: e.target.value })} />
            </Field>
            <Field label='tokens ≥'><Input value={r.min_tokens} aria-invalid={!intOk(r.min_tokens) || !rangeOk(r)} onChange={(e) => set(i, { min_tokens: e.target.value })} /></Field>
            <Field label='tokens ≤' error={!rangeOk(r) ? t('下限不能大于上限') : undefined}>
              <Input value={r.max_tokens} aria-invalid={!intOk(r.max_tokens) || !rangeOk(r)} onChange={(e) => set(i, { max_tokens: e.target.value })} />
            </Field>
            <Field label={t('带图片')}><SimpleSelect value={r.images} onChange={(v) => set(i, { images: v as RuleDraft['images'] })} options={tri} /></Field>
            <Field label={t('开启推理')}><SimpleSelect value={r.thinking} onChange={(v) => set(i, { thinking: v as RuleDraft['thinking'] })} options={tri} /></Field>
            <Field label={t('接口格式')} className='sm:col-span-2'>
              <TagInput freeSolo={false} value={r.client} onChange={(v) => set(i, { client: v })} placeholder={t('不限')}
                options={['openai', 'anthropic', 'responses'].map((v) => ({ value: v, label: v }))} />
            </Field>
            <Field label={t('客户端工具')} className='sm:col-span-2'>
              <TagInput value={r.tool} onChange={(v) => set(i, { tool: v })} placeholder={t('不限')}
                options={Object.keys(CLIENT_LABEL).filter((k) => k !== 'litegate').map((k) => ({ value: k, label: t(CLIENT_LABEL[k]) }))} />
            </Field>
            <Field label={t('请求标签（任一）')} className='sm:col-span-2'>
              <TagInput value={r.tags} onChange={(v) => set(i, { tags: v })} placeholder={t('不限')} mono />
            </Field>
            <Field label={t('时段')} className='sm:col-span-2' error={r.hours.trim() !== '' && !hoursOk(r.hours) ? t('格式 09:00-18:00，起始 0-23 点，结束可到 24:00') : undefined}>
              <Input value={r.hours} placeholder='09:00-12:00' aria-invalid={r.hours.trim() !== '' && !hoursOk(r.hours)}
                onChange={(e) => set(i, { hours: e.target.value })} />
            </Field>
            <Field label={t('动作')}>
              <SimpleSelect value={r.action} onChange={(v) => set(i, { action: v as 'use' | 'skip' })}
                options={[{ value: 'use', label: t('先发给路由') }, { value: 'skip', label: t('跳过凭证') }]} />
            </Field>
            {r.action === 'use' ? (
              <Field label={t('路由')} className='sm:col-span-3'>
                <SimpleSelect value={r.use} onChange={(v) => set(i, { use: v })} options={routeOptions} placeholder={t('选择路由')} />
              </Field>
            ) : (
              <Field label={t('跳过的凭证')} className='sm:col-span-3'>
                <TagInput freeSolo={false} value={r.skip} onChange={(v) => set(i, { skip: v })} placeholder={t('选择凭证')}
                  options={credentials.map((c) => ({ value: c.id, label: c.name }))} />
              </Field>
            )}
          </div>
        </div>
      ))}
      <div>
        <Button variant='outline' size='sm' disabled={rules.length >= 16} onClick={() => onChange([...rules, emptyRule()])}><Plus /> {t('添加规则')}</Button>
      </div>
      {hasIntent && (
        <div className='grid gap-3'>
          <Field label={t('判断方式')}>
            <Segmented value={engine} onChange={(v) => onEngine(v as IntentEngine)}
              options={[{ value: 'llm', label: t('判断模型') }, { value: 'systemone', label: t('决策模型') }, { value: 'laya', label: t('本地 Laya') }]} />
          </Field>
          {engine === 'systemone' && (
            <div className='grid gap-3 sm:grid-cols-2'>
              <Field label={t('决策模型（路由）')} error={decisionRoute ? undefined : t('请选择决策模型路由')}
                hint={t('TypeSafe System One 接口（如百炼 decision-model-preview），约 0.05 秒、只按输入计费；概率低于 decision_min_prob 视为不命中')}>
                <SimpleSelect value={decisionRoute} onChange={onDecisionRoute} options={classifierOptions} placeholder={t('选择路由')} />
              </Field>
              <Field label={t('问法')} hint={decisionStyle === 'choice' ? t('所有意图合成一道单选题（含「以上都不是」），与判断模型的问法一致') : t('每条意图问一道是 / 否，取「是」的概率最高者；意图越多越慢')}>
                <Segmented value={decisionStyle} onChange={(v) => onDecisionStyle(v as DecisionStyle)}
                  options={[{ value: 'choice', label: t('单选') }, { value: 'noul', label: t('逐条是非') }]} />
              </Field>
            </div>
          )}
          {engine === 'laya' && (
            <p className='text-sm text-muted-foreground'>
              {t('本地 Laya 服务（运行参数 laya_url），约 0.1 秒、不耗额度；概率低于 laya_min_prob 视为不命中；运行参数 laya_enabled 可全局关闭')}
            </p>
          )}
          {engine === 'llm' ? (
            <Field label={t('意图判断模型（路由）')} className='max-w-sm' error={classifier ? undefined : t('有意图条件时必须选择')}
              hint={t('建议用小而快、不带推理的模型；判断超时（默认 8 秒）或失败时本轮照常路由；只列出已启用的路由（保存时后端也会校验）')}>
              <SimpleSelect value={classifier} onChange={onClassifier} options={classifierOptions} placeholder={t('选择路由')} />
            </Field>
          ) : (
            <Field label={t('后备判断模型（路由，可选）')} className='max-w-sm'
              hint={t('{engine}失败或超时（{param}）时改问这个路由；不选则本轮照常路由', { engine: engine === 'laya' ? 'Laya' : t('决策模型'), param: engine === 'laya' ? 'laya_timeout_ms' : 'decision_timeout_ms' })}>
              <SimpleSelect value={classifier} onChange={onClassifier}
                options={[{ value: '', label: t('不使用') }, ...classifierOptions]} placeholder={t('不使用')} />
            </Field>
          )}
        </div>
      )}
    </div>
  )
}
