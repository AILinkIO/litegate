import { type Route, type RouteTarget } from '@/lib/api'

export const isWildcard = (name: string) => name.endsWith('*')

export interface Draft {
  name: string
  targets: RouteTarget[]
  fallbacks: string[]
  aliases: string[]
  access: 'all' | string[]
  enabled: boolean
}

export const emptyTarget = (credential = ''): RouteTarget =>
  ({ credential, upstream_model: '', model_ref: null, weight: 1, priority: 0, enabled: true })

export function draftOf(r: Route | null, firstCred?: string): Draft {
  return r
    ? { name: r.name, targets: r.targets.map((t) => ({ ...emptyTarget(), ...t, upstream_model: t.upstream_model ?? '' })),
        fallbacks: r.fallbacks, aliases: r.aliases ?? [], access: r.access, enabled: r.enabled }
    : { name: '', targets: [emptyTarget(firstCred)], fallbacks: [], aliases: [], access: 'all', enabled: true }
}
