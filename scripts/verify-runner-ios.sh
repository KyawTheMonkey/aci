#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIRECTORY:h}
SAMPLE_ROOT="${REPOSITORY_ROOT}/samples/ios/ACISample"
TEMPORARY_BASE=${TMPDIR:-/tmp}
WORK_ROOT=$(/usr/bin/mktemp -d "${TEMPORARY_BASE%/}/aci-ios-acceptance.XXXXXX")
SOURCE_ROOT="${WORK_ROOT}/source"
WORKSPACE_ROOT="${WORK_ROOT}/workspaces"
RUN_ALL=false

cleanup() {
  if [[ -n "${WORK_ROOT:-}" &&
        -d "${WORK_ROOT}" &&
        "${WORK_ROOT}" == "${TEMPORARY_BASE%/}/aci-ios-acceptance."* ]]; then
    /bin/rm -rf -- "${WORK_ROOT}"
  fi
}
trap cleanup EXIT

case "${1:-}" in
  "")
    ;;
  --all)
    RUN_ALL=true
    ;;
  --help|-h)
    print "Usage: ./scripts/verify-runner-ios.sh [--all]"
    print "  no flag  Run the successful iOS checkout and XCTest scenario."
    print "  --all    Also verify compilation failure, test failure, timeout, and invalid SHA."
    exit 0
    ;;
  *)
    print -u2 "Unknown argument: $1"
    exit 64
    ;;
esac

for tool in /usr/bin/git /usr/bin/swift /usr/bin/xcodebuild /usr/bin/xcrun; do
  if [[ ! -x "${tool}" ]]; then
    print -u2 "Required tool is unavailable: ${tool}"
    exit 69
  fi
done

SIMULATOR_ID=$(
  /usr/bin/xcrun simctl list devices available |
    /usr/bin/sed -nE '/iPhone/ {
      s/.*\(([0-9A-F-]{36})\) \((Booted|Shutdown)\).*/\1/p
      q
    }'
)

if [[ -z "${SIMULATOR_ID}" ]]; then
  print -u2 "No available iPhone Simulator was found."
  exit 69
fi

/bin/mkdir -p "${SOURCE_ROOT}" "${WORKSPACE_ROOT}"
/bin/cp -R "${SAMPLE_ROOT}/." "${SOURCE_ROOT}/"
/usr/bin/git -C "${SOURCE_ROOT}" init --quiet
/usr/bin/git -C "${SOURCE_ROOT}" config user.name "ACI Acceptance"
/usr/bin/git -C "${SOURCE_ROOT}" config user.email "acceptance@aci.invalid"
/usr/bin/git -C "${SOURCE_ROOT}" add .
/usr/bin/git -C "${SOURCE_ROOT}" commit --quiet -m "Create iOS acceptance fixture"

COMMIT_SHA=$(/usr/bin/git -C "${SOURCE_ROOT}" rev-parse HEAD)
CLONE_URL="file://${SOURCE_ROOT}"
DESTINATION="platform=iOS Simulator,id=${SIMULATOR_ID}"

print "Building aci-runner..."
/usr/bin/swift build --package-path "${REPOSITORY_ROOT}/apps/runner" -c release
RUNNER_BIN_DIRECTORY=$(
  /usr/bin/swift build --package-path "${REPOSITORY_ROOT}/apps/runner" -c release --show-bin-path
)
RUNNER="${RUNNER_BIN_DIRECTORY}/aci-runner"

write_job() {
  local job_path=$1
  local commit_sha=$2
  local job_timeout=$3
  local step_timeout=$4
  local build_setting=${5:-}
  local optional_argument=""

  if [[ -n "${build_setting}" ]]; then
    optional_argument=", \"${build_setting}\""
  fi

  /bin/cat > "${job_path}" <<JSON
{
  "version": 1,
  "jobID": "$(/usr/bin/uuidgen)",
  "timeoutSeconds": ${job_timeout},
  "workspace": {
    "cleanAfterExecution": true
  },
  "repository": {
    "cloneURL": "${CLONE_URL}",
    "commitSHA": "${commit_sha}"
  },
  "steps": [
    {
      "id": "ios-tests",
      "name": "Run iOS tests",
      "kind": "command",
      "executable": "/usr/bin/xcodebuild",
      "arguments": [
        "test",
        "-quiet",
        "-scheme",
        "ACISample",
        "-destination",
        "${DESTINATION}",
        "-derivedDataPath",
        "DerivedData",
        "CODE_SIGNING_ALLOWED=NO"${optional_argument}
      ],
      "environment": {},
      "workingDirectory": null,
      "timeoutSeconds": ${step_timeout},
      "continueOnError": false
    }
  ],
  "artifacts": []
}
JSON
}

run_job() {
  local name=$1
  local expected_status=$2
  local expected_text=$3
  local job_path="${WORK_ROOT}/${name}.json"
  local log_path="${WORK_ROOT}/${name}.log"
  local exit_status

  print
  print "=== ${name} ==="

  if "${RUNNER}" execute --job "${job_path}" --workspace-root "${WORKSPACE_ROOT}" \
    --allow-local-repository > "${log_path}" 2>&1; then
    exit_status=0
  else
    exit_status=$?
  fi

  /bin/cat "${log_path}"

  if [[ "${expected_status}" == "success" && "${exit_status}" -ne 0 ]]; then
    print -u2 "Expected ${name} to succeed; exit status was ${exit_status}."
    exit 1
  fi

  if [[ "${expected_status}" == "failure" && "${exit_status}" -eq 0 ]]; then
    print -u2 "Expected ${name} to fail."
    exit 1
  fi

  if ! /usr/bin/grep -Fq -- "${expected_text}" "${log_path}"; then
    print -u2 "Expected ${name} output to contain: ${expected_text}"
    exit 1
  fi
}

write_job "${WORK_ROOT}/success.json" "${COMMIT_SHA}" 360 300
run_job "success" "success" ": succeeded"

if [[ "${RUN_ALL}" == true ]]; then
  write_job "${WORK_ROOT}/compilation-failure.json" "${COMMIT_SHA}" 360 300 \
    "OTHER_SWIFT_FLAGS=-DACI_COMPILE_FAILURE"
  run_job "compilation-failure" "failure" ": failed"

  write_job "${WORK_ROOT}/test-failure.json" "${COMMIT_SHA}" 360 300 \
    "OTHER_SWIFT_FLAGS=-DACI_TEST_FAILURE"
  run_job "test-failure" "failure" ": failed"

  write_job "${WORK_ROOT}/timeout.json" "${COMMIT_SHA}" 30 8 \
    "OTHER_SWIFT_FLAGS=-DACI_TEST_TIMEOUT"
  run_job "timeout" "failure" ": timedOut"

  write_job "${WORK_ROOT}/invalid-sha.json" \
    "ffffffffffffffffffffffffffffffffffffffff" 60 30
  run_job "invalid-sha" "failure" "Repository checkout failed"
fi

print
print "ACI iOS runner acceptance verification passed."
