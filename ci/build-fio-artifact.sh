#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
cd "$ROOT"

TARGET=${1:?usage: build-fio-artifact.sh <target>}
VERSION=3.43
SOURCE_TAG=fio-3.43
SOURCE_COMMIT=d2dcd7e053d1902d2420f151c83990e6acdd9f8c
SOURCE_URL=https://github.com/axboe/fio.git

case "$TARGET" in
    aarch64-apple-darwin)
        EXPECTED_ARCH=arm64
        REQUIRED_ENGINE=posixaio
        ;;
    aarch64-unknown-linux-gnu)
        EXPECTED_ARCH=aarch64
        REQUIRED_ENGINE=libaio
        ;;
    *)
        printf 'Unsupported target: %s\n' "$TARGET" >&2
        exit 2
        ;;
esac

ACTUAL_ARCH=$(uname -m)
if [ "$ACTUAL_ARCH" != "$EXPECTED_ARCH" ]; then
    printf 'Target %s requires a native %s runner, got %s\n' "$TARGET" "$EXPECTED_ARCH" "$ACTUAL_ARCH" >&2
    exit 1
fi

# Confirm the upstream release tag still names the reviewed source commit.
git fetch --no-tags "$SOURCE_URL" "refs/tags/$SOURCE_TAG:refs/tags/$SOURCE_TAG"
FETCHED_COMMIT=$(git rev-parse "$SOURCE_TAG^{commit}")
if [ "$FETCHED_COMMIT" != "$SOURCE_COMMIT" ]; then
    printf 'Upstream tag %s moved: expected %s, got %s\n' "$SOURCE_TAG" "$SOURCE_COMMIT" "$FETCHED_COMMIT" >&2
    exit 1
fi
if ! git merge-base --is-ancestor "$SOURCE_COMMIT" HEAD; then
    printf 'Build checkout is not based on %s (%s)\n' "$SOURCE_TAG" "$SOURCE_COMMIT" >&2
    exit 1
fi
if ! git diff --quiet "$SOURCE_COMMIT" -- . \
    ':(exclude).github/workflows/build-binaries.yml' \
    ':(exclude).github/workflows/ci.yml' \
    ':(exclude).github/workflows/cifuzz.yml' \
    ':(exclude).github/workflows/qemu.yml' \
    ':(exclude)ci/build-fio-artifact.sh'; then
    printf 'Unexpected fio source changes exist outside the artifact workflow and builder\n' >&2
    exit 1
fi

VERSION_FILE_CREATED=false
if [ -e version ]; then
    if [ "$(cat version)" != "fio-$VERSION" ]; then
        printf 'Refusing to replace an existing version file\n' >&2
        exit 1
    fi
else
    printf 'fio-%s\n' "$VERSION" > version
    VERSION_FILE_CREATED=true
fi

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/fio-artifact.XXXXXX")
cleanup() {
    if [ "$VERSION_FILE_CREATED" = true ]; then
        rm -f "$ROOT/version"
    fi
    rm -rf "$STAGE"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

AUDIT_DIR=$STAGE/audit
mkdir -p "$AUDIT_DIR"
printf '%s\n' \
    --disable-native \
    --disable-numa \
    --disable-rdma \
    --disable-rados \
    --disable-rbd \
    --disable-http \
    --disable-gfapi \
    --disable-libnfs \
    --disable-lex \
    --disable-pmem \
    --disable-xnvme \
    --disable-isal \
    --disable-isal64 \
    --disable-libblkio \
    --disable-libzbc \
    --disable-tcmalloc \
    --disable-dfs > "$AUDIT_DIR/configure-args.txt"

if ! ./configure \
    --disable-native \
    --disable-numa \
    --disable-rdma \
    --disable-rados \
    --disable-rbd \
    --disable-http \
    --disable-gfapi \
    --disable-libnfs \
    --disable-lex \
    --disable-pmem \
    --disable-xnvme \
    --disable-isal \
    --disable-isal64 \
    --disable-libblkio \
    --disable-libzbc \
    --disable-tcmalloc \
    --disable-dfs > "$AUDIT_DIR/configure.log" 2>&1; then
    cat "$AUDIT_DIR/configure.log" >&2
    exit 1
fi

case "$TARGET" in
    aarch64-apple-darwin)
        JOBS=$(sysctl -n hw.logicalcpu)
        ;;
    aarch64-unknown-linux-gnu)
        JOBS=$(getconf _NPROCESSORS_ONLN)
        ;;
esac
if ! make -j "$JOBS" > "$AUDIT_DIR/build.log" 2>&1; then
    cat "$AUDIT_DIR/build.log" >&2
    exit 1
fi

./fio --version > "$AUDIT_DIR/version.txt"
if [ "$(cat "$AUDIT_DIR/version.txt")" != "fio-$VERSION" ]; then
    printf 'Expected fio-%s, got %s\n' "$VERSION" "$(cat "$AUDIT_DIR/version.txt")" >&2
    exit 1
fi
./fio --enghelp > "$AUDIT_DIR/engines.txt" 2>&1
python3 - "$AUDIT_DIR/engines.txt" "$REQUIRED_ENGINE" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
for engine in ("psync", sys.argv[2]):
    if not re.search(rf"(?<![A-Za-z0-9_-]){re.escape(engine)}(?![A-Za-z0-9_-])", text):
        raise SystemExit(f"required fio engine missing: {engine}")
PY

file ./fio > "$AUDIT_DIR/binary-file.txt"
case "$TARGET" in
    aarch64-apple-darwin)
        lipo -archs ./fio > "$AUDIT_DIR/architectures.txt"
        if [ "$(cat "$AUDIT_DIR/architectures.txt")" != arm64 ]; then
            printf 'Expected an arm64-only macOS executable\n' >&2
            exit 1
        fi
        otool -L ./fio > "$AUDIT_DIR/dependencies.txt"
        python3 - "$AUDIT_DIR/dependencies.txt" <<'PY'
import json
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
dependencies = re.findall(r"^\s+(\S+) \(compatibility version", text, re.MULTILINE)
if not dependencies:
    raise SystemExit("otool reported no dynamic dependencies")
for path in dependencies:
    if not path.startswith(("/usr/lib/", "/System/Library/")):
        raise SystemExit(f"non-system macOS dependency: {path}")
Path(sys.argv[1]).with_name("dependency-audit.json").write_text(
    json.dumps({"platform": "macos", "dependencies": dependencies}, indent=2) + "\n"
)
PY
        ;;
    aarch64-unknown-linux-gnu)
        readelf -h ./fio > "$AUDIT_DIR/elf-header.txt"
        grep -q 'Class:.*ELF64' "$AUDIT_DIR/elf-header.txt"
        grep -q 'Machine:.*AArch64' "$AUDIT_DIR/elf-header.txt"
        ldd ./fio > "$AUDIT_DIR/dependencies.txt"
        getconf GNU_LIBC_VERSION > "$AUDIT_DIR/glibc-version.txt"
        readelf --version-info ./fio > "$AUDIT_DIR/glibc-symbol-versions.txt"
        python3 - "$AUDIT_DIR/dependencies.txt" "$AUDIT_DIR/glibc-version.txt" "$AUDIT_DIR/glibc-symbol-versions.txt" <<'PY'
import json
import re
import sys
from pathlib import Path

ldd_path, glibc_path, versions_path = map(Path, sys.argv[1:])
text = ldd_path.read_text()
if "not found" in text:
    raise SystemExit("ldd found an unresolved shared library")
dependencies = []
for line in text.splitlines():
    if "=>" in line:
        path = line.split("=>", 1)[1].strip().split()[0]
        if path == "not":
            raise SystemExit(f"unresolved dependency: {line}")
        dependencies.append(path)
    else:
        match = re.match(r"\s*(/\S+)\s+\(", line)
        if match:
            dependencies.append(match.group(1))
if not dependencies:
    raise SystemExit("ldd reported no dynamic dependencies")
for path in dependencies:
    if not path.startswith(("/lib/", "/usr/lib/")):
        raise SystemExit(f"dependency is outside the system library directories: {path}")

baseline_match = re.search(r"glibc\s+(\d+(?:\.\d+)+)", glibc_path.read_text())
if not baseline_match:
    raise SystemExit("could not read the runner's glibc baseline")
baseline = tuple(map(int, baseline_match.group(1).split(".")))
versions = re.findall(r"GLIBC_(\d+(?:\.\d+)+)", versions_path.read_text())
if not versions:
    raise SystemExit("could not read the executable's required GLIBC versions")
required = max(tuple(map(int, version.split("."))) for version in versions)
if required > baseline:
    raise SystemExit(f"binary requires GLIBC_{'.'.join(map(str, required))}, runner has {baseline_match.group(1)}")

Path(sys.argv[1]).with_name("dependency-audit.json").write_text(
    json.dumps(
        {
            "platform": "linux",
            "system_dependencies": dependencies,
            "glibc_baseline": baseline_match.group(1),
            "maximum_required_glibc": ".".join(map(str, required)),
        },
        indent=2,
    )
    + "\n"
)
PY
        ;;
esac

cp ./fio "$STAGE/fio"
cp COPYING MORAL-LICENSE "$STAGE/"

OUTPUT_DIR=${OUTPUT_DIR:-"$ROOT/dist"}
mkdir -p "$OUTPUT_DIR"
BUILD_COMMIT=$(git rev-parse HEAD)
RUNNER_OS=${RUNNER_OS:-$(uname -s)}
RUNNER_ARCH=${RUNNER_ARCH:-$ACTUAL_ARCH}
CC_VERSION=$(cc --version | head -n 1)
python3 - "$STAGE" "$OUTPUT_DIR" "$TARGET" "$VERSION" "$SOURCE_URL" "$SOURCE_TAG" "$SOURCE_COMMIT" "$BUILD_COMMIT" "$ACTUAL_ARCH" "$REQUIRED_ENGINE" "$RUNNER_OS" "$RUNNER_ARCH" "$CC_VERSION" <<'PY'
import hashlib
import json
import sys
import tarfile
from pathlib import Path

stage, output, target, version, source_url, source_tag, source_commit, build_commit, architecture, required_engine, runner_os, runner_arch, compiler = sys.argv[1:]
stage = Path(stage)
output = Path(output)
sha256 = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
manifest = {
    "schema_version": 1,
    "tool": {
        "name": "fio",
        "version": version,
        "executable": "fio",
        "sha256": sha256(stage / "fio"),
    },
    "source": {
        "repository": source_url,
        "tag": source_tag,
        "commit": source_commit,
    },
    "build": {
        "commit": build_commit,
        "target": target,
        "architecture": architecture,
        "runner_os": runner_os,
        "runner_architecture": runner_arch,
        "compiler": compiler,
        "required_io_engines": ["psync", required_engine],
        "configure_args": (stage / "audit" / "configure-args.txt").read_text().splitlines(),
    },
    "license": {
        "spdx": "GPL-2.0-only",
        "files": {
            "COPYING": sha256(stage / "COPYING"),
            "MORAL-LICENSE": sha256(stage / "MORAL-LICENSE"),
        },
    },
    "audit": {
        "dependency_report": "audit/dependency-audit.json",
        "binary_report": "audit/binary-file.txt",
        "engine_report": "audit/engines.txt",
    },
}
(stage / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
archive_name = f"fio-{target}.tar.gz"
archive_path = output / archive_name
with tarfile.open(archive_path, "w:gz") as archive:
    for path in sorted(stage.rglob("*")):
        archive.add(path, arcname=path.relative_to(stage).as_posix(), recursive=False)
archive_hash = sha256(archive_path)
(output / f"{archive_name}.sha256").write_text(f"{archive_hash}  {archive_name}\n")
print(f"{archive_hash}  {archive_name}")
PY
