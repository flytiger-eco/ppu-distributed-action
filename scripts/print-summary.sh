#!/usr/bin/env bash
set -uo pipefail

[ -n "${JOB_STATUS:-}" ] || { echo "PPU job was not submitted, skipping usage summary"; exit 0; }

format_duration() {
  local total_seconds="${1:-0}"
  [[ "$total_seconds" =~ ^[0-9]+$ ]] || total_seconds=0
  printf '%dh %dm %ds' \
    "$(( total_seconds / 3600 ))" \
    "$(( total_seconds % 3600 / 60 ))" \
    "$(( total_seconds % 60 ))"
}

pods="${NNODES:-0}"
[[ "$pods" =~ ^[0-9]+$ ]] || pods=0
[ "$pods" -eq 0 ] && pods=1
cards="${NPROC_PER_NODE:-1}"
[[ "$cards" =~ ^[0-9]+$ ]] || cards=1

queue="$(format_duration "${QUEUE_DURATION_SECONDS:-0}")"
unscheduled="${UNSCHEDULED_PODS:-0}"
[[ "$unscheduled" =~ ^[0-9]+$ ]] || unscheduled=0
[ "$unscheduled" -gt 0 ] && queue="${queue} (${unscheduled}/${pods} pod(s) never scheduled)"

echo "::group::PPU usage summary"
printf '%-28s %s\n' \
  "Job name:" "${JOB_NAME:-}" \
  "Status:" "$JOB_STATUS" \
  "PPU topology:" "${pods} pod(s) x ${cards} PPU = $(( pods * cards )) PPU" \
  "Queue duration:" "$queue" \
  "Job duration:" "$(format_duration "${DURATION_SECONDS:-0}")" \
  "PPU card-hours (occupied):" "${OCCUPIED_PPU_CARD_HOURS:-0.0000}" \
  "PPU card-hours (execution):" "${EXECUTION_PPU_CARD_HOURS:-0.0000}" \
  "Pods:" "${TASK_PODS:-}"
echo
echo "Metric definitions:"
echo "  Queue duration: time from the first pod creation until all PPU pods are scheduled; a pod that is never scheduled is measured until the job ends."
echo "  PPU card-hours (occupied): sum of each pod's PPU count multiplied by the time from scheduling to completion, including image pulling and container startup."
echo "  PPU card-hours (execution): sum of each pod's PPU count multiplied by the worker container running time."
echo "::endgroup::"

echo "::notice::PPU usage: ${JOB_STATUS} | ${pods} pod(s) x ${cards} PPU | queue ${queue} | occupied ${OCCUPIED_PPU_CARD_HOURS:-0.0000} card-hours | execution ${EXECUTION_PPU_CARD_HOURS:-0.0000} card-hours"
