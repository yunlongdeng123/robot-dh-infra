#!/usr/bin/env bash
set -euo pipefail

RAW_ROOT="/data/robot-dh/datasets/raw"
OUT_DIR="/data/robot-dh/datasets/manifests/quality"
CONDA_ENV_NAME="${CONDA_ENV_NAME:-robot-dh}"
CONDA_ROOT="${CONDA_ROOT:-$HOME/miniconda3}"
ONLY=""

usage() {
  cat <<EOF >&2
Usage: $0 [--only DATASET]

Datasets for --only:
  droid
  bridgedata-v2
  robomimic
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)
      shift
      if [[ $# -eq 0 ]]; then
        usage
        exit 1
      fi
      ONLY="$1"
      case "$ONLY" in
        droid|bridgedata-v2|robomimic)
          ;;
        *)
          usage
          exit 1
          ;;
      esac
      ;;
    *)
      usage
      exit 1
      ;;
  esac
  shift
done

if [[ ! -d "$RAW_ROOT" ]]; then
  echo "ERROR: $RAW_ROOT not found. Run dataset pull scripts first." >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

PYTHON_RUNNER=()

resolve_python_runner() {
  if [[ -n "${CONDA_PREFIX:-}" && -x "$CONDA_PREFIX/bin/python" ]]; then
    PYTHON_RUNNER=("$CONDA_PREFIX/bin/python")
    return 0
  fi

  if [[ -x "$CONDA_ROOT/bin/conda" ]]; then
    if "$CONDA_ROOT/bin/conda" env list | awk '{print $1}' | grep -Fxq "$CONDA_ENV_NAME"; then
      PYTHON_RUNNER=("$CONDA_ROOT/bin/conda" run --no-capture-output -n "$CONDA_ENV_NAME" python)
      return 0
    fi
  fi

  if command -v python3 >/dev/null 2>&1; then
    PYTHON_RUNNER=(python3)
    return 0
  fi

  echo "ERROR: Could not find a usable Python runtime." >&2
  return 1
}

resolve_python_runner

"${PYTHON_RUNNER[@]}" - "$RAW_ROOT" "$OUT_DIR" "$ONLY" <<'PY'
from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


try:
    import h5py
    import pyarrow as pa
    import pyarrow.compute as pc
    import pyarrow.parquet as pq
except ImportError as exc:
    fail(
        "Missing Python dependency: "
        f"{exc}. Activate the robot-dh conda env or rerun ./scripts/16_setup_conda_env.sh."
    )


RAW_ROOT = Path(sys.argv[1])
OUT_DIR = Path(sys.argv[2])
ONLY = sys.argv[3]
JSON_PATH = OUT_DIR / "curated_samples_quality_report.json"
MD_PATH = OUT_DIR / "curated_samples_quality_report.md"
CALIBRATION_KEYWORDS = (
    "calib",
    "intrinsic",
    "extrinsic",
    "distortion",
    "projection",
    "camera_matrix",
    "camera_extrinsics",
    "camera_intrinsics",
)

DATASETS = {
    "droid": {
        "slug": "droid",
        "title": "DROID LeRobot Sample",
        "kind": "parquet",
        "root": RAW_ROOT / "droid" / "lerobot_sample",
        "calibration_expected": True,
        "calibration_dir": RAW_ROOT / "droid" / "calibration",
        "globs": ("**/*.parquet",),
    },
    "bridgedata-v2": {
        "slug": "bridgedata-v2",
        "title": "BridgeData V2 Sample",
        "kind": "parquet",
        "root": RAW_ROOT / "bridgedata_v2" / "sample",
        "calibration_expected": False,
        "globs": ("**/*.parquet",),
    },
    "robomimic": {
        "slug": "robomimic",
        "title": "robomimic Sample",
        "kind": "hdf5",
        "root": RAW_ROOT / "robomimic" / "sample",
        "calibration_expected": False,
        "globs": ("**/*.hdf5", "**/*.h5"),
    },
}


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def relative_path(path: Path, root: Path) -> str:
    return str(path.relative_to(root))


def size_bytes(path: Path) -> int:
    return int(path.stat().st_size)


def format_bytes(value: int) -> str:
    units = ["B", "KB", "MB", "GB", "TB"]
    number = float(value)
    for unit in units:
        if number < 1024.0 or unit == units[-1]:
            return f"{number:.2f} {unit}"
        number /= 1024.0
    return f"{value} B"


def is_calibration_name(name: str) -> bool:
    lowered = name.lower()
    return any(keyword in lowered for keyword in CALIBRATION_KEYWORDS)


def scalar_to_json(value):
    if value is None:
        return None
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    if isinstance(value, Path):
        return str(value)
    if hasattr(value, "isoformat"):
        try:
            return value.isoformat()
        except TypeError:
            return str(value)
    if isinstance(value, (list, tuple)):
        return [scalar_to_json(item) for item in value]
    if isinstance(value, dict):
        return {str(key): scalar_to_json(item) for key, item in value.items()}
    if isinstance(value, (str, int, float, bool)):
        return value
    return str(value)


def first_non_null_preview(array) -> str | None:
    chunks = array.chunks if hasattr(array, "chunks") else [array]
    for chunk in chunks:
        if len(chunk) == 0 or chunk.null_count == len(chunk):
            continue
        values = chunk.drop_null().slice(0, 1).to_pylist()
        if values:
            text = json.dumps(scalar_to_json(values[0]), ensure_ascii=False)
            if len(text) > 160:
                return text[:157] + "..."
            return text
    return None


def flatten_leaf_table(table):
    flattened = table
    while any(pa.types.is_struct(field.type) for field in flattened.schema):
        flattened = flattened.flatten()
    return flattened


def parquet_column_profile(field: pa.Field, array) -> dict:
    total_rows = len(array)
    null_count = int(array.null_count)
    non_null_count = total_rows - null_count
    profile = {
        "name": field.name,
        "type": str(field.type),
        "nullable": bool(field.nullable),
        "null_count": null_count,
        "non_null_count": non_null_count,
        "non_null_ratio": round(non_null_count / total_rows, 6) if total_rows else 0.0,
    }

    if non_null_count:
        preview = first_non_null_preview(array)
        if preview is not None:
            profile["sample_value"] = preview

    if pa.types.is_integer(field.type) or pa.types.is_floating(field.type) or pa.types.is_decimal(field.type):
        try:
            profile["min"] = scalar_to_json(pc.min(array).as_py())
            profile["max"] = scalar_to_json(pc.max(array).as_py())
        except (NotImplementedError, ValueError, TypeError, AttributeError):
            pass

    return profile


def collect_parquet_dataset(config: dict) -> dict:
    root = config["root"]
    if not root.exists():
        raise FileNotFoundError(f"Missing dataset root: {root}")

    parquet_files = []
    for pattern in config["globs"]:
        parquet_files.extend(sorted(root.glob(pattern)))

    if not parquet_files:
        raise FileNotFoundError(f"No parquet files found under {root}")

    file_reports = []
    schema_union: dict[str, set[str]] = {}
    calibration_fields = []
    total_rows = 0
    total_size = 0

    for path in sorted(set(parquet_files)):
        table = pq.read_table(path)
        leaf_table = flatten_leaf_table(table)
        schema = leaf_table.schema
        columns = []
        for index, field in enumerate(schema):
            column_profile = parquet_column_profile(field, leaf_table.column(index))
            columns.append(column_profile)
            schema_union.setdefault(field.name, set()).add(str(field.type))
            if is_calibration_name(field.name):
                calibration_fields.append(
                    {
                        "source_file": relative_path(path, root),
                        "field": field.name,
                        "type": str(field.type),
                        "null_count": column_profile["null_count"],
                        "non_null_ratio": column_profile["non_null_ratio"],
                        "sample_value": column_profile.get("sample_value"),
                    }
                )

        size = size_bytes(path)
        total_rows += int(table.num_rows)
        total_size += size
        file_reports.append(
            {
                "path": relative_path(path, root),
                "size_bytes": size,
                "num_rows": int(table.num_rows),
                "num_columns": len(schema),
                "schema": [
                    {"name": field.name, "type": str(field.type), "nullable": bool(field.nullable)}
                    for field in schema
                ],
                "profile": {"columns": columns},
            }
        )

    calibration_dir = config.get("calibration_dir")
    artifact_payloads = []
    observed_calibration_files = []
    if calibration_dir is not None and calibration_dir.exists():
        observed_calibration_files = [
            {
                "path": relative_path(path, calibration_dir),
                "size_bytes": size_bytes(path),
            }
            for path in sorted(calibration_dir.rglob("*"))
            if path.is_file()
        ]
        observed_calibration_files = [
            item
            for item in observed_calibration_files
            if not item["path"].startswith(".cache/") and item["path"] != ".cache"
        ]
        artifact_payloads = [
            item for item in observed_calibration_files if item["path"].endswith((".json", ".jsonl"))
        ]

    calibration_status = "not_detected"
    if config["calibration_expected"]:
        if artifact_payloads and calibration_fields:
            calibration_status = "complete"
        elif artifact_payloads or calibration_fields:
            calibration_status = "partial"
        else:
            calibration_status = "missing"
    elif artifact_payloads or calibration_fields:
        calibration_status = "detected"

    return {
        "slug": config["slug"],
        "title": config["title"],
        "kind": config["kind"],
        "root": str(root),
        "files": file_reports,
        "schema": {
            "field_union": [
                {"name": name, "types": sorted(types)}
                for name, types in sorted(schema_union.items())
            ]
        },
        "profile": {
            "file_count": len(file_reports),
            "total_size_bytes": total_size,
            "total_rows_across_parquet_files": total_rows,
        },
        "calibration_completeness": {
            "expected": config["calibration_expected"],
            "status": calibration_status,
            "artifact_payload_count": len(artifact_payloads),
            "artifact_payloads": artifact_payloads,
            "observed_calibration_dir_files": observed_calibration_files,
            "embedded_field_count": len(calibration_fields),
            "embedded_fields": calibration_fields,
        },
    }


def collect_hdf5_dataset(config: dict) -> dict:
    root = config["root"]
    if not root.exists():
        raise FileNotFoundError(f"Missing dataset root: {root}")

    hdf5_files = []
    for pattern in config["globs"]:
        hdf5_files.extend(sorted(root.glob(pattern)))

    if not hdf5_files:
        raise FileNotFoundError(f"No HDF5 files found under {root}")

    file_reports = []
    schema_union = []
    calibration_hits = []
    total_size = 0
    total_group_count = 0
    total_dataset_count = 0

    for path in sorted(set(hdf5_files)):
        size = size_bytes(path)
        total_size += size
        with h5py.File(path, "r") as handle:
            groups = [{"path": "/", "attrs": sorted(str(key) for key in handle.attrs.keys())}]
            datasets = []
            top_level_keys = sorted(str(key) for key in handle.keys())

            def visit(name, obj):
                normalized = "/" + name if name else "/"
                attrs = sorted(str(key) for key in obj.attrs.keys())
                if isinstance(obj, h5py.Group):
                    groups.append({"path": normalized, "attrs": attrs})
                elif isinstance(obj, h5py.Dataset):
                    dataset_info = {
                        "path": normalized,
                        "shape": [int(dimension) for dimension in obj.shape],
                        "dtype": str(obj.dtype),
                        "attrs": attrs,
                    }
                    datasets.append(dataset_info)
                    schema_union.append(dataset_info)

                searchable = [normalized, *attrs]
                if any(is_calibration_name(value) for value in searchable):
                    calibration_hits.append(
                        {
                            "source_file": relative_path(path, root),
                            "path": normalized,
                            "attrs": attrs,
                        }
                    )

            handle.visititems(visit)

        total_group_count += len(groups)
        total_dataset_count += len(datasets)
        file_reports.append(
            {
                "path": relative_path(path, root),
                "size_bytes": size,
                "top_level_keys": top_level_keys,
                "group_count": len(groups),
                "dataset_count": len(datasets),
                "schema": {
                    "groups": groups,
                    "datasets": datasets,
                },
            }
        )

    calibration_status = "detected" if calibration_hits else "not_detected"

    return {
        "slug": config["slug"],
        "title": config["title"],
        "kind": config["kind"],
        "root": str(root),
        "files": file_reports,
        "schema": {"datasets": schema_union},
        "profile": {
            "file_count": len(file_reports),
            "total_size_bytes": total_size,
            "total_group_count": total_group_count,
            "total_dataset_count": total_dataset_count,
        },
        "calibration_completeness": {
            "expected": config["calibration_expected"],
            "status": calibration_status,
            "embedded_field_count": len(calibration_hits),
            "embedded_fields": calibration_hits,
        },
    }


def collect_dataset(config: dict) -> dict:
    if config["kind"] == "parquet":
        return collect_parquet_dataset(config)
    if config["kind"] == "hdf5":
        return collect_hdf5_dataset(config)
    raise ValueError(f"Unsupported dataset kind: {config['kind']}")


def render_markdown(report: dict) -> str:
    lines = [
        "# Curated Sample Quality Report",
        "",
        f"Generated at: {report['generated_at']}",
        f"Raw root: `{report['raw_root']}`",
        f"JSON report: `{report['json_report']}`",
        "",
    ]

    for dataset in report["datasets"]:
        lines.extend(
            [
                f"## {dataset['title']}",
                "",
                f"- Slug: `{dataset['slug']}`",
                f"- Kind: `{dataset['kind']}`",
                f"- Root: `{dataset['root']}`",
                f"- File count: `{dataset['profile']['file_count']}`",
                f"- Total size: `{format_bytes(dataset['profile']['total_size_bytes'])}`",
            ]
        )

        if dataset["kind"] == "parquet":
            lines.append(
                f"- Total rows across parquet files: `{dataset['profile']['total_rows_across_parquet_files']}`"
            )
            lines.extend(["", "### Schema / Profile", "", "| File | Rows | Columns | Size |", "| --- | ---: | ---: | ---: |"])
            for file_report in dataset["files"]:
                lines.append(
                    "| "
                    f"{file_report['path']} | {file_report['num_rows']} | {file_report['num_columns']} | {format_bytes(file_report['size_bytes'])} |"
                )

            lines.extend(["", "Field union:", ""])
            for field in dataset["schema"]["field_union"]:
                joined_types = ", ".join(field["types"])
                lines.append(f"- `{field['name']}`: `{joined_types}`")
        else:
            lines.append(f"- Total groups: `{dataset['profile']['total_group_count']}`")
            lines.append(f"- Total datasets: `{dataset['profile']['total_dataset_count']}`")
            lines.extend(["", "### Schema / Profile", "", "| File | Groups | Datasets | Size |", "| --- | ---: | ---: | ---: |"])
            for file_report in dataset["files"]:
                lines.append(
                    "| "
                    f"{file_report['path']} | {file_report['group_count']} | {file_report['dataset_count']} | {format_bytes(file_report['size_bytes'])} |"
                )

            lines.extend(["", "Top-level keys:", ""])
            for file_report in dataset["files"]:
                keys = ", ".join(file_report["top_level_keys"]) if file_report["top_level_keys"] else "<none>"
                lines.append(f"- `{file_report['path']}`: {keys}")

        calibration = dataset["calibration_completeness"]
        lines.extend(
            [
                "",
                "### Calibration Completeness",
                "",
                f"- Expected calibration payloads: `{calibration['expected']}`",
                f"- Status: `{calibration['status']}`",
            ]
        )

        if dataset["kind"] == "parquet":
            lines.append(f"- Artifact payload count: `{calibration['artifact_payload_count']}`")
            if calibration["artifact_payloads"]:
                lines.append("- Artifact payloads:")
                for item in calibration["artifact_payloads"]:
                    lines.append(f"  - `{item['path']}` ({format_bytes(item['size_bytes'])})")
            elif calibration.get("observed_calibration_dir_files"):
                lines.append("- Observed calibration dir files:")
                for item in calibration["observed_calibration_dir_files"]:
                    lines.append(f"  - `{item['path']}` ({format_bytes(item['size_bytes'])})")

        lines.append(f"- Embedded calibration field count: `{calibration['embedded_field_count']}`")
        embedded_fields = calibration["embedded_fields"]
        if embedded_fields:
            lines.extend(["", "| Source | Field / Path | Coverage |", "| --- | --- | ---: |"])
            for item in embedded_fields:
                coverage = item.get("non_null_ratio")
                if coverage is None:
                    coverage_text = "present"
                    field_name = item["path"]
                else:
                    coverage_text = f"{coverage:.6f}"
                    field_name = item["field"]
                lines.append(f"| {item['source_file']} | {field_name} | {coverage_text} |")

        lines.append("")

    return "\n".join(lines)


selected = [ONLY] if ONLY else list(DATASETS.keys())
datasets = [collect_dataset(DATASETS[name]) for name in selected]
report = {
    "generated_at": now_iso(),
    "raw_root": str(RAW_ROOT),
    "json_report": str(JSON_PATH),
    "markdown_report": str(MD_PATH),
    "datasets": datasets,
}

OUT_DIR.mkdir(parents=True, exist_ok=True)
JSON_PATH.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
MD_PATH.write_text(render_markdown(report), encoding="utf-8")

print(f"Wrote JSON report: {JSON_PATH}")
print(f"Wrote Markdown report: {MD_PATH}")
for dataset in datasets:
    calibration = dataset["calibration_completeness"]
    print(
        f"[{dataset['slug']}] kind={dataset['kind']} files={dataset['profile']['file_count']} "
        f"calibration_status={calibration['status']} embedded_fields={calibration['embedded_field_count']}"
    )
PY
