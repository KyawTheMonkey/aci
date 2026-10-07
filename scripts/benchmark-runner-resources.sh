#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIRECTORY:h}
RUNNER_PACKAGE="${REPOSITORY_ROOT}/apps/runner"
FIXTURE="${RUNNER_PACKAGE}/Fixtures/Jobs/success.json"
TEMPORARY_BASE=${TMPDIR:-/tmp}

ITERATIONS=${ACI_PERF_ITERATIONS:-15}
MAX_BINARY_BYTES=${ACI_PERF_MAX_BINARY_BYTES:-8388608}
MAX_COLD_SECONDS=${ACI_PERF_MAX_COLD_SECONDS:-2.00}
MAX_WARM_P50_SECONDS=${ACI_PERF_MAX_WARM_P50_SECONDS:-0.05}
MAX_WARM_P95_SECONDS=${ACI_PERF_MAX_WARM_P95_SECONDS:-0.15}
MAX_RSS_BYTES=${ACI_PERF_MAX_RSS_BYTES:-33554432}
OUTPUT_PATH=""
SKIP_BUILD=false
ENFORCE=true

usage() {
  print "Usage: ./scripts/benchmark-runner-resources.sh [options]"
  print
  print "  --iterations <count>  Number of warm measurements after one cold launch (default: 15)."
  print "  --output <path>       Also write the result as JSON."
  print "  --skip-build          Measure an existing release binary."
  print "  --no-enforce          Report measurements without failing guardrails."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iterations)
      [[ $# -ge 2 ]] || { print -u2 "--iterations requires a value."; exit 64; }
      ITERATIONS=$2
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { print -u2 "--output requires a path."; exit 64; }
      OUTPUT_PATH=$2
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=true
      shift
      ;;
    --no-enforce)
      ENFORCE=false
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      print -u2 "Unknown argument: $1"
      usage >&2
      exit 64
      ;;
  esac
done

if [[ ! "${ITERATIONS}" =~ '^[0-9]+$' ]] || (( ITERATIONS < 5 )); then
  print -u2 "--iterations must be an integer of at least 5."
  exit 64
fi

for tool in /usr/bin/awk /usr/bin/cut /usr/bin/sort /usr/bin/stat /usr/bin/swift /usr/bin/time; do
  if [[ ! -x "${tool}" ]]; then
    print -u2 "Required tool is unavailable: ${tool}"
    exit 69
  fi
done

if [[ "${SKIP_BUILD}" == false ]]; then
  print "Building the release runner with warnings treated as errors..."
  /usr/bin/swift build \
    --package-path "${RUNNER_PACKAGE}" \
    -c release \
    --product aci-runner \
    -Xswiftc -warnings-as-errors
fi

RUNNER_BIN_DIRECTORY=$(
  /usr/bin/swift build --package-path "${RUNNER_PACKAGE}" -c release --show-bin-path
)
RUNNER="${RUNNER_BIN_DIRECTORY}/aci-runner"

if [[ ! -x "${RUNNER}" ]]; then
  print -u2 "Release runner is unavailable: ${RUNNER}"
  exit 69
fi

WORK_ROOT=$(/usr/bin/mktemp -d "${TEMPORARY_BASE%/}/aci-runner-benchmark.XXXXXX")
SAMPLES="${WORK_ROOT}/samples.csv"
WORKSPACES="${WORK_ROOT}/workspaces"

cleanup() {
  if [[ -n "${WORK_ROOT:-}" &&
        -d "${WORK_ROOT}" &&
        "${WORK_ROOT}" == "${TEMPORARY_BASE%/}/aci-runner-benchmark."* ]]; then
    /bin/rm -rf -- "${WORK_ROOT}"
  fi
}
trap cleanup EXIT

print "run,real_seconds,max_rss_bytes" > "${SAMPLES}"
total_runs=$((ITERATIONS + 1))

for run in $(/usr/bin/seq 1 "${total_runs}"); do
  time_file="${WORK_ROOT}/time-${run}.txt"
  log_file="${WORK_ROOT}/runner-${run}.log"

  if ! /usr/bin/time -lp -o "${time_file}" \
    "${RUNNER}" execute \
      --job "${FIXTURE}" \
      --workspace-root "${WORKSPACES}" \
      > "${log_file}" 2>&1; then
    /bin/cat "${log_file}" >&2
    print -u2 "The minimal runner job failed during resource measurement."
    exit 1
  fi

  real_seconds=$(
    /usr/bin/awk '$1 == "real" { print $2 }' "${time_file}"
  )
  max_rss_bytes=$(
    /usr/bin/awk '/maximum resident set size$/ { print $1 }' "${time_file}"
  )

  if [[ -z "${real_seconds}" || -z "${max_rss_bytes}" ]]; then
    print -u2 "Unable to parse macOS time output from ${time_file}."
    exit 1
  fi

  print "${run},${real_seconds},${max_rss_bytes}" >> "${SAMPLES}"
done

percentile() {
  local column=$1
  local percentile_value=$2

  /usr/bin/tail -n +3 "${SAMPLES}" |
    /usr/bin/cut -d, -f"${column}" |
    /usr/bin/sort -n |
    /usr/bin/awk -v percentile="${percentile_value}" '
      { values[NR] = $1 }
      END {
        rank = int((percentile * NR + 99) / 100)
        if (rank < 1) rank = 1
        if (rank > NR) rank = NR
        print values[rank]
      }
    '
}

cold_seconds=$(/usr/bin/awk -F, 'NR == 2 { print $2 }' "${SAMPLES}")
warm_p50_seconds=$(percentile 2 50)
warm_p95_seconds=$(percentile 2 95)
max_rss_bytes=$(
  /usr/bin/tail -n +2 "${SAMPLES}" |
    /usr/bin/cut -d, -f3 |
    /usr/bin/sort -nr |
    /usr/bin/head -n 1
)
binary_bytes=$(/usr/bin/stat -f '%z' "${RUNNER}")
binary_mib=$(/usr/bin/awk -v bytes="${binary_bytes}" 'BEGIN { printf "%.2f", bytes / 1048576 }')
rss_mib=$(/usr/bin/awk -v bytes="${max_rss_bytes}" 'BEGIN { printf "%.2f", bytes / 1048576 }')

print
print "ACI runner absolute resource guard"
print -- "- release binary: ${binary_mib} MiB (limit: 8.00 MiB)"
print -- "- cold minimal job: ${cold_seconds} s (limit: ${MAX_COLD_SECONDS} s)"
print -- "- warm minimal job p50: ${warm_p50_seconds} s (limit: ${MAX_WARM_P50_SECONDS} s)"
print -- "- warm minimal job p95: ${warm_p95_seconds} s (limit: ${MAX_WARM_P95_SECONDS} s)"
print -- "- maximum resident set: ${rss_mib} MiB (limit: 32.00 MiB)"

if [[ -n "${OUTPUT_PATH}" ]]; then
  output_directory=${OUTPUT_PATH:h}
  /bin/mkdir -p "${output_directory}"
  swift_version=$(/usr/bin/swift --version 2>&1 | /usr/bin/head -n 1)
  macos_version=$(/usr/bin/sw_vers -productVersion)
  architecture=$(/usr/bin/uname -m)

  /bin/cat > "${OUTPUT_PATH}" <<JSON
{
  "schemaVersion": 1,
  "machine": {
    "architecture": "${architecture}",
    "macOS": "${macos_version}",
    "swift": "${swift_version}"
  },
  "sampleCount": ${ITERATIONS},
  "measurements": {
    "binaryBytes": ${binary_bytes},
    "coldSeconds": ${cold_seconds},
    "warmP50Seconds": ${warm_p50_seconds},
    "warmP95Seconds": ${warm_p95_seconds},
    "maximumResidentSetBytes": ${max_rss_bytes}
  },
  "limits": {
    "binaryBytes": ${MAX_BINARY_BYTES},
    "coldSeconds": ${MAX_COLD_SECONDS},
    "warmP50Seconds": ${MAX_WARM_P50_SECONDS},
    "warmP95Seconds": ${MAX_WARM_P95_SECONDS},
    "maximumResidentSetBytes": ${MAX_RSS_BYTES}
  }
}
JSON
  print -- "- JSON result: ${OUTPUT_PATH}"
fi

if [[ "${ENFORCE}" == false ]]; then
  print "Resource guardrails were not enforced."
  exit 0
fi

failures=0

check_integer_limit() {
  local name=$1
  local actual=$2
  local limit=$3

  if (( actual > limit )); then
    print -u2 "Performance guard failed: ${name} ${actual} exceeds ${limit}."
    failures=$((failures + 1))
  fi
}

check_decimal_limit() {
  local name=$1
  local actual=$2
  local limit=$3

  if ! /usr/bin/awk -v actual="${actual}" -v limit="${limit}" \
    'BEGIN { exit(actual <= limit ? 0 : 1) }'; then
    print -u2 "Performance guard failed: ${name} ${actual} exceeds ${limit}."
    failures=$((failures + 1))
  fi
}

check_integer_limit "release binary bytes" "${binary_bytes}" "${MAX_BINARY_BYTES}"
check_decimal_limit "cold minimal-job seconds" "${cold_seconds}" "${MAX_COLD_SECONDS}"
check_decimal_limit "warm p50 minimal-job seconds" "${warm_p50_seconds}" "${MAX_WARM_P50_SECONDS}"
check_decimal_limit "warm p95 minimal-job seconds" "${warm_p95_seconds}" "${MAX_WARM_P95_SECONDS}"
check_integer_limit "maximum resident-set bytes" "${max_rss_bytes}" "${MAX_RSS_BYTES}"

if (( failures > 0 )); then
  exit 1
fi

print "All absolute runner resource guardrails passed."
