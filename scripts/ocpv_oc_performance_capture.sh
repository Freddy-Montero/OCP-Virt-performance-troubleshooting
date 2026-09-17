#!/usr/bin/env bash
# OpenShift API and KubeVirt performance evidence collector.
# Run from an administrative workstation with oc, jq, cluster access, and
# permission to read the target VM, pod, node, and Portworx namespace.

set -Eeuo pipefail
umask 077

VERSION="1.0"
NAMESPACE=""
VM_NAME=""
PVC_NAME=""
PX_NAMESPACE=""
DURATION=330
INTERVAL=5
OUTPUT_ROOT="${PWD}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-oc-capture}"
DO_MUST_GATHER=false
DO_INSPECT=false
BACKGROUND_PIDS=()

usage() {
  cat <<'EOF'
Usage:
  ./ocpv_oc_performance_capture.sh --namespace NS --vm VM [options]

Required:
  --namespace NS        Namespace containing the VM
  --vm NAME             VirtualMachine name

Options:
  --pvc NAME            Test PVC to map to PV and Portworx volume
  --px-namespace NS     Portworx namespace, auto-detected when omitted
  --duration SECONDS    Collection duration, default 330
  --interval SECONDS    Polling interval, default 5
  --run-id ID           Shared test run ID
  --output DIR          Parent directory for results
  --inspect             Add oc adm inspect for the VM node and namespaces
  --must-gather         Add a standard oc adm must-gather after collection
  -h, --help            Show this help

Example:
  ./ocpv_oc_performance_capture.sh \
    --namespace ent-intranet-nonprod \
    --vm whmm66762 \
    --pvc wave3-whmm66762-vm-68680-kffpq-mig-fbff \
    --duration 330 \
    --run-id 20260917T150000Z-supp4-repl2-8k70r30w-q32

This script is read-only. The optional inspect and must-gather operations can
produce large evidence directories and extra API load.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="${2:?missing namespace}"; shift 2 ;;
    --vm) VM_NAME="${2:?missing VM name}"; shift 2 ;;
    --pvc) PVC_NAME="${2:?missing PVC name}"; shift 2 ;;
    --px-namespace) PX_NAMESPACE="${2:?missing Portworx namespace}"; shift 2 ;;
    --duration) DURATION="${2:?missing duration}"; shift 2 ;;
    --interval) INTERVAL="${2:?missing interval}"; shift 2 ;;
    --run-id) RUN_ID="${2:?missing run ID}"; shift 2 ;;
    --output) OUTPUT_ROOT="${2:?missing output directory}"; shift 2 ;;
    --inspect) DO_INSPECT=true; shift ;;
    --must-gather) DO_MUST_GATHER=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -n "$NAMESPACE" ]] || die "--namespace is required"
[[ -n "$VM_NAME" ]] || die "--vm is required"
[[ "$DURATION" =~ ^[1-9][0-9]*$ ]] || die "duration must be a positive integer"
[[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] || die "interval must be a positive integer"
[[ "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]] || die "run ID contains unsupported characters"
command -v oc >/dev/null 2>&1 || die "oc was not found"
command -v jq >/dev/null 2>&1 || die "jq was not found"
oc whoami >/dev/null 2>&1 || die "oc is not logged in"

OUT_DIR="${OUTPUT_ROOT%/}/ocpv-oc-${NAMESPACE}-${VM_NAME}-${RUN_ID}"
mkdir -p "$OUT_DIR"/{cluster,vm,node,storage,portworx,logs,metrics,inspect,must-gather}
LOG="$OUT_DIR/collector.log"
exec > >(tee -a "$LOG") 2>&1

echo "OpenShift API and KubeVirt collector v$VERSION"
echo "RUN_ID=$RUN_ID"
echo "START_UTC=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"

run_capture() {
  local name=$1
  shift
  {
    echo "COMMAND: $*"
    echo "START_UTC: $(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
    "$@"
    rc=$?
    echo "END_UTC: $(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
    echo "RC: $rc"
  } >"$OUT_DIR/$name" 2>&1 || true
}

run_shell() {
  local name=$1
  shift
  {
    echo "COMMAND: $*"
    echo "START_UTC: $(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
    bash -o pipefail -c "$*"
    rc=$?
    echo "END_UTC: $(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
    echo "RC: $rc"
  } >"$OUT_DIR/$name" 2>&1 || true
}

start_background() {
  local name=$1
  shift
  echo "Starting $name"
  ( "$@" ) >"$OUT_DIR/$name" 2>&1 &
  BACKGROUND_PIDS+=("$!")
}

cleanup() {
  local pid
  for pid in "${BACKGROUND_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

# Resolve the live VMI, virt-launcher pod, node, PVC, PV, and CSI handle.
oc get vm "$VM_NAME" -n "$NAMESPACE" >/dev/null 2>&1 || die "VM $NAMESPACE/$VM_NAME was not found"

POD=$(oc get pod -n "$NAMESPACE" -l "kubevirt.io=virt-launcher,vm.kubevirt.io/name=$VM_NAME" -o json | jq -r '.items | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty')
if [[ -z "$POD" ]]; then
  POD=$(oc get pod -n "$NAMESPACE" -l "kubevirt.io=virt-launcher" -o json | jq -r --arg vm "$VM_NAME" '.items[] | select(.metadata.labels["vm.kubevirt.io/name"]==$vm or .metadata.annotations["kubevirt.io/domain"]==$vm) | .metadata.name' | tail -1)
fi
[[ -n "$POD" ]] || die "no running virt-launcher pod was found for $NAMESPACE/$VM_NAME"

NODE=$(oc get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}')
PV_NAME=""
PX_VOLUME=""
STORAGE_CLASS=""
if [[ -n "$PVC_NAME" ]]; then
  oc get pvc "$PVC_NAME" -n "$NAMESPACE" >/dev/null 2>&1 || die "PVC $NAMESPACE/$PVC_NAME was not found"
  PV_NAME=$(oc get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}')
  STORAGE_CLASS=$(oc get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.storageClassName}')
  [[ -n "$PV_NAME" ]] && PX_VOLUME=$(oc get pv "$PV_NAME" -o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null || true)
fi

if [[ -z "$PX_NAMESPACE" ]]; then
  PX_NAMESPACE=$(oc get storagecluster -A -o json 2>/dev/null | jq -r '.items[0].metadata.namespace // empty' || true)
fi
if [[ -z "$PX_NAMESPACE" ]]; then
  PX_NAMESPACE=$(oc get pods -A -o json | jq -r '.items[] | select(.metadata.name|test("px-cluster|portworx";"i")) | .metadata.namespace' | head -1)
fi

cat > "$OUT_DIR/run-metadata.txt" <<EOF
run_id=$RUN_ID
start_utc=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
namespace=$NAMESPACE
vm=$VM_NAME
virt_launcher_pod=$POD
node=$NODE
pvc=$PVC_NAME
pv=$PV_NAME
storage_class=$STORAGE_CLASS
px_volume=$PX_VOLUME
px_namespace=$PX_NAMESPACE
duration_seconds=$DURATION
interval_seconds=$INTERVAL
EOF
cat "$OUT_DIR/run-metadata.txt"

# Cluster and operator versions.
run_capture cluster/oc-version.yaml oc version -o yaml
run_capture cluster/whoami.txt oc whoami
run_capture cluster/clusterversion.yaml oc get clusterversion -o yaml
run_capture cluster/clusteroperators.txt oc get co
run_capture cluster/nodes-wide.txt oc get nodes -o wide
run_capture cluster/storageclasses.yaml oc get storageclass -o yaml
run_shell cluster/virtualization-csv.txt "oc get csv -A | grep -Ei 'kubevirt|virtualization|hyperconverged'"
run_capture cluster/hyperconverged.yaml oc get hyperconverged -A -o yaml

# VM, VMI, pod, events, and active libvirt configuration.
run_capture vm/vm.yaml oc get vm "$VM_NAME" -n "$NAMESPACE" -o yaml
run_capture vm/vmi.yaml oc get vmi "$VM_NAME" -n "$NAMESPACE" -o yaml
run_capture vm/vm-describe.txt oc describe vm "$VM_NAME" -n "$NAMESPACE"
run_capture vm/vmi-describe.txt oc describe vmi "$VM_NAME" -n "$NAMESPACE"
run_capture vm/virt-launcher-pod.yaml oc get pod "$POD" -n "$NAMESPACE" -o yaml
run_capture vm/virt-launcher-describe.txt oc describe pod "$POD" -n "$NAMESPACE"
run_capture vm/namespace-events.txt oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp
run_capture vm/compute-resources.json bash -c "oc get pod '$POD' -n '$NAMESPACE' -o json | jq '.spec.containers[] | select(.name==\"compute\") | {resources,securityContext,volumeDevices,volumeMounts}'"
run_capture vm/active-domain.xml oc exec -n "$NAMESPACE" -c compute "$POD" -- virsh dumpxml 1
run_capture vm/dominfo.txt oc exec -n "$NAMESPACE" -c compute "$POD" -- virsh dominfo 1
run_capture vm/domblklist.txt oc exec -n "$NAMESPACE" -c compute "$POD" -- virsh domblklist 1 --details
run_capture vm/domstats-before.txt oc exec -n "$NAMESPACE" -c compute "$POD" -- virsh domstats 1 --block --vcpu --balloon
run_shell vm/xml-storage-and-pinning.txt "oc exec -n '$NAMESPACE' -c compute '$POD' -- virsh dumpxml 1 | grep -En 'iothreads|iothreadids|iothreadpin|vcpupin|emulatorpin|<disk|<driver|<target|<address'"
run_shell vm/cgroup-before.txt "for f in cpu.stat cpu.pressure memory.current memory.events memory.pressure io.stat io.pressure; do echo =====\$f=====; oc exec -n '$NAMESPACE' -c compute '$POD' -- sh -c \"cat /sys/fs/cgroup/\$f 2>/dev/null || true\"; done"
run_capture logs/compute-since-30m.log oc logs -n "$NAMESPACE" "$POD" -c compute --since=30m --timestamps

# Node object, capacity, allocation, labels, taints, conditions, and top data.
run_capture node/node.yaml oc get node "$NODE" -o yaml
run_capture node/node-describe.txt oc describe node "$NODE"
run_capture node/node-summary.json bash -c "oc get node '$NODE' -o json | jq '{name:.metadata.name,labels:.metadata.labels,annotations:.metadata.annotations,taints:.spec.taints,capacity:.status.capacity,allocatable:.status.allocatable,nodeInfo:.status.nodeInfo,conditions:.status.conditions}'"
run_capture metrics/node-top-before.txt oc adm top node "$NODE"
run_capture metrics/pod-top-before.txt oc adm top pod "$POD" -n "$NAMESPACE" --containers

# PVC, PV, CSI handle, StorageClass, and attachment objects.
if [[ -n "$PVC_NAME" ]]; then
  run_capture storage/pvc.yaml oc get pvc "$PVC_NAME" -n "$NAMESPACE" -o yaml
  run_capture storage/pvc-describe.txt oc describe pvc "$PVC_NAME" -n "$NAMESPACE"
  [[ -n "$PV_NAME" ]] && run_capture storage/pv.yaml oc get pv "$PV_NAME" -o yaml
  [[ -n "$PV_NAME" ]] && run_capture storage/pv-describe.txt oc describe pv "$PV_NAME"
  [[ -n "$STORAGE_CLASS" ]] && run_capture storage/storageclass.yaml oc get storageclass "$STORAGE_CLASS" -o yaml
  [[ -n "$PV_NAME" ]] && run_shell storage/volumeattachments.txt "oc get volumeattachment -o json | jq --arg pv '$PV_NAME' '.items[] | select(.spec.source.persistentVolumeName==\$pv)'"
fi
run_capture storage/csinodes.yaml oc get csinode -o yaml
run_capture storage/csidrivers.yaml oc get csidriver -o yaml

# Virtualization control-plane logs and virt-handler on the VM node.
VIRT_HANDLER_POD=$(oc get pod -n openshift-cnv --field-selector "spec.nodeName=$NODE" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name|startswith("virt-handler-")) | .metadata.name' | head -1 || true)
[[ -n "$VIRT_HANDLER_POD" ]] && run_capture logs/virt-handler.log oc logs -n openshift-cnv "$VIRT_HANDLER_POD" --all-containers --since=30m --timestamps --prefix
run_capture logs/virt-controller.log oc logs -n openshift-cnv deploy/virt-controller --all-containers --since=30m --timestamps --prefix
run_capture logs/virt-api.log oc logs -n openshift-cnv deploy/virt-api --all-containers --since=30m --timestamps --prefix
run_capture logs/cnv-events.txt oc get events -n openshift-cnv --sort-by=.lastTimestamp

# Portworx Kubernetes resources, events, and the Portworx pod on the VM node.
PX_POD=""
if [[ -n "$PX_NAMESPACE" ]]; then
  run_capture portworx/storageclusters.yaml oc get storagecluster -n "$PX_NAMESPACE" -o yaml
  run_capture portworx/storagenodes.yaml oc get storagenode -n "$PX_NAMESPACE" -o yaml
  run_capture portworx/pods-wide.txt oc get pods -n "$PX_NAMESPACE" -o wide
  run_capture portworx/events.txt oc get events -n "$PX_NAMESPACE" --sort-by=.lastTimestamp
  PX_POD=$(oc get pods -n "$PX_NAMESPACE" --field-selector "spec.nodeName=$NODE" -o json | jq -r '.items[] | select(.metadata.name|test("px-cluster|portworx";"i")) | .metadata.name' | head -1 || true)
  if [[ -n "$PX_POD" ]]; then
    run_capture portworx/px-pod.yaml oc get pod "$PX_POD" -n "$PX_NAMESPACE" -o yaml
    run_capture portworx/px-pod-describe.txt oc describe pod "$PX_POD" -n "$PX_NAMESPACE"
    run_capture logs/portworx-node.log oc logs -n "$PX_NAMESPACE" "$PX_POD" --all-containers --since=30m --timestamps --prefix
    PX_CONTAINER=$(oc get pod "$PX_POD" -n "$PX_NAMESPACE" -o json | jq -r '.spec.containers[] | select(.name|test("portworx|px";"i")) | .name' | head -1 || true)
    [[ -z "$PX_CONTAINER" ]] && PX_CONTAINER=$(oc get pod "$PX_POD" -n "$PX_NAMESPACE" -o jsonpath='{.spec.containers[0].name}')
    PXCTL_PATH=$(oc exec -n "$PX_NAMESPACE" -c "$PX_CONTAINER" "$PX_POD" -- sh -c 'command -v pxctl || test -x /opt/pwx/bin/pxctl && echo /opt/pwx/bin/pxctl' 2>/dev/null | tail -1 || true)
    if [[ -n "$PXCTL_PATH" ]]; then
      run_capture portworx/pxctl-status.txt oc exec -n "$PX_NAMESPACE" -c "$PX_CONTAINER" "$PX_POD" -- "$PXCTL_PATH" status
      run_capture portworx/pxctl-cluster-list.txt oc exec -n "$PX_NAMESPACE" -c "$PX_CONTAINER" "$PX_POD" -- "$PXCTL_PATH" cluster list
      run_capture portworx/pxctl-provision-status.txt oc exec -n "$PX_NAMESPACE" -c "$PX_CONTAINER" "$PX_POD" -- "$PXCTL_PATH" cluster provision-status
      run_capture portworx/pxctl-pools.txt oc exec -n "$PX_NAMESPACE" -c "$PX_CONTAINER" "$PX_POD" -- "$PXCTL_PATH" service pool show
      run_capture portworx/pxctl-alerts-before.txt oc exec -n "$PX_NAMESPACE" -c "$PX_CONTAINER" "$PX_POD" -- "$PXCTL_PATH" alerts show
      if [[ -n "$PX_VOLUME" ]]; then
        run_capture portworx/pxctl-volume-inspect.txt oc exec -n "$PX_NAMESPACE" -c "$PX_CONTAINER" "$PX_POD" -- "$PXCTL_PATH" volume inspect "$PX_VOLUME"
        run_capture portworx/pxctl-volume-stats-before.txt oc exec -n "$PX_NAMESPACE" -c "$PX_CONTAINER" "$PX_POD" -- "$PXCTL_PATH" volume stats "$PX_VOLUME"
      fi
    fi
  fi
fi

# Continuous OpenShift/QEMU/Portworx polling during the external workload.
start_background metrics/oc-stream.txt timeout "$DURATION" bash -c '
  while true; do
    date -u +%Y-%m-%dT%H:%M:%S.%NZ
    echo "===== NODE TOP ====="
    oc adm top node '"$NODE"' 2>&1 || true
    echo "===== POD TOP ====="
    oc adm top pod '"$POD"' -n '"$NAMESPACE"' --containers 2>&1 || true
    echo "===== DOMSTATS ====="
    oc exec -n '"$NAMESPACE"' -c compute '"$POD"' -- virsh domstats 1 --block --vcpu --balloon 2>&1 || true
    sleep '"$INTERVAL"'
  done'

start_background metrics/cgroup-stream.txt timeout "$DURATION" bash -c '
  while true; do
    date -u +%Y-%m-%dT%H:%M:%S.%NZ
    for f in cpu.stat cpu.pressure memory.current memory.events memory.pressure io.stat io.pressure; do
      echo "===== $f ====="
      oc exec -n '"$NAMESPACE"' -c compute '"$POD"' -- sh -c "cat /sys/fs/cgroup/$f 2>/dev/null || true" 2>&1
    done
    sleep '"$INTERVAL"'
  done'

if [[ -n "${PXCTL_PATH:-}" && -n "$PX_VOLUME" && -n "$PX_POD" ]]; then
  start_background portworx/pxctl-volume-stream.txt timeout "$DURATION" bash -c '
    while true; do
      date -u +%Y-%m-%dT%H:%M:%S.%NZ
      oc exec -n '"$PX_NAMESPACE"' -c '"$PX_CONTAINER"' '"$PX_POD"' -- '"$PXCTL_PATH"' volume stats '"$PX_VOLUME"' 2>&1 || true
      sleep '"$INTERVAL"'
    done'
fi

echo "Collectors started. Run the approved DiskSpd workload now."
echo "Collection will stop after $DURATION seconds."
sleep "$DURATION"

for pid in "${BACKGROUND_PIDS[@]:-}"; do
  wait "$pid" 2>/dev/null || true
done
BACKGROUND_PIDS=()

# Final counter snapshots and recent events/logs.
run_capture vm/domstats-after.txt oc exec -n "$NAMESPACE" -c compute "$POD" -- virsh domstats 1 --block --vcpu --balloon
run_shell vm/cgroup-after.txt "for f in cpu.stat cpu.pressure memory.current memory.events memory.pressure io.stat io.pressure; do echo =====\$f=====; oc exec -n '$NAMESPACE' -c compute '$POD' -- sh -c \"cat /sys/fs/cgroup/\$f 2>/dev/null || true\"; done"
run_capture metrics/node-top-after.txt oc adm top node "$NODE"
run_capture metrics/pod-top-after.txt oc adm top pod "$POD" -n "$NAMESPACE" --containers
run_capture vm/namespace-events-after.txt oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp
run_capture logs/compute-after.log oc logs -n "$NAMESPACE" "$POD" -c compute --since=15m --timestamps
if [[ -n "${PXCTL_PATH:-}" && -n "$PX_POD" ]]; then
  run_capture portworx/pxctl-alerts-after.txt oc exec -n "$PX_NAMESPACE" -c "$PX_CONTAINER" "$PX_POD" -- "$PXCTL_PATH" alerts show
  run_capture portworx/pxctl-pools-after.txt oc exec -n "$PX_NAMESPACE" -c "$PX_CONTAINER" "$PX_POD" -- "$PXCTL_PATH" service pool show
  [[ -n "$PX_VOLUME" ]] && run_capture portworx/pxctl-volume-stats-after.txt oc exec -n "$PX_NAMESPACE" -c "$PX_CONTAINER" "$PX_POD" -- "$PXCTL_PATH" volume stats "$PX_VOLUME"
fi

if $DO_INSPECT; then
  echo "Running optional oc adm inspect"
  oc adm inspect "node/$NODE" "ns/$NAMESPACE" --dest-dir="$OUT_DIR/inspect" > "$OUT_DIR/inspect/inspect.log" 2>&1 || true
  [[ -n "$PX_NAMESPACE" ]] && oc adm inspect "ns/$PX_NAMESPACE" --dest-dir="$OUT_DIR/inspect-portworx" > "$OUT_DIR/inspect/inspect-portworx.log" 2>&1 || true
fi

if $DO_MUST_GATHER; then
  echo "Running optional standard must-gather"
  (
    cd "$OUT_DIR/must-gather"
    oc adm must-gather
  ) > "$OUT_DIR/must-gather/must-gather.log" 2>&1 || true
fi

echo "end_utc=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" >> "$OUT_DIR/run-metadata.txt"
find "$OUT_DIR" -type f -printf '%P\t%s bytes\n' | sort > "$OUT_DIR/manifest.txt"
find "$OUT_DIR" -type f ! -name sha256sums.txt -print0 | sort -z | xargs -0 sha256sum > "$OUT_DIR/sha256sums.txt"

ARCHIVE="${OUT_DIR}.tar.gz"
tar -C "$(dirname "$OUT_DIR")" -czf "$ARCHIVE" "$(basename "$OUT_DIR")"
echo "Capture complete"
echo "Directory: $OUT_DIR"
echo "Archive:   $ARCHIVE"
