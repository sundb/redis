#!/bin/sh
# Training workload for PGO / BOLT: starts the redis-server found in $1 (default
# ./src), drives it with redis-benchmark and redis-cli, then shuts it down
# gracefully so profile data is flushed. Used by 'make pgo' and 'make bolt'.
#
# Env: PORT (default 7999), REQUESTS (default 500000), SERVER_WRAPPER (a command
# prefix for the server, e.g. 'perf record -o x --').
set -e
DIR=$(cd "${1:-./src}" && pwd)
PORT=${PORT:-7999}
REQUESTS=${REQUESTS:-500000}
SERVER=$DIR/redis-server
CLI="$DIR/redis-cli -p $PORT"
BENCH="$DIR/redis-benchmark -p $PORT -q"
WORKDIR=$(mktemp -d)
trap 'kill $SERVER_PID 2>/dev/null || true; rm -rf "$WORKDIR"' EXIT

cd "$WORKDIR"
$SERVER_WRAPPER "$SERVER" --port $PORT --save "" --appendonly no --daemonize no \
    --enable-debug-command yes >/dev/null &
SERVER_PID=$!
i=0
until $CLI ping >/dev/null 2>&1; do
    i=$((i+1)); [ $i -gt 100 ] && { echo "server did not start"; exit 1; }
    sleep 0.1
done

# All built-in benchmark tests with several pipeline depths and value sizes.
$BENCH -n $REQUESTS -c 50 -t ping,set,get,incr,lpush,rpush,lpop,rpop,sadd,hset,spop,zadd,zpopmin,lrange,mset,xadd
$BENCH -n $REQUESTS -c 50 -P 16 -d 128 -r 100000 -t set,get,lpush,sadd,hset,zadd
$BENCH -n $REQUESTS -c 50 -P 64 -d 1024 -r 100000 -t set,get,incr
$BENCH -n 50000 -c 20 -d 16384 -r 1000 -t set,get

# Other data types / commands benchmark does not cover.
$BENCH -n 200000 -c 20 -r 100000 \
    zadd myz __rand_int__ m:__rand_int__ >/dev/null
$BENCH -n 20000 -c 20 -r 100000 zrangebyscore myz 0 100 >/dev/null
$BENCH -n 100000 -c 20 -r 100000 hget myhash element:__rand_int__ >/dev/null
$BENCH -n 100000 -c 20 -r 100000 pfadd hll __rand_int__ >/dev/null
$BENCH -n 100000 -c 20 -r 100000 append bitsk x >/dev/null
$BENCH -n 100000 -c 20 bitcount bitsk >/dev/null
$BENCH -n 100000 -c 20 -r 100000 geoadd geo 13.361389 38.115556 m:__rand_int__ >/dev/null
$BENCH -n 50000 -c 20 -r 100000 eval "return redis.call('incr',KEYS[1])" 1 luakey:__rand_int__ >/dev/null
$BENCH -n 50000 -c 20 -r 100000 expire k:__rand_int__ 100 >/dev/null

# Persistence, keyspace scans, transactions.
$CLI debug populate 200000 key 64 >/dev/null
$CLI --scan --pattern 'key:1*' >/dev/null
$CLI save >/dev/null
$CLI debug reload >/dev/null
$CLI bgrewriteaof >/dev/null
$CLI info >/dev/null
$CLI memory doctor >/dev/null
$CLI flushall >/dev/null

$CLI shutdown nosave >/dev/null 2>&1 || true
wait $SERVER_PID 2>/dev/null || true
