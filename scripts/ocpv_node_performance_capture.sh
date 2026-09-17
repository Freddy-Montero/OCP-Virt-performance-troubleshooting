#!/usr/bin/env bash
# OpenShift Virtualization node-side performance evidence collector.
# Run as root on the RHCOS/OpenShift worker hosting the VM, or on a
# Portworx replica node. The script is read-only and does not generate load.

set -Eeuo pipefail
umask 077

VERSION="1.0"
DURATION=330
INTERVAL=5
VM_NAME=""
PEER_IP=""
IFACE=""
WWID=""
PX_VOLUME=""
QEMU_PID=""
OUTPUT_ROOT="${PWD}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-node-capture}"
BACKGROUND_PIDS=()

usage() {
  cat <<'EOF'
Usage:
  sudo ./ocpv_node_performance_capture.sh [options]

Options:
  --vm NAME            VM name used to locate the QEMU process
  --qemu-pid PID       Explicit QEMU PID when automatic discovery is ambiguous
  --peer IP            Portworx replica peer IP used to resolve the data NIC
  --interface NAME     Explicit storage/replication interface
  --wwid WWID          Multipath WWID to capture in detail
  --px-volume ID       Portworx volume ID for inspect/stats collection
  --duration SECONDS   Collection duration, default 330
  --interval SECONDS   Polling interval, default 5
  --run-id ID          Shared test run ID
  --output DIR         Parent directory for results
  -h, --help           Show this help

Example:
  sudo ./ocpv_node_performance_capture.sh \
    --vm whmm66762 \
    --peer 172.19.226.6 \
    --wwid 3624a9370e77686a657c3466f1856fa8e \
    --px-volume 992160317935909378 \
    --duration 330

Start this script about 60 seconds before DiskSpd. Use the same --run-id on
the OCP collector, Windows test, Cisco MDS capture, and array export.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm) VM_NAME="${2:?missing VM name}"; shift 2 ;;
    --qemu-pid) QEMU_PID="${2:?missing QEMU PID}"; shift 2 ;;
    --peer) PEER_IP="${2:?missing peer IP}"; shift 2 ;;
    --interface) IFACE="${2:?missing interface}"; shift 2 ;;
    --wwid) WWID="${2:?missing WWID}"; shift 2 ;;
    --px-volume) PX_VOLUME="${2:?missing Portworx volume ID}"; shift 2 ;;
    --duration) DURATION="${2:?missing duration}"; shift 2 ;;
    --interval) INTERVAL="${2:?missing interval}"; shift 2 ;;
    --run-id) RUN_ID="${2:?missing run ID}"; shift 2 ;;
    --output) OUTPUT_ROOT="${2:?missing output directory}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "$DURATION" =~ ^[1-9][0-9]*$ ]] || die "duration must be a positive integer"
[[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] || die "interval must be a positive integer"
[[ "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]] || die "run ID contains unsupported characters"

HOST_SHORT=$(hostname -s 2>/dev/null || hostname)
OUT_DIR="${OUTPUT_ROOT%/}/ocpv-node-${HOST_SHORT}-${RUN_ID}"
mkdir -p "$OUT_DIR"/{system,cpu,qemu,network,fc,block,portworx,kernel}
LOG="$OUT_DIR/collector.log"
exec > >(tee -a "$LOG") 2>&1

echo "OpenShift Virtualization node collector v$VERSION"
echo "RUN_ID=$RUN_ID"
echo "HOST=$HOST_SHORT"
echo "START_UTC=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
echo "DURATION=$DURATION INTERVAL=$INTERVAL"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "WARNING: not running as root. Some HBA, multipath, kernel, and process data will be unavailable."
fi

have() { command -v "$1" >/dev/null 2>&1; }

record_missing() {
  echo "$1" >> "$OUT_DIR/missing-commands.txt"
}

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

cat > "$OUT_DIR/run-metadata.txt" <<EOF
run_id=$RUN_ID
host=$HOST_SHORT
start_utc=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
duration_seconds=$DURATION
interval_seconds=$INTERVAL
vm_name=$VM_NAME
peer_ip=$PEER_IP
interface_requested=$IFACE
wwid=$WWID
px_volume=$PX_VOLUME
EOF

# Resolve QEMU and network identities before collection.
if [[ -z "$QEMU_PID" && -n "$VM_NAME" ]]; then
  QEMU_PID=$(pgrep -f "qemu.*${VM_NAME}|${VM_NAME}.*qemu" | head -1 || true)
fi

if [[ -n "$QEMU_PID" && ! -r "/proc/$QEMU_PID/status" ]]; then
  echo "WARNING: QEMU PID $QEMU_PID is not readable. QEMU-specific collection is disabled."
  QEMU_PID=""
fi

if [[ -z "$IFACE" && -n "$PEER_IP" ]]; then
  IFACE=$(ip route get "$PEER_IP" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' || true)
fi

echo "QEMU_PID=${QEMU_PID:-not-resolved}" | tee -a "$OUT_DIR/run-metadata.txt"
echo "interface_resolved=${IFACE:-not-resolved}" | tee -a "$OUT_DIR/run-metadata.txt"

# System identity and time.
run_capture system/date-utc.txt date -u +%Y-%m-%dT%H:%M:%S.%NZ
run_capture system/uname.txt uname -a
run_capture system/os-release.txt cat /etc/os-release
have timedatectl && run_capture system/timedatectl.txt timedatectl || record_missing timedatectl
have rpm-ostree && run_capture system/rpm-ostree-status.txt rpm-ostree status || record_missing rpm-ostree
have systemctl && run_capture system/tuned.txt systemctl status tuned --no-pager || true
run_capture system/cmdline.txt cat /proc/cmdline
run_capture system/mounts.txt findmnt -A

# CPU, NUMA, memory, pressure, interrupts, and scheduler identity.
have lscpu && run_capture cpu/lscpu.txt lscpu || record_missing lscpu
have lscpu && run_capture cpu/lscpu-extended.txt lscpu -e=CPU,NODE,SOCKET,CORE,ONLINE,MAXMHZ,MINMHZ || true
have numactl && run_capture cpu/numactl-hardware.txt numactl --hardware || record_missing numactl
have numastat && run_capture cpu/numastat.txt numastat || record_missing numastat
run_capture cpu/meminfo.txt cat /proc/meminfo
have free && run_capture cpu/free.txt free -h || record_missing free
have swapon && run_capture cpu/swapon.txt swapon --show || record_missing swapon
run_capture cpu/pressure-cpu-before.txt cat /proc/pressure/cpu
run_capture cpu/pressure-memory-before.txt cat /proc/pressure/memory
run_capture cpu/pressure-io-before.txt cat /proc/pressure/io
run_capture cpu/interrupts-before.txt cat /proc/interrupts
run_capture cpu/softirqs-before.txt cat /proc/softirqs
run_capture cpu/schedstat-before.txt cat /proc/schedstat
run_shell cpu/cpu-topology-sysfs.txt 'for n in /sys/devices/system/node/node*; do echo "===== $n ====="; cat "$n/cpulist" "$n/meminfo" 2>/dev/null; done; grep -H . /sys/devices/system/cpu/{online,isolated,nohz_full} 2>/dev/null'
run_shell cpu/irq-affinity.txt 'for irq in $(awk '\''/fc|qla|lpfc|bnxt|mlx|enic|ixgbe|i40e|ice/ {gsub(":","",$1); print $1}'\'' /proc/interrupts); do printf "IRQ=%s affinity=" "$irq"; cat "/proc/irq/$irq/smp_affinity_list" 2>/dev/null; done'
have systemctl && run_capture cpu/irqbalance.txt systemctl status irqbalance --no-pager || true

# QEMU process, thread, cgroup, and NUMA evidence.
run_shell qemu/qemu-process-list.txt "ps -eLo pid,tid,psr,pcpu,stat,comm,wchan:32,args | grep '[q]emu'"
if [[ -n "$QEMU_PID" ]]; then
  run_capture qemu/status-before.txt cat "/proc/$QEMU_PID/status"
  run_capture qemu/sched-before.txt cat "/proc/$QEMU_PID/sched"
  run_capture qemu/io-before.txt cat "/proc/$QEMU_PID/io"
  run_capture qemu/cgroup.txt cat "/proc/$QEMU_PID/cgroup"
  have taskset && run_capture qemu/taskset.txt taskset -cp "$QEMU_PID" || record_missing taskset
  have numastat && run_capture qemu/numastat.txt numastat -p "$QEMU_PID" || true
  run_capture qemu/threads-before.txt ps -T -p "$QEMU_PID" -o pid,tid,psr,pcpu,stat,comm,wchan:32

  CGROUP_REL=$(awk -F: '$1=="0" {print $3}' "/proc/$QEMU_PID/cgroup" | head -1)
  if [[ -n "$CGROUP_REL" && -d "/sys/fs/cgroup$CGROUP_REL" ]]; then
    CGROUP_PATH="/sys/fs/cgroup$CGROUP_REL"
    echo "$CGROUP_PATH" > "$OUT_DIR/qemu/cgroup-path.txt"
    run_shell qemu/cgroup-before.txt "for f in cpu.stat cpu.pressure memory.current memory.events memory.pressure io.stat io.pressure; do echo =====\$f=====; cat '$CGROUP_PATH'/\$f 2>/dev/null || true; done"
  fi
fi

# Network path and NIC state.
run_capture network/ip-address.txt ip -details address show
run_capture network/ip-route-all.txt ip route show table all
run_capture network/ip-link-before.txt ip -s -s link show
have ss && run_capture network/ss-before.txt ss -tinp || record_missing ss
have nstat && run_capture network/nstat-before.txt nstat -az || record_missing nstat
have tc && run_capture network/qdisc-before.txt tc -s qdisc show || record_missing tc
if [[ -n "$PEER_IP" ]]; then
  run_capture network/route-to-peer.txt ip route get "$PEER_IP"
  have tracepath && run_capture network/tracepath-peer.txt tracepath -n "$PEER_IP" || record_missing tracepath
fi
if [[ -n "$IFACE" && -e "/sys/class/net/$IFACE" ]]; then
  run_capture network/interface-before.txt ip -s -s link show "$IFACE"
  if have ethtool; then
    run_capture network/ethtool-link.txt ethtool "$IFACE"
    run_capture network/ethtool-driver.txt ethtool -i "$IFACE"
    run_capture network/ethtool-features.txt ethtool -k "$IFACE"
    run_capture network/ethtool-ring.txt ethtool -g "$IFACE"
    run_capture network/ethtool-coalesce.txt ethtool -c "$IFACE"
    run_capture network/ethtool-channels.txt ethtool -l "$IFACE"
    run_capture network/ethtool-pause.txt ethtool -a "$IFACE"
    run_capture network/ethtool-stats-before.txt ethtool -S "$IFACE"
  else
    record_missing ethtool
  fi
  [[ -r "/proc/net/bonding/$IFACE" ]] && run_capture network/bond.txt cat "/proc/net/bonding/$IFACE"
  run_shell network/interface-lower-devices.txt "readlink -f /sys/class/net/'$IFACE'/lower_* /sys/class/net/'$IFACE'/master 2>/dev/null || true"
  run_shell network/interface-queues.txt "for q in /sys/class/net/'$IFACE'/queues/{rx,tx}-*; do echo =====\$q=====; grep -H . \$q/{rps_cpus,rps_flow_cnt,xps_cpus} 2>/dev/null; done"
fi

# Fibre Channel and HBA identity and starting counters.
have lspci && run_shell fc/lspci-hba.txt "lspci -nnk | grep -A4 -Ei 'fibre|fc hba|qlogic|emulex|broadcom'" || record_missing lspci
have lsmod && run_shell fc/modules.txt "lsmod | grep -E 'qla2xxx|lpfc'" || record_missing lsmod
have systool && run_capture fc/systool-fc-host.txt systool -c fc_host -v || record_missing systool
run_shell fc/fc-host-identity.txt 'for h in /sys/class/fc_host/host*; do echo "===== $h ====="; for f in port_name node_name port_id port_state speed supported_speeds fabric_name symbolic_name dev_loss_tmo; do [[ -r "$h/$f" ]] && printf "%-24s %s\n" "$f" "$(cat "$h/$f")"; done; drv=$(basename "$(readlink -f "$h/device/driver" 2>/dev/null)"); echo "driver=$drv"; done'
run_shell fc/fc-remote-ports.txt 'for r in /sys/class/fc_remote_ports/rport-*; do echo "===== $r ====="; grep -H . "$r"/{port_name,node_name,port_id,port_state,roles,scsi_target_id} 2>/dev/null; done'
run_shell fc/fc-statistics-before.txt 'for h in /sys/class/fc_host/host*; do echo "===== $h ====="; grep -H . "$h"/statistics/* 2>/dev/null; done'

# Block, SCSI, multipath, and queue state.
have lsblk && run_capture block/lsblk.txt lsblk -o NAME,KNAME,MAJ:MIN,TYPE,SIZE,HCTL,WWN,MODEL,VENDOR,ROTA,SCHED,RQ-SIZE,MIN-IO,OPT-IO,PHY-SEC,LOG-SEC,MOUNTPOINTS || record_missing lsblk
have lsscsi && run_capture block/lsscsi.txt lsscsi -g -t || record_missing lsscsi
have multipath && run_capture block/multipath-all.txt multipath -ll || record_missing multipath
if have multipathd; then
  run_capture block/multipathd-maps-status.txt multipathd show maps status
  run_capture block/multipathd-maps-topology.txt multipathd show maps topology
  run_capture block/multipathd-paths.txt multipathd show paths
  run_capture block/multipathd-config-local.txt multipathd show config local
else
  record_missing multipathd
fi
have dmsetup && run_capture block/dmsetup-info.txt dmsetup info -c || record_missing dmsetup
run_capture block/diskstats-before.txt cat /proc/diskstats
run_shell block/queue-settings.txt 'for d in /sys/block/*; do dev=$(basename "$d"); echo "===== $dev ====="; for f in scheduler nr_requests read_ahead_kb max_sectors_kb max_hw_sectors_kb logical_block_size physical_block_size minimum_io_size optimal_io_size rotational nomerges rq_affinity io_poll io_poll_delay; do [[ -r "$d/queue/$f" ]] && printf "%-24s %s\n" "$f" "$(cat "$d/queue/$f")"; done; [[ -r "$d/device/queue_depth" ]] && echo "scsi_queue_depth=$(cat "$d/device/queue_depth")"; done'
run_shell block/scsi-device-state.txt 'for d in /sys/class/scsi_device/*/device; do echo "===== $d ====="; grep -H . "$d"/{queue_depth,device_blocked,state,timeout} 2>/dev/null; done'
if [[ -n "$WWID" ]]; then
  have multipath && run_capture block/multipath-selected.txt multipath -ll "$WWID" || true
  [[ -e "/dev/mapper/$WWID" ]] && run_capture block/mapper-link.txt readlink -f "/dev/mapper/$WWID"
  have dmsetup && [[ -e "/dev/mapper/$WWID" ]] && run_capture block/dmsetup-status-selected.txt dmsetup status "/dev/mapper/$WWID" || true
fi

# Portworx CLI if present on the node.
PXCTL=""
if have pxctl; then
  PXCTL=$(command -v pxctl)
elif [[ -x /opt/pwx/bin/pxctl ]]; then
  PXCTL=/opt/pwx/bin/pxctl
fi
if [[ -n "$PXCTL" ]]; then
  timeout 30 "$PXCTL" status > "$OUT_DIR/portworx/status.txt" 2>&1 || true
  timeout 30 "$PXCTL" cluster list > "$OUT_DIR/portworx/cluster-list.txt" 2>&1 || true
  timeout 30 "$PXCTL" cluster provision-status > "$OUT_DIR/portworx/provision-status.txt" 2>&1 || true
  timeout 30 "$PXCTL" service pool show > "$OUT_DIR/portworx/pools.txt" 2>&1 || true
  timeout 30 "$PXCTL" alerts show > "$OUT_DIR/portworx/alerts-before.txt" 2>&1 || true
  if [[ -n "$PX_VOLUME" ]]; then
    timeout 30 "$PXCTL" volume inspect "$PX_VOLUME" > "$OUT_DIR/portworx/volume-inspect.txt" 2>&1 || true
    timeout 30 "$PXCTL" volume stats "$PX_VOLUME" > "$OUT_DIR/portworx/volume-stats-before.txt" 2>&1 || true
  fi
else
  record_missing pxctl
fi

# Kernel messages before load.
have journalctl && run_shell kernel/storage-journal-before.txt "journalctl -k --since '-30 min' | grep -Ei 'scsi|multipath|dm-|qla|lpfc|fc |fibre|abort|timeout|reset|offline|reject|sense|I/O error|oom|stall|lockup|mce|edac'" || record_missing journalctl
have dmesg && run_shell kernel/dmesg-before.txt "dmesg --ctime | tail -2000" || record_missing dmesg

# Bounded continuous collectors.
if have mpstat; then
  start_background cpu/mpstat-stream.txt timeout "$DURATION" mpstat -P ALL 1
else
  record_missing mpstat
fi
if have vmstat; then
  start_background cpu/vmstat-stream.txt timeout "$DURATION" vmstat -w 1
else
  record_missing vmstat
fi
if have pidstat; then
  start_background cpu/pidstat-system-stream.txt timeout "$DURATION" pidstat -h -u -w 1
  [[ -n "$QEMU_PID" ]] && start_background qemu/pidstat-qemu-stream.txt timeout "$DURATION" pidstat -h -u -w -t -p "$QEMU_PID" 1
else
  record_missing pidstat
fi
if have iostat; then
  start_background block/iostat-stream.txt timeout "$DURATION" iostat -xmdz -p ALL 1
else
  record_missing iostat
fi
if have sar; then
  start_background network/sar-network-stream.txt timeout "$DURATION" sar -n DEV,EDEV,SOCK,TCP,ETCP 1
  start_background cpu/sar-cpu-stream.txt timeout "$DURATION" sar -q -u ALL -w 1
  start_background cpu/sar-memory-stream.txt timeout "$DURATION" sar -r -B -W 1
else
  record_missing sar
fi

start_background fc/fc-statistics-stream.txt timeout "$DURATION" bash -c '
  while true; do
    date -u +%Y-%m-%dT%H:%M:%S.%NZ
    for h in /sys/class/fc_host/host*; do
      echo "===== $h ====="
      grep -H . "$h"/statistics/* 2>/dev/null
    done
    sleep '"$INTERVAL"'
  done'

if [[ -n "$IFACE" && -e "/sys/class/net/$IFACE" ]]; then
  start_background network/interface-stream.txt timeout "$DURATION" bash -c '
    while true; do
      date -u +%Y-%m-%dT%H:%M:%S.%NZ
      ip -s -s link show '"$IFACE"'
      if command -v ethtool >/dev/null 2>&1; then
        ethtool -S '"$IFACE"' 2>/dev/null | grep -Ei "drop|discard|error|crc|pause|miss|timeout|reset|overrun|buffer" || true
      fi
      command -v nstat >/dev/null 2>&1 && nstat -az 2>/dev/null | grep -Ei "Retrans|Timeout|Abort|ListenDrop|Prune|InErr|OutDiscards" || true
      sleep '"$INTERVAL"'
    done'
fi

if [[ -n "$QEMU_PID" ]]; then
  start_background qemu/thread-stream.txt timeout "$DURATION" bash -c '
    while true; do
      date -u +%Y-%m-%dT%H:%M:%S.%NZ
      ps -T -p '"$QEMU_PID"' -o pid,tid,psr,pcpu,stat,comm,wchan:32
      sleep '"$INTERVAL"'
    done'
  if [[ -n "${CGROUP_PATH:-}" ]]; then
    start_background qemu/cgroup-stream.txt timeout "$DURATION" bash -c '
      while true; do
        date -u +%Y-%m-%dT%H:%M:%S.%NZ
        for f in cpu.stat cpu.pressure memory.current memory.events memory.pressure io.stat io.pressure; do
          echo "===== $f ====="
          cat '"$CGROUP_PATH"'/$f 2>/dev/null || true
        done
        sleep '"$INTERVAL"'
      done'
  fi
fi

if [[ -n "$PXCTL" && -n "$PX_VOLUME" ]]; then
  start_background portworx/volume-stream.txt timeout "$DURATION" bash -c '
    while true; do
      date -u +%Y-%m-%dT%H:%M:%S.%NZ
      timeout 30 '"$PXCTL"' volume stats '"$PX_VOLUME"' || true
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

# Final snapshots for counter deltas.
run_capture cpu/pressure-cpu-after.txt cat /proc/pressure/cpu
run_capture cpu/pressure-memory-after.txt cat /proc/pressure/memory
run_capture cpu/pressure-io-after.txt cat /proc/pressure/io
run_capture cpu/interrupts-after.txt cat /proc/interrupts
run_capture cpu/softirqs-after.txt cat /proc/softirqs
run_capture cpu/schedstat-after.txt cat /proc/schedstat
run_capture block/diskstats-after.txt cat /proc/diskstats
run_shell fc/fc-statistics-after.txt 'for h in /sys/class/fc_host/host*; do echo "===== $h ====="; grep -H . "$h"/statistics/* 2>/dev/null; done'
run_capture network/ip-link-after.txt ip -s -s link show
have nstat && run_capture network/nstat-after.txt nstat -az || true
if [[ -n "$IFACE" && -e "/sys/class/net/$IFACE" ]]; then
  run_capture network/interface-after.txt ip -s -s link show "$IFACE"
  have ethtool && run_capture network/ethtool-stats-after.txt ethtool -S "$IFACE" || true
fi
if [[ -n "$QEMU_PID" && -r "/proc/$QEMU_PID/status" ]]; then
  run_capture qemu/status-after.txt cat "/proc/$QEMU_PID/status"
  run_capture qemu/sched-after.txt cat "/proc/$QEMU_PID/sched"
  run_capture qemu/io-after.txt cat "/proc/$QEMU_PID/io"
  run_capture qemu/threads-after.txt ps -T -p "$QEMU_PID" -o pid,tid,psr,pcpu,stat,comm,wchan:32
  [[ -n "${CGROUP_PATH:-}" ]] && run_shell qemu/cgroup-after.txt "for f in cpu.stat cpu.pressure memory.current memory.events memory.pressure io.stat io.pressure; do echo =====\$f=====; cat '$CGROUP_PATH'/\$f 2>/dev/null || true; done"
fi
if [[ -n "$PXCTL" ]]; then
  timeout 30 "$PXCTL" alerts show > "$OUT_DIR/portworx/alerts-after.txt" 2>&1 || true
  timeout 30 "$PXCTL" service pool show > "$OUT_DIR/portworx/pools-after.txt" 2>&1 || true
  [[ -n "$PX_VOLUME" ]] && timeout 30 "$PXCTL" volume stats "$PX_VOLUME" > "$OUT_DIR/portworx/volume-stats-after.txt" 2>&1 || true
fi
have journalctl && run_shell kernel/storage-journal-after.txt "journalctl -k --since '-15 min' | grep -Ei 'scsi|multipath|dm-|qla|lpfc|fc |fibre|abort|timeout|reset|offline|reject|sense|I/O error|oom|stall|lockup|mce|edac'" || true

echo "end_utc=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" >> "$OUT_DIR/run-metadata.txt"
find "$OUT_DIR" -type f -printf '%P\t%s bytes\n' | sort > "$OUT_DIR/manifest.txt"
find "$OUT_DIR" -type f ! -name sha256sums.txt -print0 | sort -z | xargs -0 sha256sum > "$OUT_DIR/sha256sums.txt"

ARCHIVE="${OUT_DIR}.tar.gz"
tar -C "$(dirname "$OUT_DIR")" -czf "$ARCHIVE" "$(basename "$OUT_DIR")"
echo "Capture complete"
echo "Directory: $OUT_DIR"
echo "Archive:   $ARCHIVE"
