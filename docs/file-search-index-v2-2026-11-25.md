# 文件索引 v2：FTS5、索引瘦身与并行扫描（2026-11-25）

把 2026-11-23 性能复盘里排出的六项一次做完。目标不是把 MiscKit 做成 Everything，
而是让 100 万行规模下的包含匹配和计数不再随行数线性变慢。

## 改了什么

1. **空间回收不再只在冷启生效**
   `reclaimSpaceIfNeeded()` 原先只在 `!keepServing` 分支调用，后台重建永远不 VACUUM，
   1.35GB 的库里躺着约 665MB 空页。现在由 `scheduleMaintenance()` 接管：等 20 秒没有查询、
   没有重建/增量在跑，再 VACUUM；checkpoint 失败不阻塞回收。

2. **计数上限 1000 → 300**
   与 `resultLimit` 对齐。多数的那个数字本来也翻不到第 301 条，省下的是每次搜索几十毫秒。
   底栏文案仍是「300+」，不会出现假精确值。

3. **包含段接 FTS5 trigram**
   新增 `name_fts`（contentless + `contentless_delete=1`，trigram，列：name/pinyin/initials）。
   `FileIndexDatabase` 负责增量写入（与正式表同一事务）、子树交换补丁、整库交换后清空重建；
   `FileIndex` 用 `isFTSReady` 统一读写四条连接的口径，重建期间自动回退 `instr`。

4. **索引瘦身**
   五棵索引（name + kind + modified/created/size 三棵复合）砍到两棵：
   `name_folded`、`(modified DESC, name_folded)`。created/size 排序改在候选集上排，
   候选集本来只有几百条。版本号 `index_definition_version = 3`，旧库打开时整套换掉。

5. **能力补齐**
   - `path:src/main` 与路径直达失败后的回退：只搜完整路径，不再只给一句“路径不存在”。
   - `in:~/Downloads` 作用域。
   - 汉字名的拼音全拼与首字母（`会议纪要` → `huiyijiyao` / `hyjy`），只对含汉字的 3.7% 条目计算。
   - `~rpt` 子序列模糊（`%r%p%t%`）。
   - `re:/pattern/i` 正则：先取模式里最长的一段必有字面文本走 FTS/instr 预筛，
     再用 NSRegularExpression 精筛；没有字面锚点时明确提示，不拿全表跑正则。

6. **并行扫描**
   顶层目录先切两层成扫描单元，最多 4 个 worker 从共享队列领取，写库仍由 actor 串行。
   进度与取消语义不变，批次 1500 条不变。

## 实测

在一份 1,004,857 行的真实索引副本上测（`sqlite3` CLI、热页缓存、新 schema + FTS）。
副本没有写拼音列，真实库会多出几 MB。

| 查询 | 改造前 | 改造后 |
|---|---|---|
| `report` 包含计数（上限 301） | 33–41ms（`instr`） | **0.5–1.4ms**（FTS） |
| `report` 取 300 条按名字序 | 33.8ms（`instr`） | **1.2–1.9ms**（FTS） |
| `test` 常见词计数 | — | 3.9ms |
| `test` 常见词取 300 条 | — | 13.5ms |
| 前缀 `report*` 计数 | 0.1ms | 0.1ms（没变） |
| 2 字中文 `合同` 计数 | 71.8ms | 71.8ms（FTS 不支持，回退 `instr`） |

库体积：1.35GB → **672MB**（VACUUM 后；真实库含拼音与两棵索引，预计 680–700MB）。
1M 行 FTS 全量重建 19.1 秒，分 20k 一块写，WAL 不会一次撑大。

## 边界

- FTS trigram 至少 3 个字符：2 字中文、2 字拼音首字母仍走 `instr`（约 70ms）。
- 拼音只覆盖汉字名，英文名不生成，避免百万行白算 ICU。
- 模糊模式是显式 `~`，接受一次全表 LIKE；正则必须能抽出 ≥2 字的字面锚点。
- `in:` / `path:` / `re:` 这些语法不带 `file` 前缀也会切到文件搜索面板。

## 升级行为

升级后首次启动会整库重建一次：并行扫描 + 建索引 + 建 FTS。重建期间旧的（现在是空的）
索引不服务，随后 FTS 在后台补齐；补齐前包含段回退 `instr`，结果仍然正确，只是慢。
重建完成后的空闲窗口会自动 VACUUM，把旧表和旧索引腾出的页还回去。
