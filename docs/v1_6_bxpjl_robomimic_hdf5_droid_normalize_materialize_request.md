# robomimic HDF5 probe 仍未修 + droid-normalize 全量 materialize 失败 + bridge-qc duration 未收敛 修复需求

> 提交方：`robot-dh-infra`（云端 PostgreSQL / MinIO / Redis）
> 接收方：WSL 侧 `robot-data-harness` 主项目
> 优先级：P1（v1.6 `multisource-scale30` 第 6 次提交仍无法到达 `ml-ready`）
> 关联：
>
> - 本次完整 step 归档：[`docs/runs/20260525/robot-dh-multisource-scale30-bxpjl/INDEX.md`](runs/20260525/robot-dh-multisource-scale30-bxpjl/INDEX.md)
> - 上一份需求：[`docs/v1_6_fvx5z_robomimic_hdf5_droid_normalize_request.md`](v1_6_fvx5z_robomimic_hdf5_droid_normalize_request.md)
> - 再上一份需求：[`docs/v1_6_ddbfb_qc_regression_and_droid_normalize_request.md`](v1_6_ddbfb_qc_regression_and_droid_normalize_request.md)

## 1. 背景

`robot-dh-multisource-scale30-bxpjl` 是 WSL 侧消化 `fvx5z` 需求后的下一次 `multisource-scale30` 联调。结果比 `fvx5z` 多暴露了一层信息：

```text
已推进：
- droid-normalize 不再是 0 archive log：两个 retry pod 都有 runner_boot 与阶段日志。
- droid-qc 稳定 PASS，duration 从 39.75s 收敛到 1.03s。
- bridge-qc metric 继续正确：traj_len_p50=108, traj_len_p95=131, episode_count=3。

仍阻塞：
- robomimic-qc 仍然无法 probe HDF5，两个 retry pod 合计 12 行 RetriesExceededError，无新 contract_report。
- droid-normalize 两次都在 materialize_input 全量下载 532 个非视频文件 / 12.1 GiB 后失败，每次耗时 4h+。
- droid-normalize 失败后 _checkpoint.json 仍保持 status=RUNNING，ODS 目录仍无 manifest / parquet。
- bridge-qc duration 仍 1096s，未达到 < 30s 的验收目标。
```

本次不是 infra endpoint / policy / raw 数据缺失问题。相同 workflow 内 `droid-qc`、`bridge-qc`、`droid-partition`、`bridge-normalize`、`bridge-features` 均能读写 MinIO，且 Argo `archiveLogs` 已经能抓到所有实际启动的 pod stdout。

## 2. 错误清单与优先级

| # | 错误 | 致命？ | 阻塞下游？ | 责任方 |
|---|------|--------|------------|--------|
| F1 | `robomimic-qc` HDF5 probe 仍然全失败；`cause_type` 仍是 `RetriesExceededError` 自引用；没有新的 `contract_report.json` | 是 | 是，robomimic 通路无法进入后续阶段 | WSL `robot-data-harness` |
| F2 | `droid-normalize` 不再静默，但每次 retry 都全量 materialize 12.1 GiB 后 `Max Retries Exceeded`；未使用 partition plan 做有界输入 | 是 | 是，droid ODS 没有任何产物 | WSL `robot-data-harness` |
| F3 | `droid-normalize` 失败后 checkpoint 仍是 `RUNNING`，导致 resume / 监控看到脏状态 | 是 | 是，下一次运行无法准确判断旧状态 | WSL `robot-data-harness` |
| F4 | `bridge-qc` duration 仍 1096s；lazy/footer enrichment timeout 没有被硬 cap 到 < 30s | 否 | 否，但浪费算力且验收未过 | WSL `robot-data-harness` |

`etl_perf_runs` 的 `started_at` schema drift 本次继续触发 pending fallback，累计 8 条 pending record。该项是 infra 侧已知迁移项，不作为本需求对 WSL 的阻塞要求。

## 3. 本次现场证据

### 3.1 droid-qc 与 droid-partition 证明 raw 数据和读权限可用

`qc-contract-run.241985536.log`：

```text
status=PASS
duration_sec=1.0258028507232666
num_parquet_files=156
num_episodes=95658
num_frames=27630375
num_videos=14
parquet_valid_rate=1.0
```

`partition-plan.1336333997.log`：

```text
dataset_id=droid_lerobot_scale30
dataset_family=droid
total_input_bytes=19269555036
partitions=6
target_partition_size_bytes=2147483648
```

这两步在同一个 workflow 内使用同一套 `ROBOT_DH_S3_*` secret。它们能正常读 raw、写 report / partition plan，说明 droid raw 对象、MinIO endpoint、bucket policy 都不是主因。

### 3.2 droid-normalize 失败点已经明确

两次 retry 日志完全同款：

```text
materialize_input: lerobot v2 layout detected, skipping prefixes=('videos/',)
S3 download_dir: bucket=robot-datasets prefix=raw/droid_lerobot_scale30/v1/ files=532 total_size=12058.9 MiB concurrency=8 excluded=14 files (6318.0 MiB)
heartbeat ... phase=normalize.materialize_input ... msg=phase_failed: RetriesExceededError
etl_run FAIL: Max Retries Exceeded
```

耗时：

| pod | 开始 | 结束 | duration |
|-----|------|------|----------|
| `etl-phase.2633268923.log` | 2026-05-25 09:40:03 CST | 2026-05-25 13:42:44 CST | 14560.94s |
| `etl-phase.2163642686.log` | 2026-05-25 13:43:03 CST | 2026-05-25 17:45:59 CST | 14576.02s |

当前 lake 侧状态：

```text
$ mc cat rdh/robot-lake/ods/droid_lerobot_scale30/v1/_checkpoint.json
{
  "dataset_id": "droid_lerobot_scale30",
  "version": "v1",
  "phase": "normalize",
  "status": "RUNNING",
  "completed_steps": [],
  "files": {},
  "metrics": {},
  "updated_at": "2026-05-25T05:43:04Z"
}

$ mc ls rdh/robot-lake/ods/droid_lerobot_scale30/v1/
_checkpoint.json 365B
```

也就是说，业务进程明明打印了 `etl_run FAIL`，但 checkpoint 没有被更新成 `FAILED`。

### 3.3 robomimic-qc 仍未产出新 report

本次两个 robomimic retry pod：

```text
qc-contract-run.2829358379.log  # 4 行 hdf5 probe failed
qc-contract-run.3433499758.log  # 8 行 hdf5 probe failed
```

代表性日志：

```text
hdf5 probe failed for s3://robot-datasets/raw/robomimic_scale30/v1/v1.5/can/mg/low_dim_dense_v15.hdf5: error_type=RetriesExceededError error=Max Retries Exceeded cause_type=RetriesExceededError cause=Max Retries Exceeded
```

`mc stat rdh/robot-lake/qc/robomimic_scale30/v1/contract_report.json` 仍显示：

```text
Date: 2026-05-25 01:11:45 CST
Size: 2.0 KiB
```

这是旧的 qptk9 report，不是 bxpjl 新产物。

### 3.4 bridge-qc duration 仍未收敛

当前 `contract_report.json`：

```text
status=PASS
duration_sec=1096.160436630249
traj_len_p50=108
traj_len_p95=131
episode_count=3
```

日志中唯一 warning：

```text
bridge metrics enrichment failed ... error_type=IndexError cause_type=FSTimeoutError error=tuple index out of range
```

外层 `IndexError` 与内层 `FSTimeoutError` 说明 enrichment 仍可能在 S3 lazy read / footer path 上长时间等待，然后再被上层 tuple 解包逻辑包装。该路径不应让一个可选 enrichment 把 QC step 拖到 18 分钟。

## 4. 修复需求

### 4.1 F1：robomimic HDF5 probe 必须改为 materialize-first

请在 `robot-data-harness` 的 robomimic profile / QC 代码里彻底移除 HDF5 远端 range read 路径。不要让 `h5py` 直接打开 `s3://...hdf5`，也不要经由 `fsspec` / `s3fs` 做远端 HDF5 读取。

要求：

1. 每个 HDF5 对象先用 `boto3.download_file` 或等价的 multipart 下载到本地临时文件。
2. 下载完成后只用本地路径交给 `h5py.File(local_path, "r")` 读取结构和样本。
3. 每个文件有明确的 per-file timeout / retry cap，失败日志必须包含对象 key、已下载字节数、耗时、`error_type`、底层 cause。
4. probe 可并发，但并发要有上限，建议 `ThreadPoolExecutor(max_workers=4)` 或读取环境变量 `ROBOT_DH_QC_PROBE_CONCURRENCY`。
5. 临时文件落到 `ROBOT_DH_INPUT_CACHE_DIR` 或 pod ephemeral storage，结束后清理。
6. `cause_type` 必须取 `exc.__cause__` / `exc.__context__` 中最底层的具体异常类；禁止再把 `exc` 自己当 cause。

建议实现骨架：

```python
def _root_cause(exc: BaseException) -> BaseException | None:
    """返回链式异常中最底层的具体原因。"""
    cur: BaseException | None = exc
    seen: set[int] = set()
    last: BaseException | None = None
    while cur is not None and id(cur) not in seen:
        seen.add(id(cur))
        last = cur
        cur = cur.__cause__ or cur.__context__
    return last if last is not exc else None


def profile_hdf5_object(uri: str, cache_dir: Path, s3: S3Client) -> Hdf5Profile:
    """先整文件落地，再用本地 h5py 读取 robomimic HDF5。"""
    local_path = cache_dir / stable_name_from_uri(uri)
    download_s3_object(uri, local_path, s3=s3, timeout_sec=600)
    with h5py.File(local_path, "r") as h5:
        return read_robomimic_hdf5_profile(h5)
```

验收：

| 检查项 | 通过标准 |
|--------|----------|
| 新 workflow 的 `robomimic-qc` | `status=PASS`，产出新的 `s3://robot-lake/qc/robomimic_scale30/v1/contract_report.json` |
| report 更新时间 | `mc stat` 显示 `Last Modified` 晚于本次 workflow 启动时间 |
| 日志 | 不再出现 `hdf5 probe failed ... cause_type=RetriesExceededError cause=Max Retries Exceeded` 自引用 |
| 性能 | 26 个 HDF5 文件总耗时 < 20min；如有单文件失败，日志必须能定位具体 key 和底层异常 |
| 单测 | 覆盖 `__cause__` / `__context__` 提取，确保 `cause_type` 不等于外层 `RetriesExceededError` |

### 4.2 F2：droid-normalize 必须按 partition 做有界输入，不能每次全量下载 root prefix

本次 droid partition 已经把 raw 输入切成 6 个 partition，但 normalize pod 实际仍执行：

```text
download_dir prefix=raw/droid_lerobot_scale30/v1/ files=532 total_size=12058.9 MiB
```

这说明 normalize 没有消费上游 partition plan，或者 CLI / WorkflowTemplate 没把 partition 文件列表传给 normalize。请修复 DAG 参数传递和 normalize 入口。

要求：

1. droid-normalize 的每个分片 pod 只处理自己 partition 的 `input_files`，禁止从 root prefix 全量 `download_dir`。
2. 如果当前 CLI 只有 `--dataset` root 参数，请新增或接线已有的 `--partition-plan-uri`、`--partition-index`、`--input-files-json` 之一。
3. LeRobot v2 normalize 只 materialize 当前 partition 必需的 parquet/meta 文件，继续跳过 `videos/`，并且不要下载与当前 partition 无关的 chunk。
4. `materialize_input` 必须打印进度：总文件数、已完成文件数、当前 key、累计下载 MiB、最近一次异常 cause。
5. 单文件下载使用有界 S3 config，建议 `connect_timeout=5`、`read_timeout=60`、`retries={"max_attempts": 3, "mode": "standard"}`。不要让单次 root prefix 下载静默跑 4 小时。
6. 重试策略要避免重复做同一轮 12 GiB 全量下载。相同 root-prefix `RetriesExceededError` 二次出现时应 fail fast，并保留清晰错误。

验收：

| 检查项 | 通过标准 |
|--------|----------|
| droid-normalize 日志 | 每个 pod 打印 partition id / partition index / input_files 数量；不再出现 root prefix `files=532 total_size=12058.9 MiB` |
| droid-normalize 结果 | 至少产出 `s3://robot-lake/ods/droid_lerobot_scale30/v1/_manifest.json`、`pose.parquet`、`episode_meta.parquet` |
| 失败语义 | 如仍失败，单个 pod 应 < 30min 退出，并在日志中给出具体 key + root cause |
| workflow | droid 分支不再 8 小时级重复 retry 同一个 full download |

### 4.3 F3：checkpoint 必须在异常路径写成 FAILED

本次最危险的状态是：日志已经 `etl_run FAIL`，但 lake checkpoint 仍是 `RUNNING`。这会让下一次 `--resume` 误判旧状态，也会让外部监控认为任务还活着。

要求：

1. normalize 进入阶段时可写 `RUNNING`，但任何异常退出前必须 best-effort 写 `FAILED`。
2. `FAILED` checkpoint 至少包含：
   - `failed_step`
   - `error_type`
   - `error_message`
   - `failed_at`
   - `workflow_name`
   - `job_id`
3. checkpoint 写入失败时必须向 stderr/stdout 打印 fallback JSON，保证 Argo archiveLogs 可见。
4. `--resume` 遇到旧 `RUNNING` checkpoint 时，必须判断是否是当前 job。若不是当前 job，不能直接沿用；应标记 `STALE_RUNNING` / `FAILED`，或者要求 `--force`。

建议 checkpoint 形态：

```json
{
  "dataset_id": "droid_lerobot_scale30",
  "version": "v1",
  "phase": "normalize",
  "status": "FAILED",
  "completed_steps": [],
  "failed_step": "materialize_input",
  "error_type": "RetriesExceededError",
  "error_message": "Max Retries Exceeded",
  "workflow_name": "robot-dh-multisource-scale30-xxxxx",
  "job_id": "etl-run-droid_lerobot_scale30-v1-...",
  "updated_at": "2026-05-25T09:45:59Z"
}
```

验收：

```bash
mc cat rdh/robot-lake/ods/droid_lerobot_scale30/v1/_checkpoint.json | jq '.status'
```

在失败时必须返回 `"FAILED"`，在成功时必须返回 `"OK"` 或等价完成态；不允许 workflow 已终止后仍是 `"RUNNING"`。

### 4.4 F4：bridge-qc enrichment 必须做硬 timeout cap

bridge-qc metric 已经正确，但 duration 仍 1096s。请对可选 enrichment 做硬上限：

1. 单次 enrichment 总耗时不超过 30s。
2. 底层 S3 read 使用标准重试和短 read timeout，不使用会长时间退避的默认配置。
3. enrichment 失败时保留当前正确 metric，最多打一条 warning。
4. warning 中外层错误和 root cause 都要准确；不要用 `IndexError tuple index out of range` 掩盖真正的 S3 timeout。

验收：

```bash
mc cat rdh/robot-lake/qc/bridgedata_v2_scale30/v1/contract_report.json | jq '.duration_sec'
```

目标 `< 30`。metric 仍需保持：

```text
traj_len_p50=108
traj_len_p95=131
episode_count=3
```

## 5. 建议测试计划

### 5.1 单元测试

| 模块 | 用例 |
|------|------|
| robomimic HDF5 | mock S3 下载到本地后用本地 `h5py.File` 打开；断言没有调用远端 `s3://` h5py |
| cause 提取 | 构造 `RetriesExceededError -> ReadTimeoutError` 链，断言日志 `cause_type=ReadTimeoutError` |
| droid partition input | 给定 partition plan，normalize 只 materialize 当前 partition 的 input_files |
| checkpoint | `materialize_input` 抛异常时，checkpoint 写 `FAILED`，包含 `failed_step` 和 error |
| bridge timeout | mock 一个永不返回的 enrichment read，断言 30s 内返回 PASS + warning |

### 5.2 WSL/kind 集成测试

建议先用小 fixture 跑通，再提交完整 `multisource-scale30`：

```bash
robot-dh qc contract run \
  --dataset-family robomimic \
  --dataset-uri s3://robot-datasets/raw/robomimic_scale30/v1 \
  --dataset-id robomimic_scale30 \
  --version v1 \
  --output s3://robot-lake/qc/robomimic_scale30/v1 \
  --contract configs/qc/robomimic_contract.yaml \
  --log-format json

robot-dh etl run \
  --dataset s3://robot-datasets/raw/droid_lerobot_scale30/v1 \
  --dataset-id droid_lerobot_scale30 \
  --version v1 \
  --lake-root s3://robot-lake \
  --phase normalize \
  --resume \
  --log-format json
```

完整 workflow 验收命令：

```bash
mc ls -r rdh/robot-dh-artifacts/argo-logs/robot-dh/robot-dh-multisource-scale30-XXXXX/
mc cat rdh/robot-lake/qc/robomimic_scale30/v1/contract_report.json | jq '{status,duration_sec,metrics}'
mc cat rdh/robot-lake/qc/bridgedata_v2_scale30/v1/contract_report.json | jq '{status,duration_sec,metrics}'
mc ls rdh/robot-lake/ods/droid_lerobot_scale30/v1/
mc cat rdh/robot-lake/ods/droid_lerobot_scale30/v1/_checkpoint.json | jq .
```

## 6. 最终验收表

| 验收项 | 命令 / 证据 | 通过标准 |
|--------|-------------|----------|
| robomimic-qc 不再失败 | `mc cat rdh/robot-lake/qc/robomimic_scale30/v1/contract_report.json` | `status=PASS`，`Last Modified` 为新 workflow 时间 |
| robomimic cause 不再自引用 | `mc ls -r .../argo-logs/... | grep robomimic` 后查看 log | 无 `cause_type=RetriesExceededError cause=Max Retries Exceeded` 自引用 |
| droid-normalize 不再 root 全量下载 | droid normalize pod log | 显示 partition id / input_files；不再显示 `files=532 total_size=12058.9 MiB` |
| droid ODS 产物落地 | `mc ls rdh/robot-lake/ods/droid_lerobot_scale30/v1/` | 至少有 `_manifest.json`、`pose.parquet`、`episode_meta.parquet`、`video_meta.parquet` |
| droid checkpoint 正确 | `mc cat .../_checkpoint.json | jq '.status'` | 成功为 `OK`；失败为 `FAILED`；不允许终态后仍 `RUNNING` |
| bridge-qc duration 收敛 | `mc cat .../bridgedata_v2_scale30/v1/contract_report.json | jq '.duration_sec'` | `< 30` |
| 完整 workflow | Argo UI / `kubectl get workflows` | `Succeeded`，进入 `build-ads` / `ml-ready-export` / `publish-lineage-report` |

## 7. 预估工作量

| 工作项 | 估时 |
|--------|------|
| robomimic HDF5 materialize-first + cause 修正 + 单测 | 0.5-1 day |
| droid normalize partition input 接线 + download progress / retry cap | 1-2 days |
| checkpoint 异常路径修复 + stale RUNNING resume 处理 | 0.5 day |
| bridge enrichment timeout cap | 0.5 day |
| WSL/kind 联调完整 `multisource-scale30` | 1 day |

建议先修 F2/F3 和 F1，再补 F4。F2/F3 与 F1 是端到端阻塞项；F4 不阻塞业务产物，但会持续拉长 workflow。

## 8. 闭环标准

收到 WSL 侧修复 PR + 一次新的 `multisource-scale30` 联调结果后，infra 侧会按同样方式从 `rdh/robot-dh-artifacts/argo-logs/robot-dh/<workflow>/` 拉取完整日志，并更新本需求与 `docs/runs/20260525/robot-dh-multisource-scale30-bxpjl/INDEX.md`。

闭环需要提供：

- 新 workflow 名称。
- robomimic / bridge / droid 三份 `contract_report.json` 的关键 metric。
- droid ODS 目录 `mc ls` 输出。
- droid `_checkpoint.json` 内容。
- `argo-logs` 中 droid-normalize 与 robomimic-qc 的 pod log 列表。
