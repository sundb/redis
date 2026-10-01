#!/bin/sh
# Optimize a redis-server binary in place with LLVM BOLT. The binary must have
# been linked with -Wl,--emit-relocs (see 'make bolt'). The original is kept as
# <binary>.pre-bolt. Requires: perf, perf2bolt, llvm-bolt.
set -e
BIN=${1:-./redis-server}
for t in perf perf2bolt llvm-bolt; do
    command -v $t >/dev/null || { echo "bolt: '$t' not found in PATH"; exit 1; }
done
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
DIR=$(dirname "$BIN")

# Prefer LBR (branch stack) sampling; fall back to plain cycles sampling
# (e.g. in VMs), which perf2bolt handles with -nl.
if perf record -e cycles:u -j any,u -o "$TMP/perf.data" -- true >/dev/null 2>&1; then
    PERF_ARGS="-e cycles:u -j any,u"; P2B_ARGS=""
else
    echo "bolt: LBR not available, falling back to non-LBR sampling"
    PERF_ARGS="-e cycles:u"; P2B_ARGS="-nl"
fi

SERVER_WRAPPER="perf record $PERF_ARGS -o $TMP/perf.data --" "$(dirname "$0")/pgo-train.sh" "$DIR"
perf2bolt $P2B_ARGS -p "$TMP/perf.data" -o "$TMP/redis.fdata" "$BIN"
cp "$BIN" "$BIN.pre-bolt"
llvm-bolt "$BIN.pre-bolt" -o "$BIN" -data="$TMP/redis.fdata" \
    -reorder-blocks=ext-tsp -reorder-functions=hfsort -split-functions \
    -split-all-cold -split-eh -dyno-stats
echo "bolt: optimized $BIN (original saved as $BIN.pre-bolt)"
