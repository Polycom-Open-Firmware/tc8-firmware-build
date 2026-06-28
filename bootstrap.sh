#!/usr/bin/env bash
# bootstrap.sh — fetch all build inputs (submodules + vanilla linux-6.6).
# Idempotent: safe to re-run.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT"

LINUX_DIR="${REPO_ROOT}/linux-6.6"
LINUX_TAG="v6.6"
LINUX_URL="${LINUX_URL:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git}"

echo "===> [1/2] init submodules (kernel-patches, rootfs)"
git submodule update --init --recursive

if [[ -d "$LINUX_DIR/.git" || -f "$LINUX_DIR/Makefile" ]]; then
    echo "===> [2/2] linux-6.6/ already present — skipping clone"
else
    echo "===> [2/2] shallow-cloning ${LINUX_TAG} from ${LINUX_URL}"
    git clone --branch "$LINUX_TAG" --depth 1 "$LINUX_URL" "$LINUX_DIR"
fi

cat <<EOF

[OK] bootstrap complete.

Next:
    ./build.sh --profile=emmc
EOF
