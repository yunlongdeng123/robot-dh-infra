"""生成 bridgedata_v2_scale30 的小样本 parquet，给主项目 normalize adapter 回归测试用。

策略：
- 保留**完整 schema**（嵌套 action.pose / action.grasp / state.end_effector_pose 等），保证主项目修复 adapter 时面对的列结构与生产一致
- 把 image / observation.image 这两列的 binary `bytes` 字段置空（保留 path），将文件从 227 MiB 压到约 200 KiB
- 只抽前 30 行，覆盖 2 个 episode（episode_idx in {0, 1}），足够触发 adapter 的多 episode 分组逻辑
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.parquet as pq

SRC = Path(
    "/data/robot-dh/datasets/raw/scale30/bridgedata_v2_scale30/v1/data/shard_0-00000-of-00001.parquet"
)
OUT_DIR = Path(__file__).resolve().parent.parent / "docs" / "samples" / "bridgedata_v2_scale30"
OUT_PARQUET = OUT_DIR / "shard_0-sample.parquet"
OUT_SCHEMA_TXT = OUT_DIR / "schema.txt"
OUT_SCHEMA_JSON = OUT_DIR / "schema.json"
OUT_MANIFEST = OUT_DIR / "_manifest.json"


def _null_image_bytes(table: pa.Table) -> pa.Table:
    """把 image.bytes / observation.image.bytes 置 null，保留 schema 形状。"""

    def _null_bytes_in_image_struct(arr: pa.Array) -> pa.Array:
        # image 列：struct<bytes: binary, path: string>
        path_field = arr.field("path")
        n = len(arr)
        null_bytes = pa.array([None] * n, type=pa.binary())
        return pa.StructArray.from_arrays(
            [null_bytes, path_field],
            fields=[
                pa.field("bytes", pa.binary()),
                pa.field("path", pa.string()),
            ],
        )

    cols = {}
    for name in table.column_names:
        arr = table.column(name).combine_chunks()
        if name == "image":
            cols[name] = _null_bytes_in_image_struct(arr)
            continue
        if name == "observation":
            # observation: struct<image: struct<bytes,path>, task: string>
            inner_image = arr.field("image")
            task = arr.field("task")
            new_image = _null_bytes_in_image_struct(inner_image)
            cols[name] = pa.StructArray.from_arrays(
                [new_image, task],
                fields=[
                    pa.field("image", new_image.type),
                    pa.field("task", pa.string()),
                ],
            )
            continue
        cols[name] = arr
    return pa.Table.from_arrays(list(cols.values()), names=list(cols.keys()))


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    table = pq.read_table(SRC)
    # 跨 episode 各抽 N 行，保证 adapter 多 episode 分组逻辑被覆盖
    per_ep = 20
    parts = []
    for ep in (0, 1):
        ep_mask = pc.equal(table.column("episode_idx"), pa.scalar(ep, type=pa.int64()))
        parts.append(table.filter(ep_mask).slice(0, per_ep))
    sampled = pa.concat_tables(parts)

    sampled = _null_image_bytes(sampled)

    pq.write_table(sampled, OUT_PARQUET, compression="snappy")

    # dump schema
    schema_str = table.schema.to_string(show_field_metadata=False)
    OUT_SCHEMA_TXT.write_text(schema_str + "\n", encoding="utf-8")

    schema_obj = json.loads(table.schema.metadata.get(b"huggingface", b"{}").decode("utf-8"))
    OUT_SCHEMA_JSON.write_text(
        json.dumps(schema_obj, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    # 生成 sample 自己的 manifest
    sample_bytes = OUT_PARQUET.read_bytes()
    digest = hashlib.sha256(sample_bytes).hexdigest()
    manifest = {
        "dataset_id": "bridgedata_v2_scale30",
        "version": "v1",
        "layer": "raw-sample",
        "source_repo": "mbodiai/oxe_bridge_v2",
        "source_uri": "s3://robot-datasets/raw/bridgedata_v2_scale30/v1/data/shard_0-00000-of-00001.parquet",
        "sample_strategy": "first 20 rows of each episode_idx in {0, 1}, image bytes nulled",
        "sample": {
            "path": "shard_0-sample.parquet",
            "rows": sampled.num_rows,
            "episodes": sorted(set(sampled.column("episode_idx").to_pylist())),
            "size_bytes": len(sample_bytes),
            "sha256": digest,
        },
        "full_source": {
            "rows": table.num_rows,
            "episodes": sorted(set(table.column("episode_idx").to_pylist())),
            "size_mib": SRC.stat().st_size / (1024 * 1024),
        },
    }
    OUT_MANIFEST.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    print("wrote:")
    print(f"  {OUT_PARQUET} ({len(sample_bytes)} bytes, {sampled.num_rows} rows)")
    print(f"  {OUT_SCHEMA_TXT}")
    print(f"  {OUT_SCHEMA_JSON}")
    print(f"  {OUT_MANIFEST}")


if __name__ == "__main__":
    main()
