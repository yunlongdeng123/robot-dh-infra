# `robot-dh-multisource-scale30-fvx5z` 完整 step log 归档

> 来源：`s3://robot-dh-artifacts/argo-logs/robot-dh/robot-dh-multisource-scale30-fvx5z/`（Argo `archiveLogs`）
> 拉取时间：2026-05-25 08:32 CST
> 大小：8 个 step pod，总 ~52 KiB（首条 lake-list 05:56:58 CST，最后 etl-phase 06:29:48 CST）
> 上一条 workflow：[`robot-dh-multisource-scale30-ddbfb`](../robot-dh-multisource-scale30-ddbfb/INDEX.md)（bridge-qc metric 失真 / robomimic hdf5 26 文件全 RetriesExceededError / droid-normalize 卡死 RUNNING）

## 综述：v1.6 修了 1 处旧洞，回归 + 误修 2 处旧洞，1 处旧洞继续卡死

| 维度 | ddbfb（昨晚） | fvx5z（本次） | 趋势 |
|------|---------------|---------------|------|
| `runner_boot` 首行可见日志 | ✅ 9 pod 全覆盖 | ✅ 8 pod 全覆盖 | ➖ 一致 |
| droid-qc | ✅ PASS 0.86s | ✅ PASS **39.75s**（v2 lazy footer 路径） | ➖ 一致（略慢但 < 1min OK） |
| **bridge-qc metric** | ❌ traj_p50=314, p95=314, episode_count=0 | ✅ **traj_p50=108, p95=131, episode_count=3** | ⬆️ **R1 metric 闭环** |
| bridge-qc duration | 2005s | **1849s = 30.8min** | ⬇️ 仅微降，duration 仍未收敛 |
| bridge-qc probe cause 暴露 | `cause_type=None` | ✅ `cause_type=ContentLengthError` 已暴露 | ⬆️ 部分闭环 |
| **robomimic-qc** | ❌ 16 文件 RetriesExceededError, `cause_type=None` | ❌ **20 文件 RetriesExceededError, `cause_type=RetriesExceededError`（exc 自引用，不是 `__cause__`）** | ⬇️ 误修：cause 暴露写错了 |
| robomimic-qc 并发 | ❌ 串行 ~7–20min/file | ❌ 串行 ~30s–8min/file（略快但仍串行）；1.5h 全失败 | ⬇️ G2 并发要求仍未生效 |
| robomimic-qc contract_report | ⚠ 仍是 qptk9 那份（finished_at 01:11:45 CST） | ⚠ **仍是 qptk9 那份**（同上） | ➖ 一致（本次未产出新 report） |
| **droid-normalize** | ❌ 卡死 RUNNING 18:27:37Z, 无 archive log | ❌ **卡死 RUNNING 22:10:52Z, 无 archive log** | ➖ 一致（仅 _checkpoint 时间戳变化） |
| bridge-normalize / features | ✅ 全 PASS（dwd 4 parquet 落齐） | ✅ 全 PASS（dwd 4 parquet 落齐） | ➖ 一致 |
| perf record fallback | 累计 4 条 pending | **累计 6 条 pending**（新增 fvx5z 2 条） | ⬆️ 持续稳定 |

→ **bridge metric / droid v2 lazy 两个改进生效**，但 **robomimic + droid-normalize 仍然完全没动**，整个 multisource-scale30 仍未到达 ml-ready。

## 时间线（按 step pod 创建时间排序）

| # | 任务 | pod 文件名 | 状态 | 时长 | 关键事件 |
|---|------|-----------|------|------|----------|
| 1 | `discover-assets`（lake-list） | `lake-list.3313679828.log` | ✓ OK | < 1s | 05:56:58；首行 `runner_boot`；返回 `lake_uri=s3://robot-lake/`，1 个 raw layer |
| 2 | `droid-qc`（qc-contract-run） | `qc-contract-run.3795896623.log` | ✓ **PASS** | **39.75s** | 05:57:16 boot；`profile_dataset: detected lerobot v2 layout, using lazy footer path`；final json：156 parquet / 95658 episodes / 27M frames / 14 videos / `schema_hash_unique_count=1` |
| 3 | `bridge-qc`（qc-contract-run） | `qc-contract-run.2371171254.log` | ✓ **PASS** | **1849.99s = 30.8min** | 05:57:16 boot；`bridge metrics enrichment failed ... error_type=ClientPayloadError cause_type=ContentLengthError error=Response payload is not completed: <ContentLengthError: 400 ...>`；final json：`traj_len_p50=108, traj_len_p95=131, episode_count=3` ← metric **已修复** |
| 4 | `robomimic-qc`（qc-contract-run） | `qc-contract-run.2703109404.log` | ✗ **FAIL** | ~91min | 05:57:16 boot；**20 行** `hdf5 probe failed for ...: error_type=RetriesExceededError cause_type=RetriesExceededError cause=Max Retries Exceeded`（cause_type 仍非底层异常类）；最后无 final json，contract_report 没产出 |
| 5 | `droid-partition`（partition-plan） | `partition-plan.242521650.log` | ✓ OK | < 1s | 06:10:28；19.27 GB 切成 6 个 partition（25–31 files/分片，~2 GiB/分片，`estimated_rows=5.1M–8.0M`） |
| 6 | `droid-normalize`（etl-phase） | **无 archive log** | ✗ **卡死 RUNNING** | 2h+ 未结束 | `s3://robot-lake/ods/droid_lerobot_scale30/v1/_checkpoint.json` 写 `status=RUNNING completed_steps=[] updated_at=2026-05-24T22:10:52Z`（= 06:10:52 CST），其后 2h+ 无更新；**仍然没有任何 etl-phase pod 归档** |
| 7 | `bridge-partition`（partition-plan） | `partition-plan.2939189467.log` | ✓ OK | < 1s | 06:28:47；`estimated_rows=314` 正确 |
| 8 | `bridge-normalize`（etl-phase） | `etl-phase.38013569.log` | ✓ 业务 OK | 4.5s | 06:29:06；`normalize SKIP: ods 已有 manifest`；perf record 走 pending fallback |
| 9 | `bridge-features`（etl-phase） | `etl-phase.1684093571.log` | ✓ 业务 WARN | 11.95s | 06:29:32；4 个 dwd parquet 落齐（pose_feature / press_event / trajectory_segment / episode_feature） |

## 关键发现

### A. ✅ **bridge-qc metric 修复闭环**（v1.6 §4.4.1 已生效）

ddbfb 的 R1 修复在 fvx5z 落地：

```text
# fvx5z bridge-qc contract_report.json
{
  "status": "PASS",
  "metrics": {
    "num_parquet_files": 1, "parquet_valid_rate": 1.0,
    "traj_len_p50": 108,        # ← 真值（ddbfb 是 314）
    "traj_len_p95": 131,        # ← 真值（ddbfb 是 314）
    "episode_count": 3,         # ← 真值（ddbfb 是 0）
    "language_missing_rate": 0.0,
    "image_ref_missing_rate": 0.0,
    "action_column_coverage": 1.0
  }
}
```

`bridge metrics enrichment failed` WARN 行也带上了 `cause_type=ContentLengthError`（ddbfb 是 None） ← **§4.4.1 + cause 暴露两条都生效**。

5 条 rule 全 PASS：`parquet_valid_rate=1.0 / num_parquet_files_min / action_column_coverage / language_missing_rate / episode_count_min`。

### B. ⚠ **bridge-qc duration 仍 30.8min**（ddbfb §4.4.3 的 cap 没生效）

| 字段 | ddbfb | fvx5z | 目标 |
|------|-------|-------|------|
| duration_sec | 2005s | **1849.99s = 30.8min** | < 30s |
| `bridge metrics enrichment failed` WARN | 2 行 | **1 行**（只 1 次 retry） | 0–1 行 |

虽然只产生了 **1** 条 WARN（不是 ddbfb 的 2 条），但是 duration_sec 居然还是 30 分钟，说明：

- 单次 enrichment 内部已经走过了**长时间 retry loop**（boto3 / s3fs 默认 retry 累计可达数 min）
- `ContentLengthError 400 Not enough data` 是 aiohttp / s3fs lazy footer GET 拿到 body 不全的典型表现，**单次 GET 就跑 30min 才放弃** 极不正常
- ddbfb §4.4.3 `activeDeadlineSeconds: 1800` step 级 cap + backoff `maxDuration: 5m` 都没看到生效

→ **未阻塞 step exit**（status PASS、metric 正确），但**浪费 30min 算力**，duration 这一条 ddbfb §4.4 验收没过。

### C. ❌ **robomimic-qc hdf5 probe 几乎完全没修复 + cause 暴露做错了**

```text
{"message": "hdf5 probe failed for s3://...low_dim_sparse_v15.hdf5: error_type=RetriesExceededError error=Max Retries Exceeded cause_type=RetriesExceededError cause=Max Retries Exceeded", "level": "WARNING"}
... 共 20 行同款，每条相隔 30s–8min ...
# 然后 step exit 非 0，没产出新 contract_report
```

**逐条核对 ddbfb §5.3 的要求：**

| ddbfb §5.3 要求 | ddbfb 现状 | **fvx5z 现状** |
|----------------|------------|----------------|
| 走 `boto3.download_file` materialize-first | ❌ | ❌ 仍走 fsspec 远端 read |
| `Config(retries={'max_attempts': 10, 'mode': 'adaptive'})` | ❌ | ❌（如果生效不应该这么快放弃；20 个文件 1.5h，单文件 ~4.5min） |
| `cause_type=type(exc.__cause__).__name__` | ❌ `None` | ❌ **`RetriesExceededError`（== `error_type`，是 exc 自己当 cause）** |
| `ThreadPoolExecutor(max_workers=4)` 并发 | ❌ | ❌ 仍然串行 |
| 单测守门 `cause_type is None` 让 CI red | ❌ | ❌（如果有就不会让 cause_type 写成 exc 自己） |

**疑似实现错误**（核对 wsl 端代码）：

```python
# wsl 端 fvx5z 疑似实现（错误）：
except Exception as exc:
    logger.warning(f"... cause_type={type(exc).__name__} cause={exc}")  # ★ 把 exc 自己当 cause

# ddbfb §5.3 要求的实现（正确）：
except Exception as exc:
    cause = exc.__cause__   # ★ 拿底层链式异常
    logger.warning(
        f"... cause_type={type(cause).__name__ if cause else None} cause={cause!r}"
    )
```

如果是 `boto3 RetriesExceededError`，底层 `__cause__` 应该是 `ReadTimeoutError` / `ConnectionError` / `EndpointConnectionError` 之类**具体网络异常类**——这才是排障真正需要的信息。当前 `cause_type=RetriesExceededError` 等价于没暴露。

#### C.1 时间分布对比（看出还是串行）

| ddbfb 时间分布 | fvx5z 时间分布 |
|---------------|----------------|
| 第 1 行 18:40:26 | 第 1 行 22:24:20 |
| 第 16 行 20:17:50 | 第 20 行 23:55:16 |
| 总时长 ~1h37min | **总时长 ~1h31min**（多 4 个文件却 6min 更短） |
| 单文件均时 ~6min | 单文件均时 **~4.6min** |

→ fvx5z 单文件耗时确实降了，但**完全没并发**，平均 4.6min 才放弃，仍然走 fsspec 远端 read-by-range 模式。

### D. ❌ **droid-normalize 卡死 RUNNING + 0 archive log，与 ddbfb 完全一致**

```bash
$ mc cat rdh/robot-lake/ods/droid_lerobot_scale30/v1/_checkpoint.json
{
  "dataset_id": "droid_lerobot_scale30",
  "version": "v1",
  "phase": "normalize",
  "source_uri": "s3://robot-datasets/raw/droid_lerobot_scale30/v1",
  "output_uri": "s3://robot-lake/ods/droid_lerobot_scale30/v1",
  "status": "RUNNING",
  "completed_steps": [],
  "files": {},
  "metrics": {},
  "schema_version": "1.6",
  "updated_at": "2026-05-24T22:10:52Z"   ← 06:10:52 CST，partition-plan 完成 06:10:28 之后 24s
}

$ mc ls rdh/robot-lake/ods/droid_lerobot_scale30/v1/
# 仍然只有 _checkpoint.json 365B，没有 _manifest.json / pose.parquet / video_meta.parquet / episode_meta.parquet

$ mc ls rdh/robot-dh-artifacts/argo-logs/robot-dh/robot-dh-multisource-scale30-fvx5z/ | grep -i normalize
# 仍然只看到 bridge 的两个 etl-phase pod，0 个 droid normalize pod
```

| 维度 | ddbfb | fvx5z |
|------|-------|-------|
| `_checkpoint.json` updated_at | 18:27:37Z（partition 完成 +20s） | **22:10:52Z（partition 完成 +24s）** |
| 之后无更新时长 | 2.5h | **2h+** |
| 6 个 partition 中归档了几个 | 0 | **0** |
| `runner_boot` 模块顶层 print（ddbfb §6.3.1） | ❌ 没接 | ❌ **仍然没接** |

→ ddbfb §6.3.1 / §6.3.2 / §6.3.3 / §6.3.4 **四条建议一条都没实施**。

### E. ✅ **perf record fallback 持续稳定**

```text
mc ls -r rdh/robot-dh-artifacts/perf-records-pending/
2.8KiB  bridgedata_v2_scale30/v1/build_features/.../...-985bea4c.json   # ddbfb features
2.8KiB  bridgedata_v2_scale30/v1/build_features/.../...-bc60a477.json   # fvx5z features
2.8KiB  bridgedata_v2_scale30/v1/build_features/.../...-86aa1f87.json   # qptk9 features
2.8KiB  bridgedata_v2_scale30/v1/normalize/.../...-ffe282eb.json        # qptk9 normalize
2.8KiB  bridgedata_v2_scale30/v1/normalize/.../...-b2a85214.json        # ddbfb normalize
2.8KiB  bridgedata_v2_scale30/v1/normalize/.../...-e46dbd89.json        # fvx5z normalize
```

→ 累计 **6 条 pending records** 等 infra 端 `006_etl_perf_runs_align.sql` 上线后 `robot-dh perf reingest-pending` 一次性回填。

## 文件列表

```text
docs/runs/20260525/robot-dh-multisource-scale30-fvx5z/
├── INDEX.md                              # 本文件
├── lake-list.3313679828.log              # 1.3 KiB（discover-assets ✓）
├── qc-contract-run.3795896623.log        # 2.5 KiB（droid-qc ✓ PASS 39.75s，95658 episodes）
├── qc-contract-run.2371171254.log        # 2.5 KiB（bridge-qc ✓ PASS 1849.99s，metric 已修复 traj=108/131 episode=3）
├── qc-contract-run.2703109404.log        # 7.3 KiB（robomimic-qc ✗，20 行 RetriesExceededError，无 final json）
├── partition-plan.242521650.log          # 20 KiB （droid-partition-plan ✓，6 个 partition × ~2 GiB）
├── partition-plan.2939189467.log         # 2.5 KiB（bridge-partition-plan ✓，单 partition 314 rows）
├── etl-phase.38013569.log                # 7.6 KiB（bridge-normalize ✓ 业务 OK，perf 走 pending）
└── etl-phase.1684093571.log              # 7.4 KiB（bridge-features ✓ 业务 WARN，dwd 4 parquet 落齐）
```

文件命名约定：`<step-name>.<argo-pod-hash>.log`（与 dls4z / jddlp / qptk9 / ddbfb 同款）。

> 缺失 pod：`droid-normalize` 6 个 partition pod **仍然 0 archive log**（与 ddbfb 同款），需要 wsl 侧用 `kubectl -n robot-dh get pods -l workflows.argoproj.io/workflow=robot-dh-multisource-scale30-fvx5z` 拉 pod 列表 + `kubectl describe pod` 看是否 OOMKilled / Pending / Evicted。

## 与 dls4z / jddlp / qptk9 / ddbfb 关键事件对账

| 维度 | dls4z | jddlp | qptk9 | ddbfb | **fvx5z（本次）** |
|------|-------|-------|-------|-------|--------------------|
| `runner_boot` 首行 print | ❌ | ❌ | ❌ | ✅ 9 pod 全覆盖 | ✅ 8 pod 全覆盖 |
| bridge-qc metric 正确性 | ❌ traj=314 | ✅ traj=108 | ✅ traj=108 | ❌ traj=314 回归 | ✅ **traj=108 修回** |
| bridge-qc duration | < 1s | < 1s | < 1s | 2005s | **1849s ← 仍未收敛** |
| bridge-qc probe cause_type | — | — | — | None | **ContentLengthError ✓ 已暴露** |
| bridge-normalize 业务 | ❌ adapter | ✅ OK | ✅ OK | ✅ OK | ✅ OK |
| dwd 工件落地 | ❌ | ❌ | ✅ | ✅ | ✅ |
| droid-qc | — | — | ❌ 0B | ✅ PASS 0.86s | ✅ **PASS 39.75s**（lazy v2） |
| droid-partition-plan | — | — | — | ✅ 6 partitions | ✅ 6 partitions |
| droid-normalize | — | — | — | ❌ 卡死 18:27:37Z | ❌ **卡死 22:10:52Z**（同款无 log） |
| robomimic-qc hdf5 probe 失败数 | — | — | — | 16 文件 | **20 文件**（更多） |
| robomimic-qc cause_type | — | — | — | None | **RetriesExceededError（自引用）** |
| robomimic-qc 并发 | — | — | — | 串行 | **仍然串行** |
| perf-records-pending 累计 | 0 | 2 | 2 | 4 | **6** |
| workflow 终态 | Failed | Failed | Failed | Failed | **Failed（同款 droid-normalize timeout）** |

→ fvx5z 是 **R1 metric 闭环 + R1.2 duration 未收敛 + R2 cause 误修 + R3 droid-normalize 完全没动**。

→ 新需求文档：[`docs/v1_6_fvx5z_robomimic_hdf5_droid_normalize_request.md`](../../../v1_6_fvx5z_robomimic_hdf5_droid_normalize_request.md)
