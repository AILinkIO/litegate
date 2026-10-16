import { useEffect, useRef, useState } from 'react'
import { BarChart, LineChart, PieChart } from 'echarts/charts'
import {
  DataZoomComponent,
  GridComponent,
  LegendComponent,
  MarkLineComponent,
  TitleComponent,
  TooltipComponent,
} from 'echarts/components'
import * as echarts from 'echarts/core'
import { CanvasRenderer } from 'echarts/renderers'
import type { ChartOption, ChartTheme } from '@/lib/chart'
import { cn } from '@/lib/utils'

echarts.use([BarChart, LineChart, PieChart, GridComponent, TooltipComponent, LegendComponent, DataZoomComponent,
  MarkLineComponent, TitleComponent, CanvasRenderer])

function readTheme(): ChartTheme {
  const s = getComputedStyle(document.documentElement)
  const v = (n: string) => s.getPropertyValue(n).trim()
  return {
    dark: document.documentElement.classList.contains('dark'),
    palette: [1, 2, 3, 4, 5, 6, 7].map((i) => v(`--chart-${i}`)),
    fg: v('--foreground'),
    muted: v('--muted-foreground'),
    border: v('--border'),
    card: v('--card'),
    success: v('--success'),
    warning: v('--warning'),
    danger: v('--destructive'),
  }
}

/** 跟随 <html class="dark"> 的变化 */
function useChartTheme(): ChartTheme {
  const [theme, setTheme] = useState(readTheme)
  useEffect(() => {
    const obs = new MutationObserver(() => setTheme(readTheme()))
    obs.observe(document.documentElement, { attributes: true, attributeFilter: ['class'] })
    return () => obs.disconnect()
  }, [])
  return theme
}

/** ECharts 图表：option 由当前主题生成；容器尺寸变化时自适应 */
export function EChart({ option, height = 240, className }: {
  option: (t: ChartTheme) => ChartOption
  height?: number
  className?: string
}) {
  const ref = useRef<HTMLDivElement>(null)
  const chart = useRef<echarts.ECharts | null>(null)
  const theme = useChartTheme()

  useEffect(() => {
    const el = ref.current!
    chart.current = echarts.init(el, null, { renderer: 'canvas' })
    const ro = new ResizeObserver(() => chart.current?.resize())
    ro.observe(el)
    return () => {
      ro.disconnect()
      chart.current?.dispose()
      chart.current = null
    }
  }, [])

  useEffect(() => {
    chart.current?.setOption(option(theme), { notMerge: true })
  }, [option, theme])

  return <div ref={ref} className={cn('w-full', className)} style={{ height }} />
}
