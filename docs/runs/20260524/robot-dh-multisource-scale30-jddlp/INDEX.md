# `robot-dh-multisource-scale30-jddlp` 完整 step log 归档

> 来源：`s3://robot-dh-artifacts/argo-logs/robot-dh/robot-dh-multisource-scale30-jddlp/`（Argo `archiveLogs`）
> 拉取时间：2026-05-24 22:32 CST
> 大小：5 个 step pod，总 31.45 KiB
> 上一条 workflow：[`robot-dh-multisource-scale30-dls4z`](../robot-dh-multisource-scale30-dls4z/INDEX.md)（5 类错误：A/B/C/D/E）

## 时间线（按 step pod 创建时间排序）

| 顺序 | step | pod 文件名 | 状态 | 关键事件 |
|------|------|-----------|------|----------|
| 1 | lake-list | `lake-list.623652825.log` | ✓ OK | `s3://robot-lake/` 仅 raw 1 个对象，slices 空 |
| 2 | qc-contract-run | `qc-contract-run.1491557645.log` | ✓ **PASS（修复确认）** | `traj_len_p50=108`、`traj_len_p95=131`、`language_missing_rate=0.0`、`episode_count=3` ← dls4z 的 B 类已修 |
| 3 | partition-plan | `partition-plan.1987402368.log` | ✓ OK（**修复确认**） | `estimated_rows=314` 与真实 `parquet.num_rows=314` 完全一致 ← dls4z 的 D 类已修 |
| 4 | etl-phase 第 1 次 | `etl-phase.3033229424.log` | ✗ FAIL（**新 root cause**） | job_id `...-a7fcf7d3`，duration 640.86s，业务 `status=OK` 但 perf record 写 PG 抛 `V15SchemaMissingError`；adapter 一行日志确认 dls4z 的 A 类已修：`bridgedata_v2 adapter[...]: matched nested oxe_bridge_v2 schema (state.end_effector_pose), 3 episodes` |
| 5 | etl-phase 第 2 次 | `etl-phase.2697529949.log` | ✗ FAIL（**同一新 root cause**） | job_id `...-d8ac7e58`，duration 0.90s，`normalize SKIP: ods 已有 manifest` ← dls4z 的 C 类（resume）已修；同样在 perf record 写 PG 抛 `V15SchemaMissingError` |

## 关键发现（按 step 串起来）

### A. **新 root cause：`etl_perf_runs` 表缺 `started_at` / `finished_at` 列（直接致 step FAIL）**

两次 etl-phase 都在业务 `etl_run END status=OK` 之后，由 `emit_perf_records` → `record_etl_perf_run` 抛：

```text
warehouse record_etl_perf_run schema mismatch:
  (psycopg.errors.UndefinedColumn) column "started_at" of relation "etl_perf_runs" does not exist
[SQL: INSERT INTO etl_perf_runs (..., started_at, finished_at, metrics_json, created_at) VALUES (...)]
robot_dh.warehouse.service.V15SchemaMissingError: ...
  Apply the matching schema migration in the infra project first.
```

`infra` 端实际表（`docker exec robot-dh-postgres psql ... -c '\d etl_perf_runs'` 实测）：

```text
job_id, run_id, dataset_id, version, phase, input_uri, output_uri,
input_bytes, output_bytes, input_rows, output_rows,
duration_sec, download_duration_sec, upload_duration_sec, compute_duration_sec,
peak_memory_mb, worker_id, status, error_message, metrics_json, created_at
```

**缺失**：`started_at timestamptz` / `finished_at timestamptz`。

主项目 ORM 已经在写这两列（见 `etl-phase.3033229424.log` L24 的 INSERT 列表），infra 端 002 创建表时没有这两列，003/004/005 也没有补；这是典型的 schema 漂移，**与 v1.5 `etl_shards` / `benchmark_*` 的对齐套路相同**（参见 [`docs/v1_5_benchmark_align_handoff.md`](../../../v1_5_benchmark_align_handoff.md)）。

引发的副作用：

- `emit_perf_records` 抛 `V15SchemaMissingError`，CLI 进程退出码非 0 → step pod FAIL → workflow FAIL
- 即使第 2 次 etl-phase 因 ods manifest 已经存在直接 SKIP（耗时 0.90s），仍然要执行 perf record 写入，仍然 FAIL
- 业务工件**已经全部写入** `s3://robot-lake/ods/bridgedata_v2_scale30/v1/`（`output_bytes=39769`、`output_rows=318`、`_manifest.json` 已落），下游 contract gate / OpenLineage / 后续 transform step **可以读取这份产物**——但是 Argo 端会因为 step FAIL 不会跳到 transform，需要人工把 etl-phase 标 success 或者重启 workflow 后跳过 normalize。

→ **修复责任**：infra 端按主项目字段清单补 `006_v1_6_etl_perf_runs_align.sql`；同时主项目应在新需求文档（[`docs/v1_6_etl_perf_runs_schema_align_request.md`](../../../v1_6_etl_perf_runs_schema_align_request.md)）确认字段集合 + 是否考虑把 perf record 写失败软降级。

### B. **dls4z 的 5 类错误已全部修复**（对账确认）

| 错误（dls4z） | 现象 | jddlp 状态 | 证据 |
|------|------|-----------|------|
| A. adapter 不识别嵌套 schema | `bridgedata_v2 adapter could not extract any pose episode` | ✅ 已修 | `etl-phase.3033229424.log` L11：`matched nested oxe_bridge_v2 schema (state.end_effector_pose), 3 episodes`，2.9s 完成 load_bundles |
| B. qc-contract 嵌套字段穿透 | `traj_len_p50=314`、`language_missing_rate=1.0` | ✅ 已修 | `qc-contract-run.1491557645.log`：`status=PASS`、`traj_len_p50=108`、`traj_len_p95=131`、`language_missing_rate=0.0`、`episode_count=3` |
| C. resume=True 不生效，重做 materialize_input | 第 2 次 11min53s 重下 227 MiB | ✅ 已修 | `etl-phase.2697529949.log` L4：`normalize SKIP: s3://robot-lake/ods/.../v1 already has manifest; pass force=True to rerun`，整段 etl_run 0.90s |
| D. partition-plan estimated_rows 误差 ~3000× | `estimated_rows=931394` vs 真实 314 | ✅ 已修 | `partition-plan.1987402368.log`：`estimated_rows=314`，与真实 `parquet.num_rows=314` 一致 |
| E. botocore connection pool full | 5 次 `Connection pool is full` WARNING | ✅ 已修 | 第 1 次 etl-phase 拉 227 MiB / 9 文件 / concurrency=8 全程无 `Connection pool is full` 日志（只是带宽本身偏低，~0.36 MiB/s，下行外网到 MinIO，不在本次问题域） |

→ 主项目 v1.6 修复 PR 已经把 dls4z 的 5 类问题全部消化，端到端 normalize 业务路径**第一次跑通**，曝出了被前 5 类错误掩盖的 schema 漂移（A 类）。

### C. 第 1 次 etl-phase 仍然完整 download 227 MiB（语义符合预期，不是 bug）

```text
14:16:35  materialize_input.start
14:27:09  materialize_input.input_dir / done   (耗时 10min 34s)
14:27:12  load_bundles done                    (3 episodes)
14:27:15  write_manifest done → etl_run END status=OK duration=640.86s
```

第 1 次 normalize 是首跑，ods 还没有 `_manifest.json`，所以 materialize_input 必跑——这与 dls4z 的 C 类（第 2 次重做 materialize）**含义不同**。第 2 次 etl-phase 是 argo retry 触发，ods manifest 已经在，触发 SKIP（0.90s），证明 resume 修复已经生效。

10min34s 拉 227 MiB（~0.36 MiB/s）这个吞吐偏低，但不是 connection pool 撑不住，是带宽本身——本仓库监控的 minio 上行 / 跨 zone 链路问题，不在主项目 fix 范围。

### D. perf 写失败是否应该 abort step？（开放问题）

这是本次需求文档的次要诉求：业务 ETL 工件已经完整写入 ODS（`output_rows=318`、`_manifest.json` 已落），仅因为可观测性的 perf record 写 PG schema 漂移就让整个 etl-phase step FAIL，是否合理？

- 优点（当前 fail-loud 策略）：第一时间暴露 schema 漂移，不会让历史 perf 偷偷漏写
- 缺点：当 schema 漂移发生时，即便 ETL 业务 OK，下游 transform / contract-gate 仍然不会被 Argo 触发（因为上游 step FAIL）
- 折中建议：在主项目 perf writer 增加一个 fallback——schema mismatch 落 `s3://robot-dh-artifacts/perf-records-pending/<job_id>.json` 并继续，让业务 step exit 0；admin 后续跑 schema migration 后再批量 ingest 这批 pending records。详见需求文档 §4。

## 文件列表

```text
docs/runs/20260524/robot-dh-multisource-scale30-jddlp/
├── INDEX.md                              # 本文件
├── lake-list.623652825.log               # 170 B
├── qc-contract-run.1491557645.log        # 695 B
├── partition-plan.1987402368.log         # 1.1 KiB
├── etl-phase.3033229424.log              # 16 KiB （第 1 次 FAIL，business OK）
└── etl-phase.2697529949.log              # 13 KiB （第 2 次 FAIL，normalize SKIP）
```

文件命名约定：`<step-name>.<argo-pod-hash>.log`，可与 Argo UI / `s3://.../argo-logs/.../<pod-name>/main.log/main.log` 双向定位（与 dls4z 同款）。

## 与 dls4z 关键事件对账（一表读完）

| 维度 | dls4z（2026-05-24 早 / `fhkvr` 之后第一条） | jddlp（2026-05-24 晚 / 本次） |
|------|---------------------------------------------|------------------------------|
| etl-phase 是否走到 `etl_run END status=OK` | ❌ 没走到（A 类 FAIL 于 load_bundles） | ✅ 走到（duration 640.86s） |
| ods manifest 是否落 | ❌ 否 | ✅ 是（`output_bytes=39769`、`output_rows=318`） |
| 二次重试 materialize_input | ❌ 重做 11min53s | ✅ 跳过 0.90s |
| qc-contract 报表口径 | ⚠ 失真（traj=314、lang=1.0） | ✅ 正确（traj_p50=108、lang=0.0） |
| partition_plan estimated_rows | ❌ 931394 | ✅ 314 |
| Connection pool full warnings | ✗ 5 次 | ✅ 0 次 |
| step FAIL 真因 | adapter schema mismatch | **perf record schema mismatch（PG 缺列）** |
| FAIL 是否阻塞 ods 产物可用 | 是（无 ods 工件） | 否（ods 工件已完整落，但 Argo 不会跳到 transform） |

→ jddlp 是 **"业务 OK，可观测性 KO"** 的失败模式，下一步 fix 完全落在 PG schema 对齐 + 主项目 perf writer 容错策略。
