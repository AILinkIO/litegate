# T15 多实例部署配额语义文档

优先级：P2 ｜ 设计：[D04 §4](../designs/D04-features-and-security.md) ｜ 状态：待开始 ｜ 依赖：T09（文档需涵盖出站节流）

## 背景

入站限流（lg_limiter）、并发闸（lg_conc）、预算（lg_budget）、出站自适应节流
（lg_out_rate）全部是节点本地状态；多实例部署时全局配额 ≈ N × 配置值，
目前无任何文档说明。

## 目标

`docs/deploy.md` 增加"多实例部署"章节；纯文档任务，不改代码。

## 内容要求

- 逐项列明哪些限额/状态是 per-node：RPM/TPM/并发、budget 计数、cooldown、
  affinity、出站节流 Cap、response cache、login guard；
- 横向扩容时的配置折算指引（N 实例每节点配 1/N）；
- bitcask `data_dir` 不可共享（每实例独立目录），mnesia 配置表可集群同步的说明；
- 前置负载均衡下的会话亲和注意事项；
- 指明"全局配额"属路线图（外部计数器后端），当前不承诺。

## 验收标准

- [ ] 章节完整覆盖上述清单，与代码实际行为逐项核对（评审确认）；
- [ ] README 部署小节链接到新章节。

## 预估

文档 0.5 天。
