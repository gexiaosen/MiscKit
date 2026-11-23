# MiscKit 性能分析（2026-11-23）

> 使用性能优化流程：**无测量，不结论；无同合同证据，不授权。**
> 本文所有数字只覆盖：本机、两份真实索引快照、热缓存、单进程、SQL/DB 边界。

## 0. 结论（verdict）

**ACCEPT（仅限 SQL/DB 边界）**：把文件相关性排序的前缀段从
`name_folded LIKE 'x%' ESCAPE '\'` 改为 `name_folded GLOB 'x*'`，并给排序加
`id` 作为并列项定序。在 608,928 行与 753,051 行两份快照上，16 条核心查询 ×
9 次配对测量，行集合、顺序（含并列定序）、总数、`totalIsExact` 全部一致；
中位耗时改善 **1.38–2.21x**，中文前缀场景 **39–41x**。

这不是「100ms 预算已达成」的结论：S2 上常见查询仍 49–50ms、`scope=folders` 仍 197ms；
D4（count 上限）与 D5（contains/范围索引）未授权，见 §5。

**已证明范围**：
- 机器：Mac16,1 / Apple M4 / 32 GB / macOS 27.3 (26C5047e)
- 代码：repo `03c1252`（工作树干净）；安装包 MiscKit 1.0.3（build 105）
- 数据：`index.sqlite3` 的 `.backup` 快照，608,928 行（重建中）与 753,051 行（重建后）
- 查询：16 条核心矩阵 + 12 条边界矩阵；5 个臂；每臂 9 次；两份快照
- 指标：整个查询函数的 wall time（含 3 段 SELECT、去重、`cappedCount`）
- 缓存：每臂先预热 1 次，再测 9 次；热缓存
- 隔离：单进程只读连接，`mmap_size=256MB`、`cache_size=-32MB`、`temp_store=MEMORY`

**最大未验证项**：从按键到首帧的端到端延迟。仓库只有「唤起预算 ≤100ms，
实测基线 36–42ms」的注释与 CHANGELOG 的「20ms / 100ms」口径，但本次没有
panel / SwiftUI 的同合同 artifact。**不得把上面的 SQL 改善外推成端到端结论。**

**明确未授权**：count 上限调整、FTS trigram、VACUUM/auto_vacuum、
启动 Spotlight 探针移除、完整扫描改造、panel/UI 改动。原因见 §5。

---

## 1. Evidence card

| 项 | 记录 |
|---|---|
| revision / worktree | `03c1252`，`git status --porcelain` 为空 |
| dependency / runtime | 系统 `sqlite3` 3.54.0；测量脚本 Python 3.53.1；Sparkle 2.10.1；macOS 27.3 |
| 点名入口 | `FileIndexDatabase.query(_:) throws -> FileIndexQueryResult`，`Sources/MiscKitCore/Files/Index/FileIndexDatabase.swift:519` |
| 实际 callers | `FileIndex.search(term:request:)` `FileIndex.swift:534` → `FileSearchService.searchIndex(term:request:)` `FileSearchService.swift:65` → `FileSearchModel.run(query:token:)` `FileSearchModel.swift:349` ← `update(query:)` `FileSearchModel.swift:108`（90ms 去抖） |
| selected vs adjacent | 选中 `rankingGroups(folded:)` `FileIndexDatabase.swift:579`；相邻实现是 `termFilter` `:642` 与 Spotlight 兜底 `FileSearchService.searchSpotlight`（本次未改） |
| capacity / batch | `countCap = 1000` `:498`；`limit = 80`；索引 5 个（path UNIQUE、stage/name 等） |
| concurrency | reader / writer 两个连接；WAL；全量重建 `keepServing=true` 时旧表继续服务 |
| output boundary | 最多 80 行；总数有上限；`totalIsExact` 区分精确/下限 |
| error boundary | SQL 抛错 → `searchIndex` 兜底到 Spotlight；候选不改错误路径 |
| DB 体积 | 244,152 页 × 4096 B = 999,950,592 B（文件 954 MiB） |

### 1.1 字面状态转移（不是估算）

| 对象 | 旧值 / 操作 | 代入 | 新值 |
|---|---|---|---|
| 前缀段 SQL | `name_folded LIKE 'report%' ESCAPE '\'` | 计划 `SCAN entries USING INDEX idx_stage_name` | 访问 753,051 条索引项 → 315 个前缀命中 → 返回 81 行 |
| 前缀段候选 | `name_folded GLOB 'report*'` | 计划 `SEARCH entries USING INDEX idx_stage_name (name_folded>? AND name_folded<?)` | 只访问前缀区间（315 个命中 + 边界）→ 返回 81 行 |
| 总数 | `SELECT COUNT(*) FROM (SELECT 1 ... LIMIT 1001)` | `report` 共 1,041 命中 | 扫描 753,051 行才确认 1001 个 → 45.9ms（Python）/ 49.7ms（系统 3.54） |
| 总数上限 | 同上，`LIMIT 201` | 第 201 个命中即停 | 9.7ms；`total` 从 `1000` 变 `200`（显示语义变化） |
| 中文前缀 | `合同`：前缀 31、包含 1,820 | `LIKE '合同%'` 全扫 25.0ms；`GLOB` 0.04ms | 候选整条 0.6ms vs 当前 25.2ms |

> 源码注释 `FileIndexDatabase.swift:577` 说「前两段能吃索引范围」。实测
> 第一段（等值）能吃；**第二段 `LIKE 'x%'` 在默认 `case_sensitive_like=0`
> 且带 `ESCAPE` 时是 `SCAN`，不是 `SEARCH`**。这是本次最大的机制发现。

---

## 2. 现场事实（只陈述，不当成延迟结论）

1. **索引文件 954 MiB，其中约 480 MiB 是空闲页**
   - 753,051 行快照：`freelist_count=123,027` → 503,918,592 B（480.6 MiB，52.7%）。
   - 608,928 行快照：`freelist_count=144,031` → 590,078,976 B（562.7 MiB，59.0%）。
   - `FileIndex.swift:265-267` 只在 `!keepServing` 时调用 `reclaimSpaceIfNeeded()`；
     后台重建走 `keepServing=true`（`:185`、`:246`），因此重建后不 VACUUM。
2. **一次后台全量重建约 30 分钟**
   - meta：`rebuilding=1795397350`（09:29:10）→ `full_scan_completed_at=1795399152`（09:59:12），
     `full_scan_row_count=753,337`；实测 30m02s。
   - 每 1,500 行暂停 8ms（`:246`）：502 批 × 8ms = **4.0s**，只占 0.2%；
     其余约 29m58s 是逐文件元数据读取/调度成本。触发原因未知（非启动）。
3. **历史真实查询里有 512–549ms**
   - `2026-11-20 17:06:54 file.search count=32 ms=549 termLen=40 up=4s via=index`
   - `2026-11-20 17:11:28 file.search count=3 ms=512 termLen=39 up=278s via=index`
   - 同长度下一次 19–24ms；说明慢查询不是稳定常数，冷缓存/查询形状/并发重建都可能参与。
4. **内存稳定**：日志 `mem=40–55MB`；`ps` 观察 55–66MB，无增长证据。
5. **已有预算口径**：`ClipboardWatch.swift:112`「唤起预算 ≤100ms，实测基线 36–42ms」；
   `CHANGELOG.md:64`「常见关键词 20ms 内出结果，最慢不超过 100ms」。

---

## 3. Delta dossier（D1：相关性前缀段 GLOB）

| 字段 | 内容 |
|---|---|
| mechanism | 默认 `LIKE` 大小写不敏感且带 `ESCAPE`，SQLite 不能把它降为 B-tree 区间；`GLOB` 对折叠后的 `name_folded` 是大小写敏感，前缀模式可走 `idx_stage_name` 的 `SEARCH` 区间 |
| delta fingerprint | SQL 文本：`rankingGroups` 第二段 `LIKE ? ESCAPE '\'` → `GLOB ?`；排序 `name_folded ASC` → `name_folded ASC, id ASC`；其余 SQL、参数、limit、countCap、连接 pragma 不变 |
| touched boundaries | `FileIndexDatabase.query` 的 relevance 分支；`select(order:)` 的 name 排序；`rankingGroups`；不触碰 termFilter、baseFilter、writer、scanner |
| protected semantics | 结果 path 集合、`name_folded` 主序、并列定序、去重、80 行上限、`total`/`totalIsExact`、错误路径、空结果 |
| baseline characterization | 16 条核心查询 + 12 条边界查询；每条先跑一遍预热，再交替测 9 次；`current` 与 `ref` 的差异只出现在 `scope_home_report` 的同名并列顺序 |
| minimum counterexample | `uppercase_Report`：候选若不做 `FileIndexText.fold`，`GLOB 'Report*'` 对全小写数据 0 命中，参考实现有结果 → oracle 必须报错 |
| mutant sensitivity | M1 未折叠：`uppercase_Report` 检出 1/1；M2 未转义 `[`：查询 `[` 参考 80 行、mutant 0 行，检出 1/1 |
| state | **ACCEPT**（仅 SQL/DB 边界、仅上述 workload） |

### 3.1 语义矩阵

| 维度 | 保护内容 | 参考实现（current + id 定序） | GLOB 候选 | 结果 |
|---|---|---|---|---|
| content / cardinality | path 集合与行数 | 16/16 核心、12/12 边界 | 同左 | 一致 |
| ordering / duplicates | `name_folded` 主序；并列按 `id`；按 path 去重 | 显式 `ORDER BY name_folded, id` | 同左 | 一致 |
| identity / aliasing | `FileIndexEntry.path` 为身份 | 同一 path 集合 | 同左 | 一致 |
| time / visibility | 无缓存、无时间窗口 | 只读 SELECT | 同左 | 一致 |
| state / side-effect | 查询无写入 | 无 | 无 | 一致 |
| empty / unknown | 0 命中、未知扩展名 | 返回 0 / total 0 | 同左 | 一致 |
| error / partial | SQL 错→throw→Spotlight 兜底 | 同路径 | 同左 | 一致 |
| configured output | limit 80、countCap 1000、`totalIsExact` | 同 | 同 | 一致 |
| case / diacritics | 先 `fold`，数据全小写 | `name_folded` 无 A–Z（实测 0 行） | GLOB 大小写敏感但输入已折叠 | 一致 |
| wildcard | `hasWildcard` 不进 relevance 分段 | LIKE 路径 | 不触碰 | 一致 |
| filters | category / folder / ext / scope | 5 种组合 | 同左 | 一致 |

> 并列定序为什么必须写进候选：当前 SQL 只写 `ORDER BY name_folded`，
> `scope_home_report` 上 `current` 与 `ref` 出现两条同名文件互换；这不是
> 候选引入的差异，而是当前排序本身依赖计划/临时 B-tree，不能作为契约。
> 候选把 `id` 写进 ORDER BY，使 oracle 可以做逐行全等比较。

### 3.2 Oracle 与 mutant

- **参考实现**：当前 SQL + `ORDER BY ..., id`（只加确定性并列键，不改谓词）。
- **候选**：`GLOB` 前缀 + `ORDER BY ..., id`；`instr` 为可选的第二 delta。
- **核心矩阵**：16/16 的 `(10 列行元组, total, totalIsExact)` 完全相等。
- **边界矩阵**：12/12 完全相等（`[`、`]`、`a[1]`、`a_b`、`_test`、`%`、
  `café`、`CAFÉ`、`*`、`?`、`合同`、含空格短语）。
- **mutant M1**：候选跳过 `fold` → `uppercase_Report` 检出。
- **mutant M2**：`globPrefix` 不转义 `[` → 查询 `[` 参考 80 行、mutant 0 行检出。

---

## 4. 已测 artifact 链

### 4.1 两份快照

| 快照 | 行数 | 文件 | SHA-256 前 16 | 状态 |
|---|---|---|---|---|
| S1 | 608,928 | 954 MiB | `3e52075f85bf0ec7` | 后台重建进行中，旧表对外服务 |
| S2 | 753,051 | 954 MiB | `459fa3f042fde846` | 重建完成后 |

### 4.2 配对 A/B（S2，753k 行；单位 ms，9 次中位）

| 查询 | current | GLOB | 加速 | S1 加速 |
|---|---:|---:|---:|---:|
| `report` | 73.6 | 49.0 | 1.50x | 1.77x |
| `screenshot` | 66.4 | 43.1 | 1.54x | 1.55x |
| `zzqxjv`（0 命中） | 61.0 | 37.3 | 1.64x | 1.64x |
| `合同` | 25.2 | 0.6 | 40.97x | 39.33x |
| `会议纪要` | 33.0 | 8.2 | 4.03x | 4.55x |
| `报价 2026` | 100.6 | 50.5 | 1.99x | 2.00x |
| `final report` | 85.0 | 42.6 | 1.99x | 1.92x |
| 40 字符稀有串 | 77.2 | 53.4 | 1.45x | 1.44x |
| `Report`（大写） | 71.7 | 48.3 | 1.48x | 1.74x |
| `rep*`（通配） | 28.7 | 28.9 | 0.99x | 1.05x |
| `category=image` | 6.2 | 5.9 | 1.06x | 1.06x |
| `folder only` | 80.0 | 57.6 | 1.39x | 1.38x |
| `ext:pdf` | 68.5 | 43.6 | 1.57x | 1.60x |
| `scope=folders`（home 兜底） | 381.1 | 197.3 | 1.93x | 1.90x |
| `sort=modified` | 56.0 | 55.7 | 1.01x | 1.00x |
| `report -tmp` | 98.1 | 49.2 | 1.99x | 2.21x |

**读法**：
- 加速集中在 relevance 三段排序里；通配、非 relevance 排序、category 单过滤不受影响（符合预期）。
- 中文前缀一旦 `GLOB` 直接区间命中，省掉了原来必然发生的一次全索引扫描，所以数字大；
  这不代表中文整体快 40 倍，只代表「前缀段」这一段的代价被移除。
- `scope=folders` 仍 197ms：剩余成本在 contains/计数与 path 过滤（§5 D5），这里只证明前缀段被移除。
- 门槛口径：`CHANGELOG.md:64` 的 ≤100ms 是既有发布预算；本次未在采样前登记新的倍数门槛，
  因此 1.38–2.21x 只作为机制证据，不当作发布门槛。

### 4.3 单语句交叉验证（系统 sqlite3 3.54.0，app pragma）

| 语句 | 时间 |
|---|---:|
| `SELECT ... GLOB 'report*' ORDER BY name_folded,id LIMIT 81` | 0.035ms |
| `SELECT ... LIKE 'report%' ESCAPE '\' ORDER BY name_folded LIMIT 81` | 34.7ms |
| `SELECT COUNT(*) ... instr(...) LIMIT 1001` | 45.4ms |
| `SELECT COUNT(*) ... LIKE '%report%' LIMIT 1001` | 49.7ms |
| `SELECT COUNT(*) ... GLOB 'report*'`（索引内计数） | 0.052ms |

`instr` 在 3.54 上比 `LIKE '%x%'` 快约 8–14%，与 3.53 的 5–35% 同向；作为次要 delta。

### 4.4 噪声与漂移

- S1 两次独立运行：多数查询中位漂移 <8%；`long_40_rare` 26%、`folder_only` 23%、
  `category_image` 14%（绝对量 6ms 的小基数）。S2 的比值与 S1 同向，故用「两次快照的
  区间」而非单次小数。
- 每臂原始样本（9 个）保存在 `docs/bench/results-753k.json` / `results-609k.json`；
  没有只留汇总。
- 运行环境为共享桌面，测量期间另有后台索引重建（S1）；S2 在重建结束后复测，结论未反转。

---

## 5. 候选账本（含被反证项）

| ID | 候选 | 状态 | 证据 / 原因 |
|---|---|---|---|
| D1 | relevance 前缀段 `LIKE` → `GLOB` | **ACCEPT** | §3、§4：语义 28/28、1.38–2.21x、中文 39–41x |
| D2 | contains 谓词 `LIKE '%x%'` → `instr(...)` | **ACCEPT（次要，可选）** | 3.54 上 8–14%，3.53 上 5–35%；语义矩阵一致；不改变索引计划 |
| D3 | 排序并列键 `id` | **ACCEPT（伴随）** | 只把当前不稳定的并列顺序变成确定顺序；计划仍是 `idx_stage_name`，无额外排序；代价在噪声内 |
| D4 | `countCap` 1000 → 200 | **DESIGN_REQUIRED，不授权** | 实测候选：`report` 43.8→10.8ms、`会议纪要` 7.5→2.6ms、`scope_home` 200.4→22.7ms；但显示从「1000+」变「200+」，是产品契约变更 |
| D5 | `scope=folders` 的 path OR / contains 全扫 | **DESIGN_REQUIRED，不授权** | 候选后仍 197ms；剩余是 path 过滤 + contains/计数扫描；需要 FTS5 trigram、覆盖索引或 count 契约一起设计 |
| D6 | 954 MiB 文件 / 480 MiB 空闲页 | **FACT；延迟 EVIDENCE_REQUIRED** | `freelist_count` 直接读取；对 B-tree 扫描无直接证据；建议空闲 VACUUM 或 incremental auto_vacuum，先测写放大/耗时 |
| D7 | 启动即跑全盘 Spotlight 探针 | **EVIDENCE_REQUIRED** | `AppDelegate.swift:58` 调用；`probeSpotlight` 1.5s 全盘 `NSMetadataQuery`；文件搜索未用也会跑。需 launch trace 才能授权删除 |
| D8 | panel 唤起 / 首帧 | **EVIDENCE_REQUIRED** | 只有注释预算与历史 36–42ms，没有本次 artifact；见 §6 合同 |
| D9 | `LauncherView.results` 多次重算 + `FileQueryParser` 每次枚举卷 | **EVIDENCE_REQUIRED** | `LauncherView.swift:94` 计算属性在 body 中被引用 10+ 次；`FileSearchModel.swift:376` / `:105` 每次构造 parser，`FileQuery.swift:133-146` 枚举挂载卷。可能 1–5ms，未测 |
| D10 | 全量重建 30 分钟 | **EVIDENCE_REQUIRED** | meta 时间戳 + 753,337 行；批间暂停仅 4.0s，剩余是逐文件元数据；先加批级 signpost，再考虑 `getattrlistbulk` |
| D11 | 内存 | **无问题证据** | 40–66MB 稳定；不做改动 |
| D12 | 冷缓存首查 | **EVIDENCE_REQUIRED** | 历史 549/512ms 是冷/异常样本；本次全部热缓存；需 purge/重启合同 |
| — | `LIKE` 前缀「能吃索引范围」的源码注释 | **REJECT（文档错误）** | `EXPLAIN` 明确 `SCAN`；应随 D1 修正注释，避免后人再踩 |

---

## 6. 仅 ACCEPT 的实施步骤（D1 + D2 + D3）

### 6.1 代码改动

`FileIndexText` 增加：

```swift
static func globPrefix(_ text: String) -> String {
    var out = ""
    for ch in text {
        if ch == "*" || ch == "?" || ch == "[" || ch == "]" {
            out += "[\(ch)]"   // GLOB 字符类转义：[*] [?] [[] []]
        } else {
            out.append(ch)
        }
    }
    return out + "*"
}
```

`rankingGroups(folded:)` 第二段改为：

```swift
("name_folded GLOB ?", [.text(FileIndexText.globPrefix(folded))])
```

`termFilter` 的可选 D2（仅 `!term.hasWildcard`）：

```swift
let folded = FileIndexText.fold(term.text)
filter.append(term.isNegated
    ? "instr(name_folded, ?) = 0"
    : "instr(name_folded, ?) > 0",
    [.text(folded)])
```

`select(order:)` 的 name 排序统一加并列键：

```swift
"name_folded ASC, id ASC"
"COALESCE(modified, 0) DESC, name_folded ASC, id ASC"
"COALESCE(created, 0) DESC, name_folded ASC, id ASC"
"COALESCE(size, 0) DESC, name_folded ASC, id ASC"
```

### 6.2 守卫（必须先失败，再放行）

1. **语义守卫**：新增 fixture 测试，旧 `LIKE` 三段排序作为测试专用参照，对 20 条查询
   比较 `entries.map(\.path)`、`total`、`totalIsExact`；任一不等 → `REJECT`。
   覆盖：大写、`[`、`]`、`_`、`%`、`*`、`?`、中文、带空格短语、`scope=folders`、`ext:`、`folder:`。
2. **性能守卫**：在 ≥60 万行快照上跑本目录脚本；D1 在 16 条核心矩阵中
   `median(glob) < median(current)`，且 non-relevance/通配行不得回归超过 5%。
3. **计划守卫**：`EXPLAIN QUERY PLAN` 必须出现
   `SEARCH entries USING INDEX idx_stage_name (name_folded>? AND name_folded<?)`；
   若仍是 `SCAN`，说明该 SQLite 版本没吃到 GLOB 区间 → `REJECT`，不要上线。
4. **回滚条件**：任一语义不等、任一非目标查询 >5% 回归、或 `scope=folders` 结果集变化 →
   `RESTORE` 到原 `LIKE` 三段实现。

### 6.3 明确不授权

- D4 countCap、D5 FTS/覆盖索引、D6 VACUUM、D7 启动探针、D8–D10 任何 panel/UI/扫描改动，
  在没有新的同合同 artifact 前不得实施，也不得在周报里写成「预计提升 X%」。
- 本次 ACCEPT 不覆盖冷缓存、端到端、真实用户输入分布；只覆盖 §0 的 workload。

---

## 7. 未验证项的最小实验合同

### 7.1 端到端「按键 → 首帧」

- **插桩**：`os_signpost`，subsystem `app.misckit.launcher`：
  - `panel.hotkey` → `panel.show.begin` → `panel.show.end`（`PanelController.show` 返回）
  - `panel.firstFrame`：`orderFront` 后 `CATransaction` completion / 下一次 display
  - `file.query.begin/end`（`FileIndex.search`）
  - `file.ui.commit`（结果数组赋值后的首个 CATransaction completion）
- **workload**：Release 包；30 次唤起/关闭（间隔 3s）；4 类查询各 10 次：
  `report`、`报价 2026`、`合同`、`scope=folders` + `report`；前 3 轮预热，第 4 轮取样本。
- **门槛**：panel `p95 ≤ 100ms`（来源：`ClipboardWatch.swift:112`）；
  file query `p95 ≤ 100ms`（来源：`CHANGELOG.md:64`）；端到端 p95 作为**待产品确认**的
  新指标，不预先写成结论。
- **停止/重测**：同一 fingerprint（release build、无重建、同一 DB 快照、同一查询集）；
  p95 两轮差异 >20% → `REMEASURE`；任何一次崩溃/超时 → `REJECT` 该轮。

### 7.2 冷缓存首查

- 重启或 `sudo purge`（需用户授权）；启动后 2s 内发第一条查询；
- 3 次冷启动 × 4 条查询；记录 page-fault / `file.search ms` / 首帧；
- 不与热缓存结果混表；冷结果单独 `EVIDENCE_REQUIRED` 收口。

### 7.3 count 上限（D4）

- 这是产品契约，不是纯性能：先确认「1000+」是否可改为「200+」；
- 若可，按 D4 的表复测 UI 文案与 `totalIsExact`，再走 D1 相同的语义/性能守卫；
- 若不可，考虑「先返回 80 行 + 后台精确计数」两阶段，不阻塞首屏。

### 7.4 启动探针（D7）与全量扫描（D10）

- D7：10 次冷启动，A/B「保留 / 延后到首次文件搜索」，测 `didFinishLaunching` 到首次
  `panel.show`、启动后 10s 的 CPU/IO；不改逻辑先测。
- D10：在 `performFullScan` 每批打 signpost（batch index、rows、elapsed），连续 3 次重建；
  若单批 >50ms 或总时长 >10min，再评估 `getattrlistbulk`。

---

## 附录 A：复现

```bash
# 1) 一致性快照（只读，不影响正在运行的 app）
sqlite3 -readonly "$HOME/Library/Application Support/MiscKit/index.sqlite3" \
  ".backup '$HOME/.cache/misckit-bench/snapshot.sqlite3'"

# 2) 跑 A/B（默认 5 臂 × 9 次，输出 JSON）
cd docs/bench
BENCH_DB="$HOME/.cache/misckit-bench/snapshot.sqlite3" \
BENCH_OUT="$HOME/.cache/misckit-bench/result.json" \
python3 file-index-query-ab.py

# 3) 看计划
sqlite3 -readonly "$HOME/.cache/misckit-bench/snapshot.sqlite3" \
  "EXPLAIN QUERY PLAN SELECT path FROM entries
   WHERE name_folded GLOB 'report*' ORDER BY name_folded, id LIMIT 81;"
```

## 附录 B：证据文件

| 文件 | 内容 |
|---|---|
| `docs/bench/file-index-query-ab.py` | 5 臂 A/B + oracle + mutant 的复现脚本 |
| `docs/bench/results-753k.json` | 753,051 行快照的原始样本、计划、facts |
| `docs/bench/results-609k.json` | 608,928 行快照的原始样本（第一次复测） |
| `docs/bench/runtime-log-evidence.txt` | `file.phase` / `file.search` 历史日志 |
| `docs/performance-review-2026-11-23.md` | 本文 |

## 附录 C：本次没有做的事

- 没有改任何生产代码、数据库或用户设置。
- 没有跑 Instruments、没有 purge 缓存、没有启动第二实例。
- 没有把 SQL 改善外推到 panel、SwiftUI、冷启动或 Spotlight 兜底路径。
- 没有给未验证候选排优先级；账本里的 `DESIGN_REQUIRED` / `EVIDENCE_REQUIRED` 不是「建议先做」。
