import path from 'path'
import tailwindcss from '@tailwindcss/vite'
import { tanstackRouter } from '@tanstack/router-plugin/vite'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// 控制台挂在 /console 下，构建产物由 cowboy 从 lg_web/priv/static 托管。
export default defineConfig({
  plugins: [tanstackRouter({ target: 'react', autoCodeSplitting: true }), react(), tailwindcss()],
  base: '/console/',
  resolve: { alias: { '@': path.resolve(__dirname, './src') } },
  build: {
    outDir: '../apps/lg_web/priv/static',
    emptyOutDir: true,
    // ECharts 单独成块（约 600KB，只有带图表的页面加载，长期缓存）
    chunkSizeWarningLimit: 700,
    rolldownOptions: {
      output: { advancedChunks: { groups: [{ name: 'echarts', test: /node_modules[\\/](echarts|zrender)[\\/]/ }] } },
    },
  },
  // 开发时代理到网关（LITEGATE_URL 可改，默认本机 4000）
  server: {
    proxy: {
      '/api': process.env.LITEGATE_URL ?? 'http://localhost:4000',
      '/v1': process.env.LITEGATE_URL ?? 'http://localhost:4000',
    },
  },
})
