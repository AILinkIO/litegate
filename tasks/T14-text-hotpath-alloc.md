# T14 token 估算与 SSE 规范化的分配优化

优先级：P2 ｜ 设计：[D02 附录](../designs/D02-hotpath-performance.md) ｜ 状态：待开始 ｜ 依赖：无

## 背景

- `lg_tokens:estimate` / `lg_limiter:text_tokens` 用 `unicode:characters_to_list/1`
  把整段文本展开成 list（每请求全文两次大分配）做 CJK 检测；
- `lg_sse:normalize` 对含 `\r` 的 chunk 做 `binary:replace` 全量复制。

## 目标

两处都改为 binary 原生处理，降低大文本请求的分配压力；语义与精度不变。

## 改动点

- `apps/lg_provider/src/lg_tokens.erl`、`apps/lg_router/src/lg_limiter.erl`：
  CJK 判定改按 UTF-8 码点区间在 binary 上扫描（逐码点解码状态机或分段
  `binary:decode_unsigned`），估算规则（CJK≈1 token、其余 4 字符≈1 token）不变。
- `apps/lg_provider/src/lg_sse.erl`：`normalize` 先 `binary:match(B, <<"\r">>)`
  探测，无 `\r` 直接返回原 binary（零拷贝分支）。

## 验收标准

- [ ] 现有 token 估算与 `lg_sse` eunit 全绿（估算值逐 case 不变）；
- [ ] 新增边界 case：非法 UTF-8 序列、空文本、纯 CJK、混合文本；
- [ ] 1MB 文本估算的分配量对比（PR 描述记录，定性）；
- [ ] `rebar3 eunit xref dialyzer` 全绿。

## 预估

~100 行，1 天。
