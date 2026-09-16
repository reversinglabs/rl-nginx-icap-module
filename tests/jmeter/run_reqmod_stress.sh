#!/bin/sh
# Runs reqmod_stress_test.jmx against an already-running nginx + detect_icap
# deployment. Requires Apache JMeter (`jmeter`) on PATH.
#
# Env vars:
#   SAMPLES_FOLDER  (required) directory of files to POST/PUT — one request
#                   per file, round-robined across threads for the duration
#                   of the run.
#   NGINX_HOST      default: localhost
#   NGINX_PORT      default: 8080
#   NGINX_PATH      default: /up
#   JMETER_THREADS    default: 10   (concurrent virtual users)
#   JMETER_RAMPUP     default: 5    (seconds to reach full thread count)
#   JMETER_DURATION   default: 60   (seconds to run once ramped up)
#   JMETER_TARGET_RPS default: 50   (total requests/sec across all threads,
#                     enforced by a PreciseThroughputTimer)
#   RESULTS_FILE      default: ./reqmod_results.csv
set -eu

: "${SAMPLES_FOLDER:?SAMPLES_FOLDER must point to a directory of files to upload}"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
JMX="$SCRIPT_DIR/reqmod_stress_test.jmx"

NGINX_HOST="${NGINX_HOST:-localhost}"
NGINX_PORT="${NGINX_PORT:-8080}"
NGINX_PATH="${NGINX_PATH:-/up}"
JMETER_THREADS="${JMETER_THREADS:-10}"
JMETER_RAMPUP="${JMETER_RAMPUP:-5}"
JMETER_DURATION="${JMETER_DURATION:-60}"
JMETER_TARGET_RPS="${JMETER_TARGET_RPS:-50}"
RESULTS_FILE="${RESULTS_FILE:-$SCRIPT_DIR/reqmod_results.csv}"

export SAMPLES_FOLDER NGINX_HOST NGINX_PORT NGINX_PATH \
       JMETER_THREADS JMETER_RAMPUP JMETER_DURATION JMETER_TARGET_RPS RESULTS_FILE

rm -f "$RESULTS_FILE"

echo "== REQMOD stress test =="
echo "  files:    $SAMPLES_FOLDER"
echo "  target:   http://$NGINX_HOST:$NGINX_PORT$NGINX_PATH"
echo "  threads:  $JMETER_THREADS (ramp-up ${JMETER_RAMPUP}s)"
echo "  duration: ${JMETER_DURATION}s"
echo "  rate:     ${JMETER_TARGET_RPS} req/s (PreciseThroughputTimer)"
echo "  results:  $RESULTS_FILE"
echo

jmeter -n -t "$JMX"

echo
echo "== results written to $RESULTS_FILE =="