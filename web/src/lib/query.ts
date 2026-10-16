import { useQuery, useQueryClient, type UseQueryOptions } from '@tanstack/react-query'
import { api } from './api'

/** GET 接口的查询：以路径为缓存键 */
export function useGet<T>(path: string | null, opts: Omit<UseQueryOptions<T>, 'queryKey' | 'queryFn'> = {}) {
  return useQuery<T>({
    queryKey: [path],
    queryFn: () => api.get<T>(path!),
    enabled: path !== null && (opts.enabled ?? true),
    ...opts,
  })
}

/** 写操作后刷新：使以这些前缀开头的 GET 缓存失效 */
export function useInvalidate() {
  const qc = useQueryClient()
  return (...prefixes: string[]) =>
    qc.invalidateQueries({
      predicate: (q) => {
        const k = q.queryKey[0]
        return typeof k === 'string' && prefixes.some((p) => k === p || k.startsWith(`${p}/`) || k.startsWith(`${p}?`))
      },
    })
}
