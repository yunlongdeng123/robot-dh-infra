# `bridgedata_v2_scale30` 全链路适配需求（normalize / qc-contract / resume）

> 提交方：`robot-dh-infra`（云端 PostgreSQL / MinIO / Redis）
> 接收方：WSL 侧 `robot-data-harness` 主项目（step container 镜像、CLI、normalize adapter、qc-contract 规则、resume 语义）
> 优先级：P1（v1.6 `multisource-scale30` bridge-normalize 步骤当前 100% FAIL，且 qc-contract 静默漏检、resume 失效造成 7+ 分钟重复 IO）
> 关联：
>
> - [`docs/v1_6_fhkvr_step_failures_request.md`](v1_6_fhkvr_step_failures_request.md) §2 B 类、§5.2
> - [`docs/v1_6_argo_log_archive_request.md`](v1_6_argo_log_archive_request.md) §8 / §11.3
> - 本次完整 5-step log 归档（11.16 KiB，已从 MinIO 拉到本地）：
>   - 索引：[`docs/runs/20260524/robot-dh-multisource-scale30-dls4z/INDEX.md`](runs/20260524/robot-dh-multisource-scale30-dls4z/INDEX.md)
>   - 原始对象：`s3://robot-dh-artifacts/argo-logs/robot-dh/robot-dh-multisource-scale30-dls4z/`

## 1. 现场（完整 5-step 时间线）

`robot-dh-multisource-scale30-dls4z` 是 2026-05-24 在 WSL/kind 上提交的 multisource-scale30 workflow。本仓库从 `s3://robot-dh-artifacts/argo-logs/` 拉到完整 5 个 step pod 的 stdout（**首次**：之前 `fhkvr` 那一条因为 controller restart 之前提交所以没归档，本次 `dls4z` 是第一条端到端被 Argo `archiveLogs` 完整捕获的 workflow）。

| 顺序 | step | 状态 | 时长 / 关键事件 |
|------|------|------|-----------------|
| 1 | lake-list | ✓ OK | inventory，`s3://robot-lake/` raw 1 个对象 |
| 2 | qc-contract-run | ⚠ WARN（不阻塞 → §3.B 静默漏检） | `traj_len_p50=traj_len_p95=314`、`language_missing_rate=1.0` |
| 3 | partition-plan | ✓ OK（但估算失真） | `estimated_rows=931394`（实际 314）、单 partition 单 shard |
| 4 | etl-phase 第 1 次 | ✗ FAIL（792.4s） | job `etl-run-...-c403d410`，挂在 `normalize.load_bundles` |
| 5 | etl-phase 第 2 次 | ✗ FAIL（717.3s） | job `etl-run-...-3fa1ac19`，**同一位置同一错误**；尽管 `resume=True`，仍重做完整 `materialize_input`（227 MiB / 11min 53s） |

`lake-list` / `qc-contract-run` / `partition-plan` 的完整 JSON 见归档目录，下文只挑关键证据行。

致命错误是错误 A；B、C、D 是相关但分级更低的"顺手修"，强烈建议同一个 PR 一起做，否则即便 A 修了，下游报表 / 二次 IO 还会继续误导。

## 2. 错误清单与优先级

| # | 错误 | 致命？ | 阻塞 normalize？ | 责任方 |
|---|------|--------|------------------|--------|
| A | normalize adapter 不识别嵌套 action schema | 是 | 是 | robot-data-harness |
| B | qc-contract 阶段没穿透嵌套 schema，traj_len / language 统计失真 | 否（但报表口径错） | 否 | robot-data-harness（contract rules） |
| C | `resume=True` 在 normalize 上没生效，failed 重试会重做 `materialize_input` | 否（但浪费 11min/次） | 否 | robot-data-harness（resume 语义） |
| D | partition-plan `estimated_rows` 严重高估（931394 vs 实际 314） | 否（scale 起来才发作） | 否 | robot-data-harness（partition planner） |
| E | `Connection pool is full, discarding connection`，botocore 池子 10 撞 concurrency 8 | 否（但慢 7min） | 否 | robot-data-harness（boto3 Config） |

> infra 侧（`robot-dh-infra`）所有检查项均通过：raw shard 完整、`robotdhapp` policy / endpoint OK、log 已通过 `archiveLogs` 落 MinIO。详见 §6 "infra 端零改动证明"。

## 3. 错误根因（每条都附带原始日志行）

### 3.A normalize adapter 不识别 `mbodiai/oxe_bridge_v2` 嵌套 schema【致命】

**原始日志行**（两次 etl-phase 都有，job_id 不同）：

```text
hf_adapter[bridgedata_v2_scale30]: matched prefix 'bridgedata_v2', using registered adapter      [INFO]
bridgedata_v2 adapter: action column action in .../shard_0-00000-of-00001.parquet
  not coercible to 7-dim                                                                          [WARNING]
heartbeat ... phase=normalize.load_bundles ... msg=phase_failed: ValueError                       [INFO]
etl_run FAIL: bridgedata_v2 adapter could not extract any pose episode ... Schema may be unknown;
  sample columns: ['absolute_action', 'action', 'episode_idx', 'image', 'metadata',
                  'observation', 'state', 'step_idx', 'supervision', 'timestamp'].                [ERROR]
```

**根因**：raw 是 `mbodiai/oxe_bridge_v2`（见 [`scripts/32_pull_scale_30gb_hf.sh`](../scripts/32_pull_scale_30gb_hf.sh) L174-179），它把 action 拆成嵌套 struct，而 adapter 期望扁平 7-float array。

raw shard 的实测 pyarrow schema（pyarrow 18.x）：

```text
image:           struct<bytes: binary, path: string>
observation:     struct<image: struct<bytes, path>, task: string>
action:          struct<
                    pose:  struct<x, y, z, roll, pitch, yaw: double>,
                    grasp: double
                  >
absolute_action: struct<                                            # 与 action 同构
                    pose:  struct<x, y, z, roll, pitch, yaw: double>,
                    grasp: double
                  >
state:           struct<
                    end_effector_pose: struct<x, y, z, roll, pitch, yaw: double>,
                    is_first / is_last / is_terminal: int64,
                    language_embedding: list<double>
                  >
supervision:     double
episode_idx:     int64
step_idx:        int64
timestamp:       double
metadata:        struct<...19 fields, 全部为 dataset-level 常量...>
```

总 314 行 / 3 个 episode（`episode_idx ∈ {0, 1, 2}`，分别 131 / 108 / 75 步），单 shard 227 MiB（主要是 image bytes）。

### 3.B qc-contract 阶段没穿透嵌套 schema（静默漏检）

**原始日志行**（`qc-contract-run.149848334.log`）：

```json
{
  "run_id": "qc-bridgedata_v2_v1-40ec85d575",
  "contract_id": "bridgedata_v2_v1",
  "status": "WARN",
  "metrics": {
    "num_parquet_files": 1,
    "parquet_valid_rate": 1.0,
    "traj_len_p50": 314,
    "traj_len_p95": 314,
    "language_missing_rate": 1.0,
    "image_ref_missing_rate": 0.0,
    "action_column_coverage": 1.0
  }
}
```

**问题**：

1. `traj_len_p50 = traj_len_p95 = 314` — 把整个 parquet 当成 **1 条 trajectory**，没按 `episode_idx` 切分。实际是 3 条，长度 131/108/75，正确的 p50 应为 ~108，p95 应为 ~131。
2. `language_missing_rate = 1.0` — `state.language_embedding` 在嵌套 `list<double>` 里，QC 没穿透 struct 字段路径。

**影响**：哪怕 normalize（错误 A）修了，下游 contract gate / OpenLineage `dataQuality` facet 仍然报"language 全部缺失、trajectory 长度异常长尾"，会误导后续 v1.7 的 schema evolution / dataset card 自动化。

### 3.C `resume=True` 在 normalize 阶段未生效（导致重复 IO）

**原始日志行对比**：

```text
# 第 1 次 etl-phase (job c403d410)
10:45:36 etl_run START: ... phase=normalize resume=True force=False
10:45:39 heartbeat ... msg=materialize_input.start
10:58:45 heartbeat ... msg=materialize_input.done                          # 耗时 8min 13s
10:58:49 etl_run FAIL: ... duration=792.41s

# 第 2 次 etl-phase (job 3fa1ac19，12 分钟后)
10:59:06 etl_run START: ... phase=normalize resume=True force=False        # ← resume=True
10:59:07 heartbeat ... msg=materialize_input.start                          # ← 又开始下载
11:10:59 heartbeat ... msg=materialize_input.done                          # 耗时 11min 53s
11:11:04 etl_run FAIL: ... duration=717.25s
```

**根因**：两次 etl-phase 的 workdir 路径不同（`-6ft_moqx/` → `-16hgbar3/`），说明第 1 次失败时 step container 退出，本地 `/run/robot-dh/workdir/...` 被清理，resume 判断只看本地 workdir + heartbeat，没看 ods 端 `_manifest.json`。

**期望语义**：`resume=True` 时优先检查 `s3://robot-lake/ods/<dataset>/<version>/_manifest.json` + 上一次 etl_perf_runs 的 `phase_progress`，能跳过整个 materialize_input 阶段，最多重做 `load_bundles` 之后的 step。

### 3.D partition-plan `estimated_rows` 严重高估

**原始日志行**（`partition-plan.332445971.log`）：

```json
{
  "partition_id": "part-d7e01174d1fa-p000",
  "input_files": ["s3://robot-datasets/raw/bridgedata_v2_scale30/v1/data/shard_0-00000-of-00001.parquet"],
  "input_bytes": 238436886,
  "estimated_rows": 931394
}
```

实际 `parquet.metadata.num_rows = 314`，差了 2965 倍。

**根因**：partition planner 用了 `total_input_bytes / avg_row_size` 估算，但 avg_row_size 没考虑 image bytes 占 99% 以上（每行 ~760 KiB，而非常规 ~256 B）。当前 workflow 是单 partition 单 shard 不影响决策，但 scale100 / scale1000 时会按错误的高 estimated_rows 切出过多并发，浪费 worker 槽位。

### 3.E `Connection pool is full, discarding connection`

**原始日志行**（5 次，第 1 次 etl-phase）：

```text
10:53:57 Connection pool is full, discarding connection: 82.156.129.81. Connection pool size: 10  [WARNING]
10:54:22 Connection pool is full, discarding connection: ...
10:54:42 ...
10:58:22 ...
10:58:45 ...
```

`download_dir(concurrency=8)` 撞上 botocore 默认 `max_pool_connections=10`，丢弃 + 重建 TCP。227 MiB 下载 8min 13s，平均吞吐 0.46 MiB/s。修复见 §4.E。

## 4. 修复方向

### 4.A adapter 加 schema sniff + episode 切分（必须）

```python
def adapt_bridgedata_v2(table: pa.Table) -> NormalizedEpisodes:
    action_field = table.schema.field("action")

    if pa.types.is_struct(action_field.type):
        # mbodiai/oxe_bridge_v2 变体
        if _is_pose_grasp_struct(action_field.type):
            action_flat   = _flatten_pose_grasp(table.column("action"))           # -> list<double>(7)
            absolute_flat = _flatten_pose_grasp(table.column("absolute_action"))  # 同处理
            state_ee      = _flatten_pose(table.column("state").field("end_effector_pose"))  # 6-dim
            return _emit_episodes(table, action_flat, absolute_flat, state_ee)
        raise ValueError(f"unrecognized struct layout for action: {action_field.type}")

    if pa.types.is_list(action_field.type) or pa.types.is_fixed_size_list(action_field.type):
        # 原版 OXE BridgeData V2 扁平 7-float 数组
        return _legacy_flat_path(table)

    raise ValueError(f"unsupported action type: {action_field.type}")
```

episode 切分用 raw 已有的 `episode_idx` / `step_idx`，**直接 group by `episode_idx`、按 `step_idx` 排序**：

```python
for ep_id, sub in table.group_by("episode_idx"):
    sub = sub.sort_by("step_idx")
    yield Episode(
        episode_id=f"{dataset_id}_ep{ep_id:05d}",
        action=sub.column("action_flat").to_numpy(zero_copy_only=False),         # (T, 7)
        absolute_action=sub.column("absolute_action_flat").to_numpy(...),         # (T, 7)
        ee_pose=sub.column("state_ee_flat").to_numpy(...),                        # (T, 6)
        is_first=sub.column("state").field("is_first").to_numpy(),
        is_last=sub.column("state").field("is_last").to_numpy(),
        timestamp=sub.column("timestamp").to_numpy(),
        language_embedding=sub.column("state").field("language_embedding").to_pylist(),
        task=sub.column("observation").field("task").to_pylist(),
    )
```

`_flatten_pose_grasp` 真正实现建议走 `pc.struct_field` + vectorized concat，避免 Python 行级循环：

```python
def _flatten_pose_grasp(arr: pa.StructArray) -> pa.FixedSizeListArray:
    """struct<pose: struct<x,y,z,roll,pitch,yaw>, grasp> -> fixed_size_list<double>(7)。"""
    pose = arr.field("pose")
    children = [pose.field(k) for k in ("x", "y", "z", "roll", "pitch", "yaw")]
    children.append(arr.field("grasp"))
    return pa.FixedSizeListArray.from_arrays(
        pa.concat_arrays([_interleave(*children)]),  # 由具体 pyarrow 版本决定 interleave 方式
        list_size=7,
    )
```

### 4.B qc-contract 规则适配嵌套 schema

`bridgedata_v2_v1` contract 当前的 traj_len / language 规则建议改成：

```yaml
# qc_contracts/bridgedata_v2_v1.yaml（示意）
metrics:
  traj_len:
    aggregation: per_episode             # 之前隐含 per_file，导致 314 当作一条
    group_by: episode_idx
    percentiles: [50, 95]
  language:
    field_path: state.language_embedding  # 之前用 'language'，路径错位 → 100% missing
    missing_rule: is_null_or_empty_list   # list<double> 长度 0 视为 missing
```

### 4.C resume 语义改成"ods 端 manifest 优先"

```python
def should_skip_materialize_input(dataset_id, version, resume, force) -> bool:
    if force or not resume:
        return False

    # 远端 manifest 已经在，跳过 materialize_input
    ods_manifest = f"s3://robot-lake/ods/{dataset_id}/{version}/_manifest.json"
    if s3.object_exists(ods_manifest):
        # 还要校验 manifest.input_sha == raw 当前 sha，避免 raw 已变化
        return s3.read_json(ods_manifest).get("input_sha") == compute_raw_sha(dataset_id, version)

    # 没有 ods manifest，但有 etl_perf_runs 的 progress，且 phase_progress >= materialize_input.done
    last_run = pg.fetch_last_run(dataset_id, version, phase="normalize")
    return bool(last_run and last_run.phase_progress and
                last_run.phase_progress.get("materialize_input") == "done")
```

### 4.D partition planner 改成"读 parquet metadata 拿真实 num_rows"

partition planner 已经持有 input parquet 的 S3 URI，加一次 `pq.ParquetFile(s3path).metadata.num_rows` 即可。对单 shard 100 MiB+ 的 parquet，footer 读取约 50 KiB，~50ms 不影响 plan 耗时。

```python
def estimate_rows(file_uri: str) -> int:
    # 之前：return int(total_input_bytes / AVG_ROW_SIZE_BYTES)
    pf = pq.ParquetFile(_open_s3(file_uri))  # 只读 footer
    return pf.metadata.num_rows
```

如果担心 `_open_s3` 额外引入 fsspec/s3fs 依赖，也可以在 partition plan 阶段直接 fallback 到上一阶段 lake-list 已经写好的 `parquet_num_rows` 字段（如果有）。

### 4.E botocore connection pool 抬高

```python
from botocore.config import Config

s3 = boto3.client(
    "s3",
    config=Config(
        max_pool_connections=max(32, concurrency * 2),   # 之前隐式 10
        retries={"max_attempts": 10, "mode": "adaptive"},
        connect_timeout=10,
        read_timeout=300,
    ),
)
```

把 normalize materialize_input 阶段从 ~8min 砍到 ~1.5min（27 MiB/s 下行带宽）。

### 4.F 是否动 raw？

**不动**。`mbodiai/oxe_bridge_v2` 已经落在 `s3://robot-datasets/raw/bridgedata_v2_scale30/v1/`，重新 ingest 原版 OXE 的成本（30 min + 30 GiB 重传）远高于 §4.A 的 adapter 修复。

## 5. 测试样本与日志（本仓库已备好，scp 拉取一次到位）

```text
robot-dh-infra/
├── docs/v1_6_bridgedata_v2_normalize_adapter_request.md      # 本文档
├── docs/samples/bridgedata_v2_scale30/                       # 数据样本
│   ├── shard_0-sample.parquet                                # 32 KiB, 40 行, ep_idx ∈ {0, 1}
│   ├── schema.txt                                            # 完整 pyarrow schema
│   ├── schema.json                                           # 上游 HuggingFace dataset_info.features
│   └── _manifest.json                                        # 来源 + sha256
├── docs/runs/20260524/robot-dh-multisource-scale30-dls4z/    # 失败 workflow 完整 log
│   ├── INDEX.md                                              # 5-step 时间线 + 关键事件
│   ├── lake-list.3736841068.log                              # 170 B
│   ├── qc-contract-run.149848334.log                         # 671 B
│   ├── partition-plan.332445971.log                          # 1.1 KiB
│   ├── etl-phase.4145881001.log                              # 4.6 KiB （第 1 次 FAIL）
│   └── etl-phase.1528822700.log                              # 4.6 KiB （第 2 次 FAIL）
└── scripts/make_bridgedata_v2_sample.py                      # 样本生成器（可复跑、校 sha256）
```

### 5.1 样本生成策略

详见 [`scripts/make_bridgedata_v2_sample.py`](../scripts/make_bridgedata_v2_sample.py)：

- 从原 shard 抽 `episode_idx ∈ {0, 1}` 各前 20 步，共 40 行
- **保持完整 schema 形状**（嵌套 action / state / metadata 一行没改），保证主项目修 adapter / contract 时面对的列结构 = 生产环境 100% 一致
- 把 `image.bytes` 与 `observation.image.bytes` 字段置 null，文件大小 227 MiB → 32 KiB
- `_manifest.json` 含 sha256，主项目 CI 可直接对比 fixture 是否被偶然篡改

### 5.2 完整失败 log 归档说明

5 个 step pod 的 stdout 全部来自 `s3://robot-dh-artifacts/argo-logs/`（Argo `archiveLogs` 已开启）。命名约定 `<step-name>.<argo-pod-hash>.log`，可与 Argo UI / S3 原始对象双向定位。详细分析见 `INDEX.md`。

### 5.3 主项目 fixture 建议位置

```text
robot_data_harness/tests/fixtures/bridgedata_v2_scale30/
├── shard_0-sample.parquet     # 从本仓库复制过去
├── _manifest.json             # 复制 sha256 校验
└── README.md                  # 引用本文档 §5
```

CI 单测最小化形态（错误 A）：

```python
def test_bridgedata_v2_struct_action_path():
    tbl = pq.read_table("tests/fixtures/bridgedata_v2_scale30/shard_0-sample.parquet")
    episodes = list(adapt_bridgedata_v2(tbl))
    assert len(episodes) == 2                       # ep 0, ep 1
    assert episodes[0].action.shape == (20, 7)      # 20 步, 7-dim
    assert episodes[0].ee_pose.shape == (20, 6)     # 6-dim end-effector
    assert all(ep.action.dtype == np.float64 for ep in episodes)
```

错误 B 同样可以基于这个 fixture 跑 contract（应能拿到 `traj_len_p50 ≈ 20`、`language_missing_rate < 1.0`）。

## 6. infra 端零改动证明（`robot-dh-infra` 这边不需要动手）

| 检查项 | 结论 | 证据 |
|--------|------|------|
| `robotdhapp` 是否能读 raw | ✅ | etl-phase 已 `materialize_input.done`，227 MiB shard 已落到 step container 本地 |
| raw shard 完整性 | ✅ | `_manifest.json` 中 `size_bytes=238436886` 与本地落盘字节数完全一致 |
| MinIO endpoint 可达 | ✅ | 错误 E 是 urllib3 池子打满，不是连不上 |
| log 是否已落 MinIO | ✅ | `s3://robot-dh-artifacts/argo-logs/robot-dh/robot-dh-multisource-scale30-dls4z/` 共 5 个 `main.log` 对象，11.16 KiB |
| schema 是否被 adapter 支持 | ❌ | 见错误 A |
| schema 是否被 qc 穿透 | ❌ | 见错误 B |
| resume 是否生效 | ❌ | 见错误 C |

→ 全部改动落在 `robot-data-harness` 主项目。`robot-dh-infra` 仅提供测试样本 + 日志归档 + 本需求文档。

## 7. 验收清单

| # | 项 | 责任方 | 通过标准 |
|---|----|--------|----------|
| 1 | adapter 对嵌套 schema 不再抛 `not coercible to 7-dim`，至少 yield 2 个 episode | robot-data-harness | 用 `docs/samples/.../shard_0-sample.parquet` 跑单测：`len(episodes) == 2`，shape `(20,7)` / `(20,6)`；端到端 `mc ls rdh/robot-lake/ods/bridgedata_v2_scale30/v1/` 至少含 `pose.parquet` |
| 2 | 原版 OXE 扁平 schema 路径不回归 | robot-data-harness | 已有 `bridgedata_v2` adapter 单测全绿 |
| 3 | qc-contract 报表 `traj_len_p50` ≈ 真实 episode 中位长度，不再恒等 `num_rows`；`language_missing_rate` < 1.0 | robot-data-harness | 用本仓库 fixture 跑 contract，`traj_len_p50 ≈ 20` 而不是 40；`language_missing_rate < 1.0` |
| 4 | `resume=True` 时第 2 次 etl-phase 不再重做 materialize_input | robot-data-harness + WSL/kind | 故意 FAIL 一次（删一个 ods/manifest 字段触发）后第 2 次提交：`etl-phase.<hash>.log` 里 `materialize_input` 全程 < 5s（仅做 manifest 校验） |
| 5 | partition planner `estimated_rows` 误差 < 5% | robot-data-harness | `partition-plan.<hash>.log` 中 `estimated_rows` 与 `parquet.num_rows` 比例 ∈ [0.95, 1.05] |
| 6 | botocore `Connection pool is full` 消失 | robot-data-harness | 全程下载 227 MiB 时 stderr 不再出现 `Connection pool is full` WARNING；耗时 ≤ 90s（27 MiB/s 下行） |
| 7 | 端到端 `multisource-scale30` workflow 跑到 Succeeded | robot-data-harness + WSL/kind | argo UI 节点全绿；`s3://robot-dh-artifacts/argo-logs/.../<etl-phase pod>/main.log/main.log` 末尾 summary `status=OK` |
| 8 | infra 侧零改动 | `robot-dh-infra` 自验 | 本文档提交后到主项目联调通过前，本仓库 main 分支无新增功能 commit（只允许文档 / 样本类提交） |

## 8. 时间窗口建议

| 阶段 | 预估 | 备注 |
|------|------|------|
| 跑 `docs/samples/.../shard_0-sample.parquet` 触发现有 adapter 单测（预期红） | < 30min | 复现路径 |
| §4.A adapter sniff + episode 切分 | 1 day | 单测含错误 A 验收第 1 项 |
| §4.B qc-contract 规则适配 | 0.5 day | 调 `qc_contracts/bridgedata_v2_v1.yaml` + contract runner 穿透 |
| §4.C resume 改 ods-manifest 优先 | 0.5 day | 同时审计 `etl_perf_runs.phase_progress` 字段 |
| §4.D partition planner 读 footer | < 1h | 同 PR 顺手 |
| §4.E botocore Config | < 1h | 同 PR 顺手 |
| 主项目镜像重 build + 推 registry | < 30min | 走现有 CI |
| WSL/kind 联调 `make argo-submit-multisource-scale30` | 1 day | 终态后云端拉 5 个 step log 重做本文档 §1 的时间线 |

总计 ~3.5 天。收到主项目修复 PR + 联调通过截图（`mc ls -r robot-dh-artifacts/argo-logs/...` + `s3://robot-lake/ods/bridgedata_v2_scale30/v1/` 列表）后，本文档可标 **「已闭环」**，同步更新 [`docs/v1_6_fhkvr_step_failures_request.md`](v1_6_fhkvr_step_failures_request.md) §2 B 类与 [`docs/v1_6_argo_log_archive_request.md`](v1_6_argo_log_archive_request.md) §11.3 的引用处。

## 9. 本仓库这边的 follow-up

| 项 | 状态 |
|----|------|
| `s3://robot-dh-artifacts/argo-logs/` 5-step log 已落 | ✅ 已落（dls4z 5 个 step pod 全归档） |
| 完整 log 拉到本地 `docs/runs/20260524/robot-dh-multisource-scale30-dls4z/` | ✅ 已落 |
| `INDEX.md` 时间线分析 | ✅ 已落 |
| 数据样本 `docs/samples/bridgedata_v2_scale30/` | ✅ 已落 |
| 样本生成脚本 `scripts/make_bridgedata_v2_sample.py` | ✅ 已落 |
| raw shard / MinIO policy / bucket / endpoint 保持不动 | ✅ 不动 |
| `docs/v1_6_argo_log_archive_request.md` §11.3 末尾追加 "对象端验收通过（dls4z 5 个 step pod main.log 已归档）" | ⏭ 主项目联调通过后再补 |

## 10. scp 拉取（一条命令拉完）

把本次需求所需的 **文档 + 数据样本 + 失败 log + 样本脚本** 一次性拉到 WSL：

```bash
# 在 WSL 本地（接收方）执行：把 4 类产物完整拉到 ./robot-dh-fhkvr-bundle/
mkdir -p ./robot-dh-fhkvr-bundle
scp -r ubuntu@<cloud-host>:/home/ubuntu/robot-dh-infra/docs/v1_6_bridgedata_v2_normalize_adapter_request.md \
       ubuntu@<cloud-host>:/home/ubuntu/robot-dh-infra/docs/v1_6_fhkvr_step_failures_request.md \
       ubuntu@<cloud-host>:/home/ubuntu/robot-dh-infra/docs/samples/bridgedata_v2_scale30 \
       ubuntu@<cloud-host>:/home/ubuntu/robot-dh-infra/docs/runs/20260524/robot-dh-multisource-scale30-dls4z \
       ubuntu@<cloud-host>:/home/ubuntu/robot-dh-infra/scripts/make_bridgedata_v2_sample.py \
       ./robot-dh-fhkvr-bundle/
```

拉完后本地结构（拍平）：

```text
robot-dh-fhkvr-bundle/
├── v1_6_bridgedata_v2_normalize_adapter_request.md     # 本文档
├── v1_6_fhkvr_step_failures_request.md                 # 上一轮三类错误归因（B 类是本文档）
├── bridgedata_v2_scale30/                              # 数据样本目录
│   ├── shard_0-sample.parquet
│   ├── schema.txt
│   ├── schema.json
│   └── _manifest.json
├── robot-dh-multisource-scale30-dls4z/                 # 失败 workflow 完整 log
│   ├── INDEX.md
│   ├── lake-list.3736841068.log
│   ├── qc-contract-run.149848334.log
│   ├── partition-plan.332445971.log
│   ├── etl-phase.4145881001.log
│   └── etl-phase.1528822700.log
└── make_bridgedata_v2_sample.py                        # 样本生成器
```

校验完整性（可选）：

```bash
cd ./robot-dh-fhkvr-bundle/bridgedata_v2_scale30
sha256sum -c <(jq -r '"\(.sample.sha256)  \(.sample.path)"' _manifest.json)
# 期望输出：shard_0-sample.parquet: OK
```

> 如果你只想要数据样本 + 失败 log（不想要文档 / 脚本），可以裁剪成：
>
> ```bash
> scp -r ubuntu@<cloud-host>:/home/ubuntu/robot-dh-infra/docs/samples/bridgedata_v2_scale30 \
>        ubuntu@<cloud-host>:/home/ubuntu/robot-dh-infra/docs/runs/20260524 \
>        ./
> ```
