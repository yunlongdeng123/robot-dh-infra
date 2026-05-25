# `robot-dh-multisource-scale30-dls4z` 完整 step log 归档

> 来源：`s3://robot-dh-artifacts/argo-logs/robot-dh/robot-dh-multisource-scale30-dls4z/`（Argo `archiveLogs`）
> 拉取时间：2026-05-24 19:54 CST
> 大小：5 个 step pod，总 11.16 KiB

## 时间线（按 step pod 创建时间排序）

| 顺序 | step | pod 文件名 | 状态 | 关键事件 |
|------|------|-----------|------|----------|
| 1 | lake-list | `lake-list.3736841068.log` | ✓ OK | `s3://robot-lake/` 只有 1 个 raw 对象，slices 空（workflow 启动 inventory） |
| 2 | qc-contract-run | `qc-contract-run.149848334.log` | ⚠ WARN（不阻塞） | `traj_len_p50=314`（**未识别 episode_idx 多 episode 切分**），`language_missing_rate=1.0`，`action_column_coverage=1.0` |
| 3 | partition-plan | `partition-plan.332445971.log` | ✓ OK（但有 hint） | 单 partition 单 shard，`estimated_rows=931394`（**严重高估**，实际 314） |
| 4 | etl-phase 第 1 次 | `etl-phase.4145881001.log` | ✗ FAIL | job_id `etl-run-...-c403d410`，duration 792.4s，FAIL at `normalize.load_bundles` |
| 5 | etl-phase 第 2 次 | `etl-phase.1528822700.log` | ✗ FAIL | job_id `etl-run-...-3fa1ac19`，duration 717.3s，**同一位置同一错误**；尽管 `resume=True`，第 2 次仍然完整重做 `materialize_input`（227 MiB 重下） |

## 关键发现（按 step 串起来）

### A. normalize adapter schema mismatch（直接致 FAIL）

两次 etl-phase 都在 `normalize.load_bundles` 抛 `ValueError: bridgedata_v2 adapter could not extract any pose episode`，根因：raw 是 `mbodiai/oxe_bridge_v2` 变体的嵌套 `action: struct<pose, grasp>`，而 adapter 期望扁平 7-float array。详见 `docs/v1_6_bridgedata_v2_normalize_adapter_request.md` §2 / §3。

### B. QC contract 阶段同样没识别嵌套 schema（不致 FAIL 但产出失真）

`qc-contract-run.149848334.log` 报：

- `traj_len_p50 = traj_len_p95 = 314` — 把整个 parquet 当成 1 条 trajectory，没按 `episode_idx` 切分（实际 3 个 episode，131/108/75 步）
- `language_missing_rate = 1.0` — `state.language_embedding` 在嵌套 `list<double>` 里，QC 读取路径没穿透 struct

→ **`qc_contracts` 里 `bridgedata_v2_v1` contract 的 traj_len / language coverage 规则需要适配嵌套 schema**，否则即便 normalize 修了，下游 contract gate 报表里 `language` 仍然显示 100% missing，统计学口径错位。

### C. `resume=True` 在 normalize 阶段未生效（导致 7+ 分钟 IO 浪费）

两次 etl-phase 都打印 `resume=True force=False`，但第 2 次仍然 `materialize_input` 重下 227 MiB（10:59:07 → 11:10:59，耗时 11min 53s）。workdir 路径不同（`-6ft_moqx/` → `-16hgbar3/`），说明前次失败时 step container 的 `/run/robot-dh/workdir/...` 已经被清理，resume 判断只看本地 workdir + heartbeat，没看 ods 端 `_manifest.json` 是否已经存在。

→ resume 语义建议：**优先看 `s3://robot-lake/ods/<dataset>/<version>/_manifest.json` 是否已存在 + `materialize_input.done` 标记**，能跳过整个 materialize_input 阶段。

### D. partition-plan 估算严重失真（minor）

`estimated_rows=931394` vs 实际 314。partition planner 用了 `total_input_bytes / avg_row_size` 但 avg_row_size 估算没考虑 image bytes 占绝大部分（227 MiB 中 image > 99%）。Bridge 单 shard 实际是 ~314 行而不是 90 万行，不影响这条 workflow 的单 partition 决策，但 scale 上去会误判并发度。

## 文件列表

```text
docs/runs/20260524/robot-dh-multisource-scale30-dls4z/
├── INDEX.md                              # 本文件
├── lake-list.3736841068.log              # 170 B
├── qc-contract-run.149848334.log         # 671 B
├── partition-plan.332445971.log          # 1.1 KiB
├── etl-phase.4145881001.log              # 4.6 KiB （第 1 次 FAIL）
└── etl-phase.1528822700.log              # 4.6 KiB （第 2 次 FAIL）
```

文件命名约定：`<step-name>.<argo-pod-hash>.log`，可与 Argo UI / `s3://.../argo-logs/.../<pod-name>/main.log/main.log` 双向定位。
