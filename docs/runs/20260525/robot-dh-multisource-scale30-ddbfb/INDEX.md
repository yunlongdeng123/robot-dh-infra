# `robot-dh-multisource-scale30-ddbfb` 完整 step log 归档

> 来源：`s3://robot-dh-artifacts/argo-logs/robot-dh/robot-dh-multisource-scale30-ddbfb/`（Argo `archiveLogs`）
> 拉取时间：2026-05-25 05:05 CST
> 大小：9 个 step pod，总 ~50 KiB（首条 lake-list 起 02:18:51 CST，最后 etl-phase 04:54:12 CST）
> 上一条 workflow：[`robot-dh-multisource-scale30-qptk9`](../../20260524/robot-dh-multisource-scale30-qptk9/INDEX.md)（droid-qc 0B fail / robomimic-qc metric 失真）

## 综述：v1.6 修了 1 个新洞，回归了 2 个旧洞，新爆 1 个洞

| 维度 | qptk9（昨晚） | ddbfb（本次，凌晨） | 趋势 |
|------|---------------|---------------------|------|
| `runner_boot` 首行可见日志 | ❌ 没有，droid-qc 0B | ✅ 9 个 pod 全部首行打 `{"event":"runner_boot","argv":[...]}` | ⬆️ 修复确认 |
| droid-qc | ❌ 0B FAIL，无 contract_report | ✅ **PASS**（0.86s，156 parquet / 95658 episodes / 27M frames / 14 videos） | ⬆️ **彻底闭环 §4.2** |
| droid-partition-plan | — 没跑到 | ✅ OK（6 个 partition，total_input_bytes=19.27 GB，每分片 ~2 GiB） | ⬆️ 首次成功 |
| droid-normalize | — 没跑到 | ❌ **卡死 RUNNING**（`_checkpoint.json` 写了 `status=RUNNING completed_steps=[]` 02:27:37 之后无下文；archive log 完全缺失） | 🆕 新爆 |
| bridge-qc | ✅ PASS（traj_p50=108, p95=131, episode_count=3，< 1s） | ⚠ PASS but **metric 失真回归 dls4z**（traj_p50=314, p95=314, episode_count=0，duration **2005s**） | ⬇️ **回归** |
| bridge-partition / normalize / features | ✅ 全 PASS（dwd 4 parquet 落齐） | ✅ 全 PASS（dwd 4 parquet 02:54 重新落） | ➖ 与 qptk9 一致 |
| robomimic-qc | ⚠ PASS but `episode_len_p50/p95=0`（7189s） | ❌ **全部 26 个 hdf5 probe RetriesExceededError**，cause_type=None，无新 contract_report 产出 | ⬇️ **大幅回归** |
| perf record fallback | ✅ 落 pending store | ✅ 同样落（4 条累计） | ➖ 一致 |

→ **bridge / droid / robomimic 三支多源 fanout 全部各有问题**，workflow 整体未到达 ml-ready。

## 时间线（按 step pod 创建时间排序）

| # | 任务 | pod 文件名 | 状态 | 时长 | 关键事件 |
|---|------|-----------|------|------|----------|
| 1 | `discover-assets`（lake-list） | `lake-list.4008332013.log` | ✓ OK | < 1s | 02:18:51；首行打了 `runner_boot`，env_keys 列表能看到 `ROBOT_DH_S3_*` 已注入 |
| 2 | `bridge-qc`（qc-contract-run 第 1 次） | `qc-contract-run.1610040161.log` | ✗ FAIL | ? | 02:19:02 boot；唯一一条 WARNING：`parquet null_rate probe failed for shard_0-00000-of-00001.parquet: tuple index out of range`，然后 step 退出非 0 |
| 3 | `robomimic-qc`（qc-contract-run） | `qc-contract-run.3265307137.log` | ✗ FAIL | ~2h | 02:19:02 boot → 04:19:03 结束；**16 次** `hdf5 probe failed for ...: error_type=RetriesExceededError error=Max Retries Exceeded cause_type=None cause=None`（覆盖 13 个 hdf5 文件），最后无 final json，step exit 非 0；本次产物**仍是 qptk9 那份**（01:11:45 CST，PASS but `episode_len_p50/p95=0`） |
| 4 | `droid-qc`（qc-contract-run） | `qc-contract-run.3564650026.log` | ✓ **PASS** | 0.86s | 02:19:10：`profile_dataset: detected lerobot v2 layout, using lazy footer path`；final json: `contract_id=droid_multimodal_v1`、95658 episodes / 27M frames / 156 parquet / 14 videos / `schema_hash_unique_count=1`、`failed_rules=[]` |
| 5 | `droid-partition`（partition-plan） | `partition-plan.2831481951.log` | ✓ OK | < 1s | 02:27:17；19.27 GB 切成 6 个 partition（25–31 文件/分片，~2 GiB/分片，`estimated_rows=5.1M–8.0M`） |
| 6 | `droid-normalize`（etl-phase） | **无 archive log** | ✗ **卡死 RUNNING** | ? | `s3://robot-lake/ods/droid_lerobot_scale30/v1/_checkpoint.json` 写了 `status=RUNNING completed_steps=[] updated_at=2026-05-24T18:27:37Z`（= 02:27:37 CST），其后 2.5h 无任何进展 |
| 7 | `bridge-qc`（qc-contract-run 第 2 次） | `qc-contract-run.1140413924.log` | ⚠ **PASS but metric 失真回归** | **2005s = 33min** | 04:19:18 boot；`parquet null_rate probe failed ...: Response payload is not completed: <ContentLengthError: 400, message='Not enough data to satisfy content length header.'>`；最终 final json：`status=PASS` **但** `traj_len_p50=314, traj_len_p95=314, episode_count=0` ← 回归 dls4z 时代的 B 类 metric bug |
| 8 | `bridge-partition`（partition-plan 第 2 次） | `partition-plan.3348563300.log` | ✓ OK | < 1s | 04:53:17；`estimated_rows=314` 正确 |
| 9 | `bridge-normalize`（etl-phase 第 1 个） | `etl-phase.324058756.log` | ✓ 业务 OK | 1.94s | 04:53:37；`normalize SKIP: ods 已有 manifest`；perf record 走 pending fallback（与 qptk9 一致） |
| 10 | `bridge-features`（etl-phase 第 2 个） | `etl-phase.4086356496.log` | ✓ 业务 WARN | 9.71s | 04:53:58；4 个 dwd parquet 落齐（pose_feature / press_event / trajectory_segment / episode_feature） |

## 关键发现

### A. **droid-qc 完美闭环**（v1.6 §4.2 lerobot v2 lazy profile 修复确认）

```text
profile_dataset: detected lerobot v2 layout, using lazy footer path: s3://robot-datasets/raw/droid_lerobot_scale30/v1
```

仅 0.86s 跑完 18.6 GiB / 156 parquet / 14 videos profile，**整 parquet 不下载、纯 footer + meta**。`contract_id=droid_multimodal_v1` 已注册 enabled，7 条规则全 PASS，`asset_profile.json` 13 KiB 含 6 个 profile sub-dict（parquet / video / episode / etc）。

→ qptk9 提的需求 §4.2.1（`runner_boot` 兜底）+ §4.2.2（lerobot v2 专属 lazy）+ §4.2.3（注册 contract）三条全部生效。

### B. **bridge-qc 大幅度回归 dls4z 时代的 metric 失真**（**P1 阻塞，下游 ml-ready 拿到错误统计**）

| 字段 | dls4z (5/24 早) | qptk9 (5/24 晚 PASS) | ddbfb (5/25 凌晨 PASS) | 真值 |
|------|-----------------|----------------------|------------------------|------|
| `traj_len_p50` | 314 | **108** | **314** ← 回归 | 108 |
| `traj_len_p95` | 314 | **131** | **314** ← 回归 | 131 |
| `episode_count` | （未上报） | **3** | **0** ← 回归 | 3 |
| `language_missing_rate` | 1.0 | 0.0 | 0.0 | 0.0 |
| duration_sec | ? | < 1s | **2005s = 33min** | < 1s |
| 失败前的 retry 错误 | adapter mismatch | — | `tuple index out of range` → `ContentLengthError 400 Not enough data to satisfy content length header` | — |

**3 条同时返红**：

1. `traj_len_p50/p95` 同时 = `parquet.num_rows`（把整个 parquet 当 1 条 trajectory，没按 `episode_idx` 切 group） ← dls4z 的 B 类
2. `episode_count=0` 比 dls4z 还差（dls4z 时是 nan/missing，现在直接 0）
3. duration `2005s` 远超 qptk9 的 < 1s，疑似 retry loop（看到 2 次 `parquet null_rate probe failed`，第 1 次 `tuple index out of range`，第 2 次 `ContentLengthError 400` 是 boto3/aiohttp 层 GET 拿到不完整 body）

**root cause 推断**：

- jddlp / qptk9 跑 < 1s 时 metric 正确 → wsl 端 PR A 把 bridge contract metric aggregator 改对了
- ddbfb 跑 33min 时 metric 失真 → wsl 端 PR B（**很可能在 PR A 之后引入**）把 `parquet null_rate probe` 改成会**因为 None / IndexError 触发回退**，回退到"整个 parquet 当 1 个 traj"的 dls4z 行为
- 同时 retry loop 没有 backoff cap，2 次 probe error 各跑 ~16min，共 33min

→ **不阻塞 step exit**（status PASS 写出了），但 **ml-ready 和 dashboard 拿到的统计完全错误**，严重程度 ≥ dls4z 当时。

### C. **robomimic-qc 大幅度回归**：26 个 hdf5 全部 `RetriesExceededError`，`cause_type=None`（**fhkvr §5.1.2 cause 暴露要求没生效**）

```text
{"message": "hdf5 probe failed for s3://robot-datasets/raw/robomimic_scale30/v1/v1.5/can/mg/low_dim_dense_v15.hdf5: error_type=RetriesExceededError error=Max Retries Exceeded cause_type=None cause=None", ... "level": "WARNING"}
... 共 16 行同款 WARN，每条间隔 3–12 分钟 ...
```

- **每条 WARN 之间 3–12 分钟**：13 个 hdf5 文件、每个失败 ~10 分钟、串行（**§5.2 G2 并发要求没生效**）
- **`cause_type=None cause=None`**：fhkvr §5.1.2 明确要求带 `cause=ReadTimeoutError` 这种具体类，本次依然 None ← **§5.1.2 cause 暴露要求没生效**
- **`error_type=RetriesExceededError`**：仍是 botocore 的 retry 顶层异常，没有 fhkvr §5.1.2 要求的 `materialize-first via boto3.download_file + Config(retries={'max_attempts': 10, 'mode': 'adaptive'})` 重试包装
- **整 step exit 非 0**：写完 16 行 WARN 后无 final json，contract_report 没产出（仍是 qptk9 那份）

**对账 §3 infra 端**：

```bash
mc stat rdh/robot-datasets/raw/robomimic_scale30/v1/v1.5/can/mg/low_dim_dense_v15.hdf5
# Size: 1.1 GiB  ETag: ...  立即返回（确认对象存在 + endpoint 可达）
# 同一 workflow 内 bridge / droid 都能正常 GET，故不是 policy / 网络问题
```

**疑似 root cause**：

1. wsl 端 hdf5 probe 走了 **fsspec / h5py 远端 random read**（**而不是** fhkvr §5.1.2 要求的 `boto3.download_file → /tmp → h5py.File(local)`）
2. fsspec 在 800 MiB+ HDF5 上 read-by-range 触发**几千次 small GET**，单 GET 受默认 retries 限制累计触发顶层 `RetriesExceededError`
3. 没有 `exc.__cause__` 透传 → `cause_type=None`，与 fhkvr WARN 同款"吞了底层异常"

### D. **droid-normalize 卡死 RUNNING**（**P1 阻塞 droid 通路，但 archive log 完全缺失**）

```bash
mc cat rdh/robot-lake/ods/droid_lerobot_scale30/v1/_checkpoint.json
{
  "status": "RUNNING",
  "completed_steps": [],
  "files": {},
  "metrics": {},
  "schema_version": "1.6",
  "updated_at": "2026-05-24T18:27:37Z"   ← 02:27:37 CST，与 droid-partition-plan 完成 02:27:17 仅差 20s
}
```

- `_checkpoint.json` 写了 RUNNING 之后 **2.5h 无任何更新**
- `s3://robot-lake/ods/droid_lerobot_scale30/v1/` 下**只有 `_checkpoint.json`，没有 `_manifest.json` / `pose.parquet` / `episode_meta.parquet`**
- `s3://robot-dh-artifacts/argo-logs/robot-dh/robot-dh-multisource-scale30-ddbfb/` 下 **没有任何 droid 的 etl-phase pod**（只有 2 个 bridge 的）

3 种可能：

1. **droid-normalize pod 启动了但 OOMKilled / DeadlineExceeded，stdout 被 SIGKILL 前未 flush，与 qptk9 droid-qc 0B 同款**（但 `runner_boot` 修复已经覆盖 qc 路径，**是否覆盖 normalize 路径不确定**）
2. **droid-normalize 的 6 个 partition 没被 Argo fanout 起来**（partition-plan 输出 6 partitions，但下游 DAG 模板可能只接 `partitions[0]`，5 个分片孤立）
3. **droid-normalize 启动后命中第一个分片 `materialize_input`（含 26 个 parquet × ~80 MiB = 2.1 GiB 下载到 `/tmp`），pod ephemeral storage 撑爆被 evict**

→ archive log 缺失是 **P0 级排障盲区**：与 qptk9 droid-qc 0B 同款，本次 normalize 路径**仍然没有兜底 `runner_boot` 首行 print**。

### E. **perf record fallback 继续稳定生效**

```text
mc ls -r rdh/robot-dh-artifacts/perf-records-pending/
2.8KiB  bridgedata_v2_scale30/v1/build_features/.../...-985bea4c.json   ← 本次 ddbfb features
2.8KiB  bridgedata_v2_scale30/v1/normalize/.../...-b2a85214.json        ← 本次 ddbfb normalize
2.8KiB  bridgedata_v2_scale30/v1/build_features/.../...-86aa1f87.json   ← qptk9 features
2.8KiB  bridgedata_v2_scale30/v1/normalize/.../...-ffe282eb.json        ← qptk9 normalize
```

→ jddlp 的 A 类 fallback 持续稳定，**4 条 pending records 等 infra 端 `006_etl_perf_runs_align.sql` 上线后 `robot-dh perf reingest-pending` 一次性回填**。

## 文件列表

```text
docs/runs/20260525/robot-dh-multisource-scale30-ddbfb/
├── INDEX.md                              # 本文件
├── lake-list.4008332013.log              # 1.3 KiB（discover-assets ✓，首行 runner_boot 修复确认）
├── qc-contract-run.1610040161.log        # 1.7 KiB（bridge-qc 第 1 次 ✗，`tuple index out of range`）
├── qc-contract-run.3564650026.log        # 2.5 KiB（droid-qc ✓ PASS，95658 episodes / 27M frames）
├── qc-contract-run.3265307137.log        # 5.6 KiB（robomimic-qc ✗，16 行 `RetriesExceededError` 后无 final json）
├── qc-contract-run.1140413924.log        # 2.4 KiB（bridge-qc 第 2 次 ⚠ PASS but metric 失真回归） 
├── partition-plan.2831481951.log         # 20 KiB （droid-partition-plan ✓，6 个 partition × ~2 GiB）
├── partition-plan.3348563300.log         # 2.5 KiB（bridge-partition-plan ✓，单 partition 314 rows）
├── etl-phase.324058756.log               # 7.6 KiB（bridge-normalize ✓ 业务 OK，perf 走 pending）
└── etl-phase.4086356496.log              # 7.3 KiB（bridge-features ✓ 业务 WARN，dwd 4 parquet 落齐）
```

文件命名约定：`<step-name>.<argo-pod-hash>.log`（与 dls4z / jddlp / qptk9 同款）。

> 缺失 pod：`droid-normalize` 6 个 partition pod **无任何 archive log**，需要 wsl 侧用 `kubectl get pods -l workflows.argoproj.io/workflow=robot-dh-multisource-scale30-ddbfb` 拉一次 pod 列表 + `kubectl describe pod` 看是否 OOMKilled / Pending。

## 与 dls4z / jddlp / qptk9 关键事件对账

| 维度 | dls4z | jddlp | qptk9 | **ddbfb（本次）** |
|------|-------|-------|-------|--------------------|
| `runner_boot` 首行 print | ❌ | ❌ | ❌ | ✅ **全部 9 pod 覆盖** |
| bridge-qc metric 正确性 | ❌ traj=314 | ✅ traj=108 | ✅ traj=108 | ❌ **traj=314 ← 回归** |
| bridge-qc 耗时 | < 1s | < 1s | < 1s | **2005s 33min ← 回归** |
| bridge-normalize 业务 | ❌ adapter | ✅ OK | ✅ OK | ✅ OK |
| bridge-normalize step exit | 非 0 | 非 0（perf abort） | **0**（perf pending） | **0**（perf pending） |
| dwd 工件落地 | ❌ | ❌ | ✅ | ✅ |
| droid-qc | — | — | ❌ 0B | ✅ **PASS 0.86s** |
| droid-partition-plan | — | — | — | ✅ 6 partitions |
| droid-normalize | — | — | — | ❌ **卡死 RUNNING 无 log** |
| robomimic-qc | — | — | ⚠ PASS but `episode_len=0` | ❌ **全 hdf5 RetriesExceededError + cause=None** |
| perf-records-pending 累计 | 0 | 2 | 2 | 2（共 4 条等回填） |
| workflow 终态 | Failed | Failed | Failed | 🔄 Running（droid-normalize 应该已 timeout） |

→ ddbfb 是**修了 1 个新洞（droid-qc）+ 回归 2 个旧洞（bridge-qc metric / robomimic hdf5 probe）+ 新爆 1 个洞（droid-normalize）** 的混合结果。

→ 新需求文档：[`docs/v1_6_ddbfb_qc_regression_and_droid_normalize_request.md`](../../../v1_6_ddbfb_qc_regression_and_droid_normalize_request.md)
