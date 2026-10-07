#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
REPOSITORY_ROOT=${SCRIPT_DIRECTORY:h}
RUNNER_PACKAGE="${REPOSITORY_ROOT}/apps/runner"
PERFORMANCE_PACKAGE="${RUNNER_PACKAGE}/Performance"
MODE=${1:-all}

if [[ $# -gt 0 ]]; then
  shift
fi

case "${MODE}" in
  all)
    if [[ $# -ne 0 ]]; then
      print -u2 "The all mode does not accept additional arguments."
      exit 64
    fi

    (
      cd "${PERFORMANCE_PACKAGE}"
      /usr/bin/swift package benchmark --target ACIRunnerBenchmarks --no-progress
    )
    "${SCRIPT_DIRECTORY}/benchmark-runner-resources.sh"
    ;;
  micro)
    (
      cd "${PERFORMANCE_PACKAGE}"
      /usr/bin/swift package benchmark --target ACIRunnerBenchmarks "$@"
    )
    ;;
  resources)
    "${SCRIPT_DIRECTORY}/benchmark-runner-resources.sh" "$@"
    ;;
  --help|-h|help)
    print "Usage: ./scripts/benchmark-runner.sh [all|micro|resources] [options]"
    print
    print "  all        Run Swift microbenchmarks and absolute resource guardrails."
    print "  micro      Run the ACIRunnerBenchmarks target; remaining arguments pass through."
    print "  resources  Measure the release CLI; remaining arguments pass through."
    ;;
  *)
    print -u2 "Unknown benchmark mode: ${MODE}"
    exit 64
    ;;
esac
