# `robot-dh-multisource-scale30-bxpjl` 完整 step log 归档

> 来源：`s3://robot-dh-artifacts/argo-logs/robot-dh/robot-dh-multisource-scale30-bxpjl/`（Argo `archiveLogs`）
> 拉取时间：2026-05-25 18:05 CST
> 大小：11 个 step pod，总 ~75 KiB（首条 lake-list 09:29:36 CST，最后 droid-normalize retry 17:45:59 CST）
> 上一条 workflow：[`robot-dh-multisource-scale30-fvx5z`](../robot-dh-multisource-scale30-fvx5z/INDEX.md)（robomimic hdf5 probe 持续失败 / droid-normalize 0 archive log + RUNNING 卡死 / bridge-qc duration 未收敛）

## 综述：droid-normalize 日志洞补上了，但主链路仍未到达 ml-ready

| 维度 | fvx5z | bxpjl（本次） | 趋势 |
|------|-------|---------------|------|
| `runner_boot` 首行可见日志 | 8 pod；droid-normalize 0 log | 11 pod；droid-normalize 两个 retry pod 都有 log | 向前推进，0 log 洞已暴露为业务失败 |
| droid-qc | PASS 39.75s | PASS 1.03s | 继续稳定 |
| bridge-qc metric | PASS；traj_p50=108, p95=131, episode_count=3 | PASS；traj_p50=108, p95=131, episode_count=3 | 继续稳定 |
| bridge-qc duration | 1849.99s | 1096.16s = 18.3min | 有下降，但仍远高于目标 < 30s |
| bridge-qc probe cause | `ContentLengthError` | `error_type=IndexError cause_type=FSTimeoutError error=tuple index out of range` | 仍有 lazy/footer enrichment 超时与异常封装问题 |
| robomimic-qc | 1 pod，20 行 `RetriesExceededError`，无新 report | 2 个 retry pod，合计 12 行 `RetriesExceededError`，仍无新 report | 仍失败；只是被 step/retry cap 更早截断 |
| robomimic cause 暴露 | `cause_type=RetriesExceededError`（自引用） | 仍是 `cause_type=RetriesExceededError`（自引用） | 未修 |
| droid-normalize | `_checkpoint.json` 写 RUNNING 后 0 archive log | 两次启动，均在 `materialize_input` 全量下载 532 文件后 4h+ `Max Retries Exceeded`；最终 checkpoint 仍 RUNNING | 旧问题从“无日志”推进到“可诊断失败”，但 normalize 仍未产物落地 |
| bridge-normalize / features | OK / WARN，业务产物齐 | OK / WARN，业务产物齐 | 继续稳定 |
| perf-records-pending | 6 条 | 8 条 | infra 侧已知 schema drift，继续走 pending fallback |

结论：`bxpjl` 证明 WSL 侧至少接上了 droid-normalize 的 `runner_boot` 和日志归档，但三处验收仍未通过：

- `robomimic-qc` 仍未按要求改成 `boto3.download_file` materialize-first，仍无法产出新的 `contract_report.json`。
- `droid-normalize` 不再静默卡死，但两次 retry 都全量下载非视频 12.1 GiB 后失败，并且失败后 `_checkpoint.json` 仍保持 `RUNNING`。
- `bridge-qc` duration 仍为 18.3 分钟，timeout cap 没有收敛到 < 30 秒。

## 时间线（按 step pod 创建时间排序）

| # | 任务 | pod 文件名 | 状态 | 时长 | 关键事件 |
|---|------|-----------|------|------|----------|
| 1 | `discover-assets`（lake-list） | `lake-list.1620497943.log` | OK | < 1s | 09:29:36；首行 `runner_boot`；返回 `lake_uri=s3://robot-lake/` |
| 2 | `droid-qc`（qc-contract-run） | `qc-contract-run.241985536.log` | PASS | 1.03s | 09:29:56 boot；lazy footer path；156 parquet / 95658 episodes / 27,630,375 frames / 14 videos |
| 3 | `bridge-qc`（qc-contract-run） | `qc-contract-run.3006339567.log` | PASS | 1096.16s | 09:29:56 boot；09:48:12 才报 `bridge metrics enrichment failed ... error_type=IndexError cause_type=FSTimeoutError`; metric 正确 |
| 4 | `robomimic-qc` attempt 1 | `qc-contract-run.2829358379.log` | FAIL | ~26min | 09:29:56 boot；4 行 HDF5 `RetriesExceededError`；无 final json |
| 5 | `robomimic-qc` attempt 2 | `qc-contract-run.3433499758.log` | FAIL | ~30min | 10:00:04 boot；8 行 HDF5 `RetriesExceededError`；无 final json |
| 6 | `droid-partition`（partition-plan） | `partition-plan.1336333997.log` | OK | ~10min | 09:30:15 boot；19.27 GB 切成 6 个 partition，仍为 droid normalize 的上游输入 |
| 7 | `droid-normalize` attempt 1 | `etl-phase.2633268923.log` | FAIL | 14560.94s = 4.04h | 09:40:03 start；`materialize_input` 检测 lerobot v2，跳过 14 个 videos，但仍下载 532 个非视频文件 / 12.1 GiB；13:42:44 `Max Retries Exceeded` |
| 8 | `droid-normalize` attempt 2 | `etl-phase.2163642686.log` | FAIL | 14576.02s = 4.05h | 13:43:03 retry；同样卡在 `materialize_input`；17:45:59 `Max Retries Exceeded` |
| 9 | `bridge-partition`（partition-plan） | `partition-plan.1219381874.log` | OK | < 1s | 09:48:33 boot；单 partition，314 rows |
| 10 | `bridge-normalize`（etl-phase） | `etl-phase.3276786738.log` | OK | 1.63s | 09:48:55；`normalize SKIP` 已有 manifest；perf 走 pending fallback |
| 11 | `bridge-features`（etl-phase） | `etl-phase.4624398.log` | WARN | 9.66s | 09:49:15；4 个 dwd parquet 落齐；perf 走 pending fallback |

## 关键发现

### A. droid-normalize 的 0 log 问题已暴露为 materialize_input 失败

`fvx5z` 时完全没有 droid-normalize archive log；本次 `bxpjl` 有两个 droid normalize pod：

```text
etl-phase.2633268923.log  # 09:40:03 -> 13:42:44，14560.94s，FAIL
etl-phase.2163642686.log  # 13:43:03 -> 17:45:59，14576.02s，FAIL
```

两次失败点完全一致：

```text
materialize_input: lerobot v2 layout detected, skipping prefixes=('videos/',)
S3 download_dir: bucket=robot-datasets prefix=raw/droid_lerobot_scale30/v1/ files=532 total_size=12058.9 MiB concurrency=8 excluded=14 files (6318.0 MiB)
heartbeat ... phase=normalize.materialize_input ... msg=phase_failed: RetriesExceededError
etl_run FAIL: Max Retries Exceeded
```

这说明 `runner_boot` 和 stdout 归档已经接上，但 normalize 仍然没有使用 partition plan 做分片输入，而是每个 retry 都从 root prefix 全量 materialize 12.1 GiB 非视频数据。失败后 `_checkpoint.json` 仍然停在：

```text
status=RUNNING
completed_steps=[]
updated_at=2026-05-25T05:43:04Z
```

`s3://robot-lake/ods/droid_lerobot_scale30/v1/` 仍只有 `_checkpoint.json`，没有 `_manifest.json` / `pose.parquet` / `episode_meta.parquet` / `video_meta.parquet`。

### B. robomimic-qc 仍是 HDF5 probe 旧问题

本次 robomimic 有两个 retry pod：

```text
qc-contract-run.2829358379.log  # 4 行 hdf5 probe failed
qc-contract-run.3433499758.log  # 8 行 hdf5 probe failed
```

代表性日志仍是：

```text
hdf5 probe failed ... error_type=RetriesExceededError error=Max Retries Exceeded cause_type=RetriesExceededError cause=Max Retries Exceeded
```

逐条核对 `fvx5z` 需求：

| 要求 | bxpjl 结果 |
|------|------------|
| `profile_hdf5` 改为 `boto3.download_file` materialize-first | 未通过；仍然无法读任何 HDF5 |
| `cause_type` 取 `exc.__cause__` 的底层异常 | 未通过；仍是 `RetriesExceededError` 自引用 |
| HDF5 probe 并发 + 单文件 timeout cap | 未通过；出现两个 retry pod，但每个 pod 内仍逐个失败 |
| 产出新的 robomimic `contract_report.json` | 未通过；`mc stat` 仍显示旧 report `Last Modified=2026-05-25 01:11:45 CST` |

### C. bridge-qc 业务正确，但 timeout 仍未收敛

当前 `contract_report.json`：

```text
status=PASS
duration_sec=1096.160436630249
traj_len_p50=108
traj_len_p95=131
episode_count=3
```

metric 继续正确，但 18.3 分钟仍远高于目标 < 30 秒。日志中的 enrichment 失败也从 `ContentLengthError` 变成：

```text
error_type=IndexError cause_type=FSTimeoutError error=tuple index out of range
```

说明 bridge 的 lazy/footer enrichment 仍可能在底层 S3 read 上耗尽长 timeout，然后再以 `IndexError` 包装成业务 warning。该项不阻塞下游，但仍浪费算力，也不满足上一份需求的 duration 验收。

### D. bridge ETL 与 perf pending 保持既有状态

`bridge-normalize` 和 `bridge-features` 业务产物继续齐全：

- ODS：`pose.parquet` / `video_meta.parquet` / `episode_meta.parquet` / `_manifest.json`
- DWD：`pose_feature.parquet` / `press_event.parquet` / `trajectory_segment.parquet` / `episode_feature.parquet` / `_manifest.json`

`etl_perf_runs` schema drift 仍触发 pending fallback，本次新增 2 条，累计 8 条。该问题属 infra 侧已知迁移项，与 WSL 本次修复互不依赖。

## 文件列表

```text
docs/runs/20260525/robot-dh-multisource-scale30-bxpjl/
├── INDEX.md
├── lake-list.1620497943.log              # discover-assets OK
├── qc-contract-run.241985536.log         # droid-qc PASS 1.03s
├── qc-contract-run.3006339567.log        # bridge-qc PASS 1096.16s，metric 正确但 duration 未收敛
├── qc-contract-run.2829358379.log        # robomimic-qc attempt 1，4 行 HDF5 RetriesExceededError
├── qc-contract-run.3433499758.log        # robomimic-qc attempt 2，8 行 HDF5 RetriesExceededError
├── partition-plan.1336333997.log         # droid-partition OK，6 partitions
├── etl-phase.2633268923.log              # droid-normalize attempt 1，4.04h 后 FAIL
├── etl-phase.2163642686.log              # droid-normalize attempt 2，4.05h 后 FAIL
├── partition-plan.1219381874.log         # bridge-partition OK，314 rows
├── etl-phase.3276786738.log              # bridge-normalize OK，perf pending fallback
└── etl-phase.4624398.log                 # bridge-features WARN，业务产物齐，perf pending fallback
```

文件命名约定：`<step-name>.<argo-pod-hash>.log`（与 dls4z / jddlp / qptk9 / ddbfb / fvx5z 同款）。

## 与 ddbfb / fvx5z 关键事件对账

| 维度 | ddbfb | fvx5z | bxpjl |
|------|-------|-------|-------|
| droid-qc | PASS 0.86s | PASS 39.75s | PASS 1.03s |
| bridge-qc metric | 错：traj=314 / episode=0 | 正：traj=108/131 / episode=3 | 正：traj=108/131 / episode=3 |
| bridge-qc duration | 2005s | 1849.99s | 1096.16s |
| bridge-qc cause | `None` | `ContentLengthError` | `FSTimeoutError`，但外层是 `IndexError` |
| robomimic-qc HDF5 失败数 | 16 | 20 | 12（跨 2 个 retry pod） |
| robomimic-qc contract_report | 旧 qptk9 report | 旧 qptk9 report | 仍是旧 qptk9 report |
| robomimic-qc cause_type | `None` | `RetriesExceededError` 自引用 | `RetriesExceededError` 自引用 |
| droid-normalize archive log | 0 | 0 | 2 个 pod 均有 log |
| droid-normalize 结果 | checkpoint RUNNING，无产物 | checkpoint RUNNING，无产物 | 两次 `Max Retries Exceeded`，checkpoint 仍 RUNNING，无产物 |
| perf-records-pending 累计 | 4 | 6 | 8 |
| workflow 可否到达 ml-ready | 否 | 否 | 否 |

→ 新需求文档：[`docs/v1_6_bxpjl_robomimic_hdf5_droid_normalize_materialize_request.md`](../../../v1_6_bxpjl_robomimic_hdf5_droid_normalize_materialize_request.md)
