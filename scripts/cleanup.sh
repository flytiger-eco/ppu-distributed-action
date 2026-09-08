#!/usr/bin/env bash
set -uo pipefail

log_info()  { echo "::notice::[cleanup] $*"; }
log_warn()  { echo "::warning::[cleanup] $*"; }
log_error() { echo "::error::[cleanup] $*"; }

NAMESPACE="${INPUT_NAMESPACE:-default}"
JOB_NAME="${JOB_NAME:-}"
JOB_STATUS="${JOB_STATUS:-unknown}"
CLEANUP_POLICY="${INPUT_CLEANUP_POLICY:-on_success}"
NNODES="${INPUT_NNODES:-0}"
SOURCE_STAGE_DIR="${SOURCE_STAGE_DIR:-}"

if [ -z "$JOB_NAME" ]; then
  log_warn "未提供 job 名称，跳过清理。"
  # 即使无 job 名称也清理 NAS 暂存 tarball
  if [ -n "${SOURCE_STAGE_DIR:-}" ] && [ -f "$SOURCE_STAGE_DIR" ]; then
    log_info "清理 NAS 源码暂存 tarball: $SOURCE_STAGE_DIR"
    rm -f "$SOURCE_STAGE_DIR"
    _parent_dir="$(dirname "$SOURCE_STAGE_DIR")"
    if [ -d "$_parent_dir" ] && [ -z "$(ls -A "$_parent_dir" 2>/dev/null)" ]; then
      rmdir "$_parent_dir" 2>/dev/null || true
    fi
  fi
  exit 0
fi

# NAS 源码暂存 tarball 始终清理（无论 cleanup_policy，因为只是临时中转存储）
if [ -n "${SOURCE_STAGE_DIR:-}" ] && [ -f "$SOURCE_STAGE_DIR" ]; then
  log_info "清理 NAS 源码暂存 tarball: $SOURCE_STAGE_DIR"
  rm -f "$SOURCE_STAGE_DIR"
  _parent_dir="$(dirname "$SOURCE_STAGE_DIR")"
  if [ -d "$_parent_dir" ] && [ -z "$(ls -A "$_parent_dir" 2>/dev/null)" ]; then
    rmdir "$_parent_dir" 2>/dev/null || true
  fi
fi

log_info "评估清理: $JOB_NAME (status=$JOB_STATUS, policy=$CLEANUP_POLICY)"

SHOULD_CLEANUP=false
case "$CLEANUP_POLICY" in
  never)
    log_info "policy=never，保留全部资源。"
    ;;
  always)
    SHOULD_CLEANUP=true
    log_info "policy=always，执行清理。"
    ;;
  on_success)
    if [ "$JOB_STATUS" = "succeeded" ]; then
      SHOULD_CLEANUP=true
      log_info "作业成功且 policy=on_success，执行清理。"
    else
      log_info "作业非成功 (status=$JOB_STATUS)，policy=on_success，保留资源供调试。"
    fi
    ;;
  on_failure)
    if [ "$JOB_STATUS" != "succeeded" ]; then
      SHOULD_CLEANUP=true
      log_info "作业非成功 (status=$JOB_STATUS) 且 policy=on_failure，执行清理。"
    else
      log_info "作业成功，policy=on_failure，保留资源。"
    fi
    ;;
  *)
    log_warn "未知 cleanup_policy '$CLEANUP_POLICY'，保留资源。"
    ;;
esac

if [ "$SHOULD_CLEANUP" = false ]; then
  log_info "跳过清理。资源保留在 namespace: $NAMESPACE"
  log_info "查看: kubectl get pods -n $NAMESPACE -l ppu-job=$JOB_NAME"
  exit 0
fi

POD_SELECTOR="ppu-job=$JOB_NAME"

# 带重试的 delete（应对 etcd NOSPACE 等暂时性故障）
kube_delete_retry() {
  local max_retries=3 delay=5
  for attempt in $(seq 1 $max_retries); do
    if "$@" 2>/dev/null; then return 0; fi
    if [ $attempt -lt $max_retries ]; then
      log_warn "删除失败（第${attempt}次），${delay}s 后重试..."
      sleep $delay
    fi
  done
  log_warn "删除在 ${max_retries} 次重试后仍失败，跳过。"
  return 0
}

log_info "删除 pods: $JOB_NAME (namespace=$NAMESPACE)"
kube_delete_retry kubectl delete pods -n "$NAMESPACE" -l "$POD_SELECTOR" --ignore-not-found=true

# Service 与 PodGroup 仅在 gang 模式（nnodes>=2）创建，单机模式跳过删除以避免多余告警
if [ "$NNODES" != "0" ]; then
  log_info "删除 service: $JOB_NAME"
  kube_delete_retry kubectl delete svc "$JOB_NAME" -n "$NAMESPACE" --ignore-not-found=true

  log_info "删除 podgroup: $JOB_NAME"
  kube_delete_retry kubectl delete podgroups.scheduling.x-k8s.io "$JOB_NAME" -n "$NAMESPACE" --ignore-not-found=true
else
  log_info "单卡/多卡模式（nnodes=0），无 service/podgroup 需清理，跳过。"
fi

WAIT_TIMEOUT=60
WAIT_START=$(date +%s)

log_info "等待关联 pod 终止..."
while true; do
  ELAPSED=$(( $(date +%s) - WAIT_START ))
  POD_COUNT=$(kubectl get pods -n "$NAMESPACE" -l "$POD_SELECTOR" \
                --no-headers 2>/dev/null | wc -l | tr -d ' ')

  if [ "${POD_COUNT:-0}" -eq 0 ]; then
    log_info "所有关联 pod 已终止。"
    break
  fi

  if [ "$ELAPSED" -ge "$WAIT_TIMEOUT" ]; then
    log_warn "等待 pod 终止超时 (${WAIT_TIMEOUT}s)，强制删除残留 pod。"
    kubectl delete pods -n "$NAMESPACE" -l "$POD_SELECTOR" \
      --force --grace-period=0 2>/dev/null || true
    break
  fi

  echo "  等待 ${POD_COUNT} 个 pod 终止... (${ELAPSED}s/${WAIT_TIMEOUT}s)"
  sleep 5
done

if [ -d "/tmp/training-manifests" ]; then
  log_info "清理临时 manifest 文件"
  rm -rf /tmp/training-manifests
fi

log_info "清理完成: $JOB_NAME"
