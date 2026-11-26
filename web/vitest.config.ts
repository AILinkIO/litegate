import path from 'path'
import { defineConfig } from 'vitest/config'

export default defineConfig({
  resolve: { alias: { '@': path.resolve(__dirname, './src') } },
  // i18n/en/*.ts 经 import.meta.glob 合并：文件缓存会沿用旧的文件列表，新增词典读不到
  test: { environment: 'node', fsModuleCache: false },
})
