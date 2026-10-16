import type * as echarts from 'echarts/core'

export type ChartOption = echarts.EChartsCoreOption

/** 当前主题下图表要用的颜色（取自 CSS 变量，随明暗切换） */
export interface ChartTheme {
  dark: boolean
  palette: string[]
  fg: string
  muted: string
  border: string
  card: string
  success: string
  warning: string
  danger: string
}

/** 各图表共用的基础配置：字体、颜色、提示框、网格 */
export function baseOption(t: ChartTheme): ChartOption {
  return {
    color: t.palette,
    textStyle: { fontFamily: 'inherit', color: t.muted, fontSize: 11 },
    animationDuration: 300,
    grid: { left: 8, right: 12, top: 28, bottom: 4, outerBoundsMode: 'same', outerBoundsContain: 'axisLabel' },
    tooltip: {
      trigger: 'axis',
      backgroundColor: t.card,
      borderColor: t.border,
      borderWidth: 1,
      padding: [6, 10],
      textStyle: { color: t.fg, fontSize: 12 },
      extraCssText: 'border-radius:8px;box-shadow:0 8px 24px rgba(0,0,0,.12);',
    },
    legend: { top: 0, right: 0, icon: 'roundRect', itemWidth: 10, itemHeight: 10, textStyle: { color: t.muted, fontSize: 11 } },
  }
}

/** 类目坐标轴 / 数值坐标轴的统一样式 */
export function axes(t: ChartTheme, categories: string[], valueFmt?: (v: number) => string) {
  return {
    xAxis: {
      type: 'category', data: categories,
      axisLine: { lineStyle: { color: t.border } }, axisTick: { show: false },
      axisLabel: { color: t.muted, hideOverlap: true },
    },
    yAxis: {
      type: 'value', splitNumber: 3,
      splitLine: { lineStyle: { color: t.border, type: 'dashed' } },
      axisLabel: { color: t.muted, formatter: valueFmt },
    },
  }
}
