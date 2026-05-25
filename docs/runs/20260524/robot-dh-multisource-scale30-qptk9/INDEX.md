# `robot-dh-multisource-scale30-qptk9` 完整 step log 归档

> 来源：`s3://robot-dh-artifacts/argo-logs/robot-dh/robot-dh-multisource-scale30-qptk9/`（Argo `archiveLogs`）
> 拉取时间：2026-05-25 01:30 CST
> 大小：7 个 step pod（其中 1 个 0B），总 ~14.7 KiB
> 上一条 workflow：[`robot-dh-multisource-scale30-jddlp`](../robot-dh-multisource-scale30-jddlp/INDEX.md)（FAIL：业务 OK 但 perf record 写 PG schema 漂移 → step abort）
> Workflow 当前态（来自 user 截图，根节点 `discover-assets` → 多源 fanout）：
>
> - `discover-assets` ✓
> - `bridge-qc` ✓ → `bridge-partition` ✓ → `bridge-normalize` ✓ → `bridge-normalize(0)` ✓ → `bridge-features` ✓ → `bridge-features(0)` ✓
> - `droid-qc` 🔄 retry 中：`droid-qc(0)` ✗ + `droid-qc(1)` 🔄
> - `robomimic-qc` 🔄 retry 中：`robomimic-qc(0)` ✗ + `robomimic-qc(1)` 🔄（**实际 1 已 PASS**，截图比 contract_report 落地早）

## 时间线（按 step pod 创建时间排序）

| 顺序 | 任务/step | pod 文件名 | 状态 | 关键事件 |
|------|----------|-----------|------|----------|
| 1 | `discover-assets`（lake-list） | `lake-list.3629310360.log` | ✓ OK | `s3://robot-lake/` raw 1 个对象，slices 空 |
| 2 | `bridge-qc`（qc-contract-run） | `qc-contract-run.2762137274.log` | ✓ **PASS** | `traj_len_p50=108`、`traj_len_p95=131`、`language_missing_rate=0.0`、`episode_count=3`（与 jddlp 一致） |
| 3 | `bridge-partition`（partition-plan） | `partition-plan.4186328431.log` | ✓ OK | 单 partition 单 shard，`estimated_rows=314`，与真实 `parquet.num_rows=314` 一致（dls4z 的 D 类已修） |
| 4 | `bridge-normalize`（etl-phase 第 1 次） | `etl-phase.3352401365.log` | ✓ **业务 OK** | job `etl-run-bridgedata_v2_scale30-v1-31317c55`，1.47s，`normalize SKIP: ods 已有 manifest` ← resume 修复仍生效；**`perf record schema mismatch, deferred to pending store`** ← jddlp 的 A 类 perf record 容错已落地，step exit 0 |
| 5 | `bridge-features`（etl-phase 第 2 次） | `etl-phase.2906995583.log` | ✓ **业务 WARN** | job `etl-run-bridgedata_v2_scale30-v1-f52997b5`，5.03s，写 `dwd/bridgedata_v2_scale30/v1/{pose_feature,press_event,trajectory_segment,episode_feature}.parquet`；同样 perf record 走 pending fallback |
| 6 | `robomimic-qc`（qc-contract-run，retry 后） | `qc-contract-run.1939853856.log` | ✓ **PASS（耗时 7189s，metric 失真）** | `contract_id=robomimic_hdf5_v1`、`status=PASS`、`demo_count=21000`、`num_hdf5_files=26`；**但 `episode_len_p50=0` / `episode_len_p95=0`**（21000 demos 显然不可能 episode_len=0，统计逻辑 bug）；耗时 7189.94s ≈ 2h，疑似 26 个 HDF5 串行 materialize-first |
| 7 | `droid-qc`（qc-contract-run） | `qc-contract-run.2368294939.log` | ✗ **FAIL（0B pod log）** | 整个 pod 退出前未输出任何 stdout（archive size 0B）；下游 `s3://robot-lake/qc/droid_lerobot_scale30/v1/contract_report.json` **不存在**；与 robomimic-qc 同一时刻完成（01:11:50），疑似在 fhkvr §5.1.1 lazy profile_parquet 走完后又被新 root cause 拦截 |

> 注：图中 `bridge-qc(0)` / `bridge-normalize(0)` / `bridge-features(0)` 这种带 `(0)` 后缀的节点是 Argo `withItems` / `withParam` fanout 出来的 task 实例，**与 retry 编号无关**；而 `droid-qc(0)` + `droid-qc(1)` 是同一个 task 的 retry 0 / retry 1。

## 关键发现（按 step 串起来）

### A. **jddlp 的 perf record schema 漂移已经彻底闭环**（重要正向证据）

`bridge-normalize` / `bridge-features` 两次 etl-phase 都在业务 `etl_run END status=OK/WARN` 之后命中同一条 `psycopg.errors.UndefinedColumn: column "started_at" of relation "etl_perf_runs" does not exist`，**但这次没有 abort step**：

```text
ERROR  warehouse record_etl_perf_run schema mismatch: ... started_at ... does not exist
ERROR  perf record schema mismatch, deferred to pending store:
   local=/tmp/.cache/robot-dh/perf-records-pending/.../etl-run-..._normalize-ffe282eb.json
   s3=s3://robot-dh-artifacts/perf-records-pending/.../etl-run-..._normalize-ffe282eb.json.
   Run schema migration on infra side then `robot-dh perf reingest-pending` to backfill.
```

落地证据（`mc ls -r rdh/robot-dh-artifacts/perf-records-pending/`）：

```text
2.8KiB  perf-records-pending/bridgedata_v2_scale30/v1/build_features/etl-run-...__features-86aa1f87.json
2.8KiB  perf-records-pending/bridgedata_v2_scale30/v1/normalize/etl-run-...__normalize-ffe282eb.json
```

→ 主项目的 perf writer fallback（[`docs/v1_6_etl_perf_runs_schema_align_request.md`](../../../v1_6_etl_perf_runs_schema_align_request.md) §4 提议项）已经实现，**业务流不再被可观测性 schema 漂移卡死**。jddlp INDEX.md §D 的"开放问题"现在闭环为"采纳折中方案"。infra 端 PG `etl_perf_runs` 加 `started_at`/`finished_at` 列后，跑 `robot-dh perf reingest-pending` 一次批量回填即可。

### B. **bridge 通路第一次端到端 ✓**（dls4z + jddlp 所有问题已收口）

| 维度 | jddlp | qptk9 |
|------|-------|-------|
| bridge-qc 报表 | ✅ PASS | ✅ PASS（同口径，复现稳定） |
| bridge-partition `estimated_rows` | ✅ 314 | ✅ 314 |
| bridge-normalize 业务终态 | ✅ OK（duration 640.86s，首跑） | ✅ OK（duration 1.47s，SKIP via manifest） |
| bridge-normalize step pod 退出码 | ❌ 非 0（perf record abort） | ✅ 0（perf 走 fallback） |
| bridge-features 是否触发 | ❌ 否（被 normalize FAIL 拦住） | ✅ 是，5.03s 写完 4 个 dwd parquet |
| dwd 工件是否落 | ❌ 无 | ✅ `dwd/bridgedata_v2_scale30/v1/{pose_feature,press_event,trajectory_segment,episode_feature}.parquet` 齐全 |

→ bridge 这条线在 v1.6 已经**完全可用**，从 raw → ods → dwd 全程跑通。

### C. **新 root cause #1：`droid-qc` 0B pod log**（直接致 step FAIL，未给出任何错误信息）

`qc-contract-run.2368294939.log` 文件大小为 **0 字节**，意味着 step container 整个 stdout/stderr 流被 Argo `archiveLogs` 上传时是空的——业务进程在第一行 `print` / `logger.info` 之前就 crash 或被 SIGKILL。

**对账：droid 数据集 infra 侧完整可达**

```bash
mc stat rdh/robot-datasets/raw/droid_lerobot_scale30/v1/data/chunk-000/file-000.parquet
# Size: 82 MiB  ETag: 04b4522220cc78a7337bc4f561bc47db-6  立即返回
mc du rdh/robot-datasets/raw/droid_lerobot_scale30/v1/
# 18 GiB  546 objects（含 data/chunk-000 下 181 个 parquet，每个 81–84 MiB）
```

→ 与 fhkvr §3 同款"raw 完整、policy 通过、endpoint 可达"，**与 `robot-dh-infra` 无关**。

可能根因（按嫌疑排序，待 wsl 侧 `kubectl describe pod` / `kubectl logs --previous` 落地）：

1. **OOM**：`profile_parquet` 如果非 lazy 模式（误用 `pq.read_table`），单文件 82 MiB 解压成 Arrow 后可能 ~500 MiB；181 文件全部装内存就爆 step container（默认 limit 通常 2 Gi）
2. **fhkvr §5.1.1 lazy fix 未覆盖 droid 路径**：fhkvr 修的是 `profile_parquet(s3_uri)` 单文件入口，但 droid 是 **lerobot v2 多 chunk** dataset（`data/chunk-000/file-000.parquet` ... `file-180.parquet` + `meta/info.json` + `meta/stats.json` + `meta/tasks.parquet`）。如果上层用 `lerobot.LeRobotDataset(...)` 高阶接口去 profile，可能会触发 `lerobot` 包对 `videos/` 目录的全量遍历或 huggingface_hub 网络回源（meta 下 `videos/` 也是 raw layer 内的，但 lerobot 客户端默认会去 HF Hub 检查 revision）
3. **import / init error**：droid 走 lerobot adapter 时如果 `lerobot` 或其依赖（`pyav` / `torchvision`）不在 step container 镜像里，import 阶段就抛 `ModuleNotFoundError`，且因为 logger 还没初始化，整个 stderr 空
4. **activeDeadlineSeconds**：robomimic 跑了 7189s 才 PASS；droid 18 GiB > robomimic 6.5 GiB，如果 timeout 也是 ~7200s，可能 SIGKILL 一来就归档了空 log

> 0B archive 是 Argo controller 看到 pod terminated 时立即从 pod stdout 拉一次；如果 pod 是被 SIGKILL（OOMKilled / DeadlineExceeded）且 stdout buffer 没 flush，就会是空文件。详见 [`docs/v1_6_argo_log_archive_handoff.md`](../../../v1_6_argo_log_archive_handoff.md) §7。

### D. **新 root cause #2：`robomimic-qc` PASS 但 metric `episode_len_p50/p95 = 0`**（数据正确性问题）

`qc-contract-run.1939853856.log` 与 `s3://robot-lake/qc/robomimic_scale30/v1/contract_report.json`：

```json
{
  "status": "PASS",
  "metrics": {
    "demo_count": 21000,
    "num_hdf5_files": 26,
    "action_present_rate": 1.0,
    "obs_next_obs_mismatch_rate": 0.0,
    "reward_done_length_mismatch_rate": 0.0,
    "action_range_violation_rate": 0.0,
    "episode_len_p50": 0,    ← ★★ 21000 demos 不可能 p50=0
    "episode_len_p95": 0     ← ★★ 同上
  },
  "rules": [...],  // 5 条规则全 PASS，但都不覆盖 episode_len
  "duration_sec": 7189.94    ← 2 小时
}
```

asset_profile.json 的内容（17 KiB）显示 26 个 HDF5 文件全部 `readable=true`、`has_actions=true`、`actions_shape=[N, 7]`（每条 demo 的 action 长度 N 已经能拿到），但 contract_report 的 `episode_len_*` 完全没消费这条信息。

→ **不会让 step FAIL，但下游 ml-ready 报表里"平均 episode 长度"会显示 0**，与 demo_count=21000 自相矛盾，**统计学口径错位**。

性能侧（次要）：26 个 HDF5 串行 download + open，单文件 ~250 MiB 平均，端到端 7189s ≈ 2 小时；按 fhkvr §5.1.2 的 materialize-first 模式，单文件下载 ~30s + h5py 解析 ~10s ≈ 40s × 26 = 17min，**实际跑了 7×期望耗时**，疑似 download 没并发或者还在跑 demo 内容遍历（而不是只读 metadata）。

### E. **bridge-features 的 `status=WARN` 不是 bug**（次要 / 仅记录）

`etl_run END status=WARN duration=5.03s`：features 阶段把 `input_bytes=0` / `input_rows=0`（下载 5 个 ods 文件 total_size=0.0 MiB，可能是元数据探测后没真的 download bytes 计数）作为 warning 触发条件，但产物 4 个 parquet 都已经落 `dwd/bridgedata_v2_scale30/v1/`，`_manifest.json` size 1.9 KiB 正常。下游 ml-ready 应该能读。这条 WARN 建议主项目检查 `input_bytes` 统计口径，但不阻塞。

## 文件列表

```text
docs/runs/20260524/robot-dh-multisource-scale30-qptk9/
├── INDEX.md                              # 本文件
├── lake-list.3629310360.log              # 170 B  （discover-assets ✓）
├── qc-contract-run.2762137274.log        # 695 B  （bridge-qc ✓ PASS）
├── partition-plan.4186328431.log         # 1.1 KiB（bridge-partition ✓）
├── etl-phase.3352401365.log              # 6.2 KiB（bridge-normalize ✓ 业务 OK，perf 走 pending fallback）
├── etl-phase.2906995583.log              # 5.9 KiB（bridge-features ✓ 业务 WARN，dwd 4 parquet 已落）
├── qc-contract-run.1939853856.log        # 685 B  （robomimic-qc ✓ PASS，但 episode_len_p50/p95=0）
└── qc-contract-run.2368294939.log        # 0 B    （droid-qc ✗ FAIL，0B 无任何 stdout）
```

文件命名约定：`<step-name>.<argo-pod-hash>.log`，与 Argo UI / `s3://.../argo-logs/.../<pod-name>/main.log/main.log` 双向定位（与 dls4z / jddlp 同款）。

> Argo 模板里 `bridge-qc` / `robomimic-qc` / `droid-qc` 三个 task 都引用同一个 `qc-contract-run` template；落到 pod name 上都是 `...-qc-contract-run-<hash>`，**无法从 pod 名直接区分**。本表通过 contract_report 内容（`contract_id`）反推：`bridgedata_v2_v1` → `bridge-qc`，`robomimic_hdf5_v1` → `robomimic-qc`；剩下那个 0B 必然是 `droid-qc`。

## 与 jddlp / dls4z 关键事件对账（一表读完）

| 维度 | dls4z（5/24 早） | jddlp（5/24 晚） | qptk9（5/24-5/25 跨夜，本次） |
|------|------------------|------------------|---------------------------------|
| bridge-normalize 业务终态 | ❌ FAIL（adapter mismatch） | ✅ OK | ✅ OK |
| bridge-normalize step pod 退出码 | ❌ 非 0 | ❌ 非 0（perf record abort） | ✅ **0**（perf 走 pending fallback） |
| ods 工件是否落 | ❌ 无 | ✅ 是 | ✅ 是（与 jddlp 同份，SKIP via manifest） |
| **dwd 工件是否落** | ❌ 无 | ❌ 无 | ✅ **`dwd/bridgedata_v2_scale30/v1/{pose_feature,press_event,trajectory_segment,episode_feature}.parquet`** |
| qc-contract: bridge | ⚠ traj=314 失真 | ✅ traj_p50=108 正确 | ✅ traj_p50=108 正确 |
| qc-contract: robomimic | — 没跑到 | — 没跑到 | ✅ PASS **但 episode_len_p50/p95=0 失真** |
| qc-contract: droid | — 没跑到 | — 没跑到 | ❌ **FAIL（0B pod log）** |
| 多源 fanout（discover-assets fork） | 否 | 否 | ✅ **是**（首次跑到 droid/robomimic 通路） |
| Argo workflow 终态 | ❌ Failed | ❌ Failed | 🔄 Running（droid-qc 还在 retry） |

→ qptk9 **是 v1.6 第一条把 bridge 全链路完整跑通（包括 dwd 落地）+ 第一条开启 droid/robomimic QC 通路**的 workflow，曝出了 fhkvr §A 修复方案对 droid 多 chunk parquet 路径 / robomimic episode_len metric 的**未覆盖盲区**。下一步 fix 完全落在 wsl 侧 `robot-data-harness` 主项目：

→ 新需求文档：[`docs/v1_6_droid_robomimic_qc_request.md`](../../../v1_6_droid_robomimic_qc_request.md)
