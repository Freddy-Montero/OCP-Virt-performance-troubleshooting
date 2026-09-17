# OpenShift Virtualization Performance Troubleshooting

Practical, evidence-driven troubleshooting for storage and I/O performance in OpenShift Virtualization.

This repository contains a two-part troubleshooting series, reusable evidence collectors, and a concise field guide for tracing latency from a virtual machine through OpenShift Virtualization, QEMU, CPU/NUMA, Portworx, networking, Fibre Channel, the SAN fabric, and the storage array.

## Repository layout

```text
openshift-virtualization-performance-troubleshooting/
├── README.md
├── docs/
│   └── troubleshooting-field-guide.md
├── scripts/
│   ├── ocpv_node_performance_capture.sh
│   └── ocpv_oc_performance_capture.sh
├── examples/
│   └── run-manifest.example
├── LICENSE
└── .gitignore
```

## Two-part practical series

OpenShift Virtualization

Storage performance troubleshooting: a two-part practical series

From locating the first latency boundary to synchronized end-to-end evidence collection across the full virtualization and storage stack.


## Source and method

This series expands the uploaded OpenShift Virtualization Storage Performance Troubleshooting Template. It preserves the source runbook's map, baseline, load, correlate, and change methodology, plus its CPU, NUMA, QEMU, cgroup, network, FC, multipath, OpenShift, Portworx, SAN, array, and automated collector coverage.


## Part 1: Finding the first storage latency boundary

Finding the first storage latency boundary in OpenShift Virtualization

A layer-by-layer method for determining whether VM storage latency begins in the guest, QEMU, host CPU, Portworx, the network, Fibre Channel, or the array.


## Why storage latency is an end-to-end problem

An OpenShift Virtualization VM does not issue I/O directly to a storage array. Between an application and persistent media sit the guest operating system, VirtIO, QEMU, virt-launcher, Linux CPU scheduling and cgroups, the worker's storage stack, CSI and PVC/PV objects, Portworx, replication networking, multipath, Fibre Channel HBAs, SAN switches, and the array.

When an application reports 20 ms of storage latency, the array might report 1 ms. Both measurements can be correct. The missing 19 ms exists somewhere above the array. The investigation therefore starts with a different question: where does latency or queue depth first increase?


## The five-step method


## Layer 1: guest latency, IOPS, bandwidth, and queue

Start where the application sees the problem. For Windows, combine DiskSpd with PhysicalDisk counters. For Linux, combine fio with iostat. Record read and write latency separately, average plus p95/p99 latency where available, read/write IOPS, bandwidth, and observed queue.

A SQL-like Windows data test:

```bash
diskspd.exe -c50G -d300 -W30 -b8K -r -w30 -t4 -o8 -Sh -L `
  C:\OCPV-IO-TEST\diskspd-test.dat
```

A comparable Linux test:

```bash
fio --name=sql-data --filename=/mnt/test/fio.dat --size=50G \
 --direct=1 --ioengine=libaio --rw=randrw --rwmixread=70 --bs=8k \
 --iodepth=32 --numjobs=4 --runtime=300 --ramp_time=30 --time_based \
 --group_reporting --lat_percentiles=1
```

Configured queue depth represents demand. Observed queue length and await represent backlog. Keep this distinction throughout the investigation.


## Layer 2: map the OpenShift storage objects

Before moving below the guest, resolve the Kubernetes objects. A VM disk name alone is not enough. Record the VM and VMI, virt-launcher pod, worker, DataVolume when present, PVC, PV, StorageClass, CSI driver, volume handle, VolumeAttachment, and Portworx volume.

```bash
oc get vm "$VM" -n "$NS" -o wide
oc get vmi "$VM" -n "$NS" -o wide
oc get pod -n "$NS" -l kubevirt.io=virt-launcher,vm.kubevirt.io/name="$VM" -o wide

PV=$(oc get pvc "$PVC" -n "$NS" -o jsonpath='{.spec.volumeName}')
PXVOL=$(oc get pv "$PV" -o jsonpath='{.spec.csi.volumeHandle}')

oc get pvc "$PVC" -n "$NS" -o yaml
oc get pv "$PV" -o yaml
oc get storageclass -o wide
oc get volumeattachment -o wide
printf 'PV=%s\nPXVOL=%s\n' "$PV" "$PXVOL"
```

Also review namespace and node events around the test. Attach failures, pod restarts, node pressure, CSI errors, migration activity, or storage operator events can explain intermittent latency without a sustained storage bottleneck.

```bash
oc get events -n "$NS" --sort-by=.lastTimestamp
oc describe vmi "$VM" -n "$NS"
oc describe pod "$POD" -n "$NS"
oc describe node "$NODE"
```


## Layer 3: QEMU and the active VM configuration

The VM YAML describes requested configuration. Active libvirt XML proves what QEMU is running. Inspect disk drivers, queue configuration, I/O threads, CPU pinning, emulator placement, and disk-to-thread mapping after every relevant VM restart.

```bash
oc exec -n "$NS" -c compute "$POD" -- virsh dumpxml 1 > "$VM"-active.xml
oc exec -n "$NS" -c compute "$POD" -- virsh dumpxml 1 | \
 egrep -n 'iothread|<disk|<driver|vcpupin|emulatorpin|iothreadpin'
oc exec -n "$NS" -c compute "$POD" -- virsh domstats 1 --block
```

Then observe QEMU under load. One I/O thread near 100% CPU while guest latency rises and lower storage layers remain quiet is strong evidence of a virtualization-side boundary.

```bash
ps -eo pid,tid,psr,pcpu,comm,args | grep '[q]emu' | grep "$VM"
QEMU_PID=<pid>
pidstat -t -p "$QEMU_PID" 2
```


## Layer 4: CPU, NUMA, and cgroups

Storage performance can become CPU performance. QEMU must schedule vCPU, emulator, and I/O-thread work. CPU contention, NUMA locality, interrupt pressure, or cgroup throttling can add latency before an I/O request reaches Portworx or Fibre Channel.

```bash
lscpu -e
lscpu
numactl --hardware
numastat
mpstat -P ALL 1
vmstat 1
cat /proc/interrupts
cat /proc/softirqs
cat /proc/pressure/cpu
cat /proc/pressure/memory
cat /proc/pressure/io
```

Compare QEMU thread CPU placement with NUMA topology and interrupt activity. Look for overloaded CPUs, high run queues, remote-memory exposure, CPU pressure, and storage or network IRQ concentration.

Inside the compute container, compare cgroup counters before and after the workload:

```bash
oc exec -n "$NS" -c compute "$POD" -- cat /sys/fs/cgroup/cpu.stat
oc exec -n "$NS" -c compute "$POD" -- cat /sys/fs/cgroup/io.stat
oc exec -n "$NS" -c compute "$POD" -- cat /sys/fs/cgroup/cpu.pressure
oc exec -n "$NS" -c compute "$POD" -- cat /sys/fs/cgroup/io.pressure
```

Growth in throttling counters during the test means the storage benchmark is also measuring a CPU limit. CPU pressure or a saturated QEMU thread with low downstream storage demand points the investigation upward, not toward the SAN.


## Layer 5: Portworx and the replica path

```bash
pxctl status
pxctl cluster provision-status
pxctl cluster list
pxctl service pool show
pxctl alerts show
pxctl volume inspect "$PXVOL"
pxctl volume stats "$PXVOL"
```

Record the attachment node, replica nodes, pools, cloud-drive devices, replica state, rebuilds, resynchronization, and available volume statistics. For replicated writes, inspect both the local storage path and the peer Ethernet path. Good reads with poor writes often justify closer inspection of synchronous replication and the slower required replica.


## Layer 6: NICs and the Portworx replication network

Resolve the interface from routing instead of assuming the management NIC carries storage replication.

```bash
ip route get "$PEER"
ip -details link show "$PX_INTERFACE"
ip -s -s link show "$PX_INTERFACE"
ethtool "$PX_INTERFACE"
ethtool -S "$PX_INTERFACE"
ethtool -g "$PX_INTERFACE"
ethtool -l "$PX_INTERFACE"
tc -s qdisc show dev "$PX_INTERFACE"
sar -n DEV,EDEV 1
nstat -az | egrep -i 'Retrans|ListenDrop|Timeout|Abort|Prune'
```

Look for drops, pause frames, retransmits, ring pressure, queue imbalance, link negotiation problems, or one bond member carrying most traffic. These symptoms matter even when FC is healthy because replicated writes can traverse Ethernet before completion.


## Layer 7: FC/HBA and multipath

for host in /sys/class/fc_host/host*; do
  echo "=== $host ==="
  for f in port_name node_name port_state speed supported_speeds; do
    printf '%-20s ' "$f"; cat "$host/$f"
  done
done

multipath -ll "$WWID"
multipathd show paths
multipathd show maps status
iostat -xmdz 1

Compare per-path activity, r_await and w_await, queue depth, HBA speed, link state, and FC error deltas. An increasing invalid CRC, invalid transmission word, link failure, loss-of-signal, or loss-of-sync counter during the test is more useful than a large lifetime count that never changes.


## Layer 8: SAN and array

On Cisco MDS, collect host-facing, ISL, and array-facing ports from both fabrics. Compare input/output rates, TxWait/RxWait where supported, credit behavior, discards, CRCs, resets, and optics. A fabric can be latency-bound by credits or slow drain without reaching its average bandwidth ceiling.

```bash
show clock
show flogi database
show fcns database
show interface fcX/Y
show interface fcX/Y counters detailed
show interface fcX/Y transceiver details
show logging logfile
show port-monitor
```

At the array, capture host, volume, and front-end port latency, IOPS, bandwidth, and queue/load in the exact same interval. High guest latency with low array latency places the delay above the array. Rising array latency at the same time shows the back end is participating.


## Reading the first boundary


## What Part 1 should leave you with

At the end of the first investigation, you should have a verified I/O path and a defensible boundary. You might not yet know the root cause, but you should know whether the first meaningful symptom appears in the guest/QEMU/CPU domain, Portworx and its replication network, host FC/multipath, the SAN fabric, or the array. Part 2 turns this method into a synchronized end-to-end performance experiment.


## Part 2: Advanced end-to-end storage performance testing

Advanced end-to-end storage performance testing in OpenShift Virtualization

How to run a synchronized 330-second experiment across the guest, OpenShift, QEMU, CPU/NUMA, Portworx, NICs, FC, SAN, and array.


## Move from troubleshooting to an experiment

Once Part 1 identifies a likely boundary, the next step is deeper correlation. The advanced test uses one disposable disk, one fixed workload, one VM placement, one UTC run identifier, and collectors running at every relevant layer. The objective is to prove how demand propagates through the stack.


## Build the run manifest first

```bash
export NS="<vm-namespace>"
export VM="<vm-name>"
export PVC="<disposable-test-pvc>"
export NODE="<vm-worker-node>"
export PXVOL="<portworx-volume-id>"
export PEER="<replica-peer-ip>"
export WWID="<multipath-wwid>"
export FC_PORT="fcX/Y"

RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)-storage-test
echo "$RUN_ID"
```

Record VM generation, worker, pod, PVC, PV, volume handle, StorageClass, Portworx volume and replicas, WWIDs, HBA WWPNs, MDS ports, array host group and volumes, test command, file size, queue depth, thread count, and exact UTC start/end time.


## Collect OpenShift state and metrics

Capture both object configuration and runtime state. This provides the control-plane context for the performance data and catches changes such as migration, restart, scheduling, attachment, node pressure, or operator events.

```bash
oc get vm "$VM" -n "$NS" -o yaml
oc get vmi "$VM" -n "$NS" -o yaml
oc get pod "$POD" -n "$NS" -o yaml
oc get pvc "$PVC" -n "$NS" -o yaml
oc get pv "$PV" -o yaml
oc get storageclass "$STORAGE_CLASS" -o yaml
oc get volumeattachment -o yaml
oc describe node "$NODE"
oc get events -A --sort-by=.lastTimestamp
```

Where the cluster monitoring stack exposes the data, collect node CPU, memory, filesystem, network, pod/container CPU, throttling, and relevant storage metrics for the same interval. Keep raw metric timestamps so you can align them with guest and SAN evidence.

```bash
oc adm top node "$NODE"
oc adm top pod -n "$NS" --containers
oc get --raw /metrics >/tmp/apiserver-metrics.txt 2>/dev/null || true
```

For deeper monitoring queries, use the cluster's supported monitoring interfaces and PromQL appropriate to the installed release. The source runbook emphasizes capturing OpenShift metrics and events, rather than relying on one fixed metric name across releases.


## Capture CPU, memory, NUMA, IRQ, and pressure continuously

```bash
mpstat -P ALL 1
pidstat -durwt 1
vmstat 1
sar -u -r -B -W -q 1
numastat
cat /proc/interrupts
cat /proc/softirqs
cat /proc/pressure/cpu
cat /proc/pressure/memory
cat /proc/pressure/io
```

CPU evidence answers whether QEMU receives enough execution time. Memory and pressure data show reclaim or paging. NUMA data shows topology and locality. IRQ and softirq data expose CPUs servicing HBA and NIC interrupts. Correlate these with QEMU thread placement instead of reading them independently.


## Capture QEMU and cgroups as a single layer

QEMU_PID=<pid>
pidstat -t -p "$QEMU_PID" 1

cat /proc/$QEMU_PID/status
cat /proc/$QEMU_PID/io
taskset -pc "$QEMU_PID"

oc exec -n "$NS" -c compute "$POD" -- cat /sys/fs/cgroup/cpu.stat
oc exec -n "$NS" -c compute "$POD" -- cat /sys/fs/cgroup/io.stat

Take cgroup snapshots before and after the workload, and keep per-thread pidstat running during it. This lets you distinguish a QEMU I/O-thread ceiling from container throttling, host CPU contention, or downstream storage latency.


## Capture Portworx volume, pool, and replica behavior

timeout 330 bash -c '
while true; do
  date -Ins
  pxctl volume stats '"$PXVOL"'
  sleep 5
done
' | tee px-volume-stats-"$PXVOL".log

pxctl service pool show
pxctl alerts show
pxctl cluster provision-status
pxctl volume inspect "$PXVOL"

Match replica state, pool utilization, volume I/O, pending I/O, and rebuild/resync activity to the steady-state workload interval. If write latency appears at Portworx before FC latency rises, inspect the replica network and each replica node before tuning the guest.


## Capture NICs, queues, bonds, and transport symptoms

timeout 330 sar -n DEV,EDEV 1 | tee sar-network-"$NODE".log
ip -s -s link show "$PX_INTERFACE"
ethtool -S "$PX_INTERFACE"
ethtool -g "$PX_INTERFACE"
ethtool -l "$PX_INTERFACE"
ethtool -a "$PX_INTERFACE"
tc -s qdisc show dev "$PX_INTERFACE"
cat /proc/net/bonding/"$PX_INTERFACE" 2>/dev/null || true
nstat -az

Do not stop at throughput. Capture drops, errors, pause behavior, ring/channel configuration, qdisc state, TCP retransmits, and bond-member balance. A 25/40/100 Gb link with low average utilization can still show queue or loss behavior that affects synchronous writes.


## Capture block, SCSI, multipath, and FC/HBA together

timeout 330 iostat -xmdz 1 | tee iostat-"$NODE".log
multipath -ll "$WWID"
multipathd show paths
multipathd show maps status
lsblk -o NAME,KNAME,TYPE,SIZE,HCTL,WWN,MODEL,VENDOR
lsscsi -t

for d in /sys/block/sd*; do
  echo "=== $d ==="
  cat "$d/device/queue_depth" 2>/dev/null
done

Block-layer await and aqu-sz show host backlog. Multipath shows path health and policy. SCSI queue depth exposes host-side constraints. FC counters show link-facing behavior. Read them as one path.

timeout 330 bash -c '
while true; do
  date -Ins
  for host in /sys/class/fc_host/host*; do
    echo "=== $host ==="
    grep -H . "$host"/statistics/* 2>/dev/null
  done
  sleep 5
done
' | tee fc-hba-"$NODE".log


## Capture the SAN at multiple points

Do not collect one switch port and call it fabric telemetry. Resolve the host HBA WWPNs and array target WWPNs, then capture both fabrics, every host-facing port, traversed ISL or port-channel member, and every relevant array-facing port.

terminal length 0
show clock
show flogi database
show fcns database
show interface fcX/Y
show interface fcX/Y counters detailed
show interface fcX/Y transceiver details
show port-monitor
show logging logfile

Capture starting counters, mid-run counters, and final counters. Use deltas for credits, waits, CRCs, discards, resets, and other cumulative values. Trace TxWait toward the downstream egress rather than treating it as a generic fabric alarm.


## Capture the array in the same window

Filter array telemetry to the Portworx host or host group and exact cloud-drive volumes from the path map. Record array-wide latency/load, host latency/IOPS/bandwidth, volume latency/IOPS/bandwidth, and front-end target-port activity. A single slow required path can dominate replicated write completion.


## Use a strict synchronized timeline


## Run controlled A/B tests

Only change settings after the baseline proves which boundary needs testing. Keep guest file size, block size, read/write mix, total outstanding I/O, duration, VM worker, and storage placement stable.

Diagnostic storage variants must use disposable data and vendor-supported parameters. A faster repl=1 test isolates replication cost. It does not establish repl=1 as a production design recommendation.


## A baseline VM profile to test

cpu:
  dedicatedCpuPlacement: false
  isolateEmulatorThread: false

ioThreadsPolicy: supplementalPool

ioThreads:
  supplementalPoolThreadCount: <io-thread-count>

devices:
  blockMultiQueue: true

Select the starting I/O-thread count from VM disk count, workload concurrency, vCPU count, and available host CPU. Verify active XML and per-thread CPU. Scale only after measurements show the configured threads are the ceiling.


## Automate the collection

The source runbook includes two read-only collector roles. The node collector runs on the VM attachment node and each relevant Portworx replica node. The oc collector runs from an authenticated administrative workstation.

sudo ./ocpv_node_performance_capture.sh \
 --vm "$VM" --peer "$PEER" --wwid "$WWID" --px-volume "$PXVOL" \
 --duration 330 --interval 5 --run-id "$RUN_ID"

./ocpv_oc_performance_capture.sh \
 --namespace "$NS" --vm "$VM" --pvc "$PVC" \
 --duration 330 --interval 5 --run-id "$RUN_ID"

Keep support-heavy collections such as inspect or must-gather outside the timed workload window when their API or storage overhead might contaminate the benchmark.


## Package evidence so someone else can reproduce your conclusion

date -u +'%Y-%m-%dT%H:%M:%S.%NZ' | tee "$EVIDENCE/end-utc.txt"
find "$EVIDENCE" -type f -printf '%P\t%s bytes\n' | sort > "$EVIDENCE/manifest.txt"
sha256sum $(find "$EVIDENCE" -type f -print) > "$EVIDENCE/sha256sums.txt"
tar -C "$(dirname "$EVIDENCE")" -czf "$RUN_ID-evidence.tar.gz" "$(basename "$EVIDENCE")"

The escalation package should include VM YAML, active XML, workload output, guest counters, QEMU and cgroup data, CPU/NUMA/IRQ evidence, OpenShift objects and events, PVC/PV/CSI mapping, Portworx volume and pool data, NIC and bond counters, iostat, multipath, FC/HBA deltas, MDS snapshots from both fabrics, and array host/volume/port exports.


## The end-to-end interpretation rule

Do not choose the busiest component. Follow the same I/O demand through time. Find the first layer where latency rises, queue accumulates, throughput flattens, an error counter grows, or a required path diverges from its peers. Then validate that boundary with one controlled change.

This approach also prevents common false conclusions. High Linux device busy time does not equal array saturation. Low FC bandwidth does not prove the fabric is healthy. A high lifetime CRC count does not prove errors occurred during the test. More QEMU I/O threads do not fix a slow replica path. A fast array does not rule out latency elsewhere in the I/O chain.


## Suggested publishing split


## References to validate before publication

Red Hat OpenShift documentation: https://docs.redhat.com/en/documentation/openshift_container_platform/

Portworx Enterprise documentation and pxctl reference: https://docs.portworx.com/

Microsoft DiskSpd: https://github.com/microsoft/diskspd

Microsoft Windows performance tuning documentation: https://learn.microsoft.com/windows-server/administration/performance-tuning/

Cisco MDS 9000 NX-OS documentation: https://www.cisco.com/c/en/us/support/storage-networking/mds-9000-nx-os-san-os-software/series.html

## Included collectors

The node-side collector captures host identity, CPU and NUMA state, pressure metrics, interrupts, QEMU process and cgroup evidence, NIC statistics, Fibre Channel/HBA data, multipath state, block-device metrics, Portworx information, and kernel evidence.

The OpenShift collector resolves the VM, VMI, virt-launcher pod, worker node, PVC, PV, CSI handle, StorageClass, VolumeAttachment, virtualization logs, node metrics, events, active libvirt XML, cgroup state, and Portworx Kubernetes resources.

Use the same UTC run ID across both collectors and any guest, MDS, and array captures. This makes cross-layer correlation much easier.

## Quick start

```bash
chmod +x scripts/*.sh

RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)-storage-test

./scripts/ocpv_oc_performance_capture.sh \
  --namespace <namespace> \
  --vm <vm-name> \
  --pvc <test-pvc> \
  --duration 330 \
  --run-id "$RUN_ID"

sudo ./scripts/ocpv_node_performance_capture.sh \
  --vm <vm-name> \
  --peer <portworx-replica-peer-ip> \
  --wwid <multipath-wwid> \
  --px-volume <portworx-volume-id> \
  --duration 330 \
  --run-id "$RUN_ID"
```

Start the collectors before the workload. Keep the VM on the same worker. Use one disposable test disk and one fixed workload. Change one variable per comparison.

## Field guide

For a shorter operational reference, see `docs/troubleshooting-field-guide.md`. It condenses the longer troubleshooting template into the path-mapping workflow, evidence matrix, command groups, interpretation patterns, and controlled-test rules.

## Safety

Do not run destructive raw-write tests against production PVCs, imported VMDKs, Portworx cloud-drive LUNs, or devices containing data. Use a newly provisioned disposable PVC and a test file inside the guest filesystem.

Validate commands and metrics against the OpenShift, OpenShift Virtualization, Portworx, operating system, SAN, and storage versions installed in your environment.

## License

Add the license appropriate for your organization before publishing. The included `LICENSE` file is a placeholder.