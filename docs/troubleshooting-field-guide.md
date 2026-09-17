# OpenShift Virtualization Performance Troubleshooting Field Guide

This field guide provides a compact workflow for locating storage and I/O performance boundaries in OpenShift Virtualization. It covers Windows or Linux guests, KubeVirt/QEMU, worker CPU and NUMA, cgroups, Portworx, Ethernet, Fibre Channel, multipath, Cisco MDS, and the storage array.

## Core method

Use the same five-step method for every test:

1. Map the exact I/O path from guest disk to PVC, PV, CSI volume, Portworx volume, replica/pool, host device, HBA, SAN port, and array LUN or volume.
2. Baseline idle counters for 30 to 60 seconds.
3. Load one disposable test disk with a repeatable workload.
4. Correlate the same UTC time window at every layer.
5. Change one variable and repeat the identical test.

The goal is to identify the first layer where latency rises, queue depth grows, throughput flattens, errors increase, or a compute resource saturates.

## Evidence map

| Layer | Primary evidence | Common boundary signal |
| --- | --- | --- |
| Guest | DiskSpd or fio, PerfMon or iostat | Guest latency/queue rises while lower layers remain quiet |
| OpenShift/KubeVirt | VM/VMI/pod, events, active libvirt XML | Restart, migration, attachment, scheduling, or configuration issue |
| QEMU | pidstat, thread CPU, domstats, active XML | I/O thread or emulator thread saturates |
| CPU/NUMA/cgroups | mpstat, vmstat, PSI, numastat, cpu.stat | Run queue, pressure, remote NUMA access, or throttling |
| Portworx | pxctl volume/pool/node state | Replica, pool, rebuild, or volume pressure |
| Ethernet | ip, ethtool, sar, nstat | Drops, pause frames, retransmits, queue imbalance |
| FC/multipath | iostat, multipath, sysfs FC counters | Await rises, path imbalance, CRC/link errors |
| Cisco MDS | interface counters/rates | TxWait/RxWait, credit pressure, discards, CRCs |
| Array | host/volume/front-end metrics | Array latency or queue rises in the same interval |

## Map the VM and storage path

```bash
export NS="<vm-namespace>"
export VM="<vm-name>"
export PVC="<disposable-test-pvc>"

oc get vm "$VM" -n "$NS" -o wide
oc get vmi "$VM" -n "$NS" -o wide

POD=$(oc get pod -n "$NS"   -l kubevirt.io=virt-launcher,vm.kubevirt.io/name="$VM"   -o jsonpath='{.items[0].metadata.name}')

NODE=$(oc get vmi "$VM" -n "$NS" -o jsonpath='{.status.nodeName}')
PV=$(oc get pvc "$PVC" -n "$NS" -o jsonpath='{.spec.volumeName}')
PXVOL=$(oc get pv "$PV" -o jsonpath='{.spec.csi.volumeHandle}')

printf 'POD=%s\nNODE=%s\nPV=%s\nPXVOL=%s\n' "$POD" "$NODE" "$PV" "$PXVOL"
```

Record the StorageClass, VolumeAttachment, Portworx replica nodes and pools, multipath WWIDs, HBA WWPNs, MDS ports, and array objects before testing.

## Validate the active VM configuration

Do not rely only on the VM YAML. Active libvirt XML shows what QEMU is using.

```bash
oc exec -n "$NS" -c compute "$POD" -- virsh dumpxml 1 > "$VM-active.xml"

oc exec -n "$NS" -c compute "$POD" -- virsh dumpxml 1 |   egrep -n 'iothread|<disk|<driver|vcpupin|emulatorpin|iothreadpin'

oc exec -n "$NS" -c compute "$POD" -- virsh domstats 1 --block
```

Verify disk bus and driver settings, block multiqueue, I/O-thread count and mapping, CPU pinning, emulator placement, and active disk mappings.

## CPU, memory, NUMA, and QEMU

```bash
lscpu
lscpu -e
numactl --hardware
numastat
mpstat -P ALL 1
vmstat 1
cat /proc/pressure/cpu
cat /proc/pressure/memory
cat /proc/pressure/io
cat /proc/interrupts
cat /proc/softirqs
```

For QEMU:

```bash
ps -eo pid,tid,psr,pcpu,comm,args | grep '[q]emu'
pidstat -t -p <qemu-pid> 2
```

For the compute container:

```bash
oc exec -n "$NS" -c compute "$POD" -- cat /sys/fs/cgroup/cpu.stat
oc exec -n "$NS" -c compute "$POD" -- cat /sys/fs/cgroup/io.stat
oc exec -n "$NS" -c compute "$POD" -- cat /sys/fs/cgroup/cpu.pressure
oc exec -n "$NS" -c compute "$POD" -- cat /sys/fs/cgroup/io.pressure
```

A saturated QEMU thread or growing cgroup throttling with low downstream storage demand points toward a virtualization or compute boundary.

## Portworx

```bash
pxctl status
pxctl cluster provision-status
pxctl cluster list
pxctl service pool show
pxctl alerts show
pxctl volume inspect "$PXVOL"
pxctl volume stats "$PXVOL"
```

Record attachment node, replica nodes, pools, cloud-drive devices, replica health, rebuilds, resynchronization, and volume statistics.

## Ethernet and Portworx replication

Resolve the actual path instead of assuming which NIC carries replication traffic.

```bash
ip route get "$PEER"
ip -s -s link show "$PX_INTERFACE"
ethtool "$PX_INTERFACE"
ethtool -S "$PX_INTERFACE"
ethtool -g "$PX_INTERFACE"
ethtool -l "$PX_INTERFACE"
tc -s qdisc show dev "$PX_INTERFACE"
sar -n DEV,EDEV 1
nstat -az
```

Look for drops, pause frames, retransmits, ring pressure, queue imbalance, bond imbalance, or link negotiation problems.

## Fibre Channel and multipath

```bash
for host in /sys/class/fc_host/host*; do
  echo "=== $host ==="
  for f in port_name node_name port_state speed supported_speeds; do
    printf '%-20s ' "$f"
    cat "$host/$f"
  done
done

multipath -ll "$WWID"
multipathd show paths
multipathd show maps status
iostat -xmdz 1
```

Focus on counter deltas during the test. New CRC, invalid transmission word, link failure, loss-of-signal, or loss-of-sync events matter more than static lifetime totals.

## Cisco MDS

Capture host-facing, ISL, and array-facing ports on both fabrics.

```text
show clock
show flogi database
show fcns database
show interface fcX/Y
show interface fcX/Y counters detailed
show interface fcX/Y transceiver details
show logging logfile
show port-monitor
```

Correlate port rates, TxWait/RxWait where available, credit behavior, discards, CRCs, resets, and optics with the exact workload window.

## Guest workload

Use a disposable test file or test filesystem. Keep block size, read/write mix, queue depth, thread count, duration, file size, and VM placement identical across A/B runs.

Example Linux workload:

```bash
fio --name=sql-data --filename=/mnt/test/fio.dat --size=50G   --direct=1 --ioengine=libaio --rw=randrw --rwmixread=70 --bs=8k   --iodepth=32 --numjobs=4 --runtime=300 --ramp_time=30 --time_based   --group_reporting --lat_percentiles=1
```

Capture read/write latency, p95/p99 where available, IOPS, bandwidth, observed queue, and CPU utilization.

## Interpret the first boundary

| Evidence | Investigate next |
| --- | --- |
| Guest latency rises, QEMU thread saturates, storage stays quiet | QEMU, CPU scheduling, cgroups, NUMA |
| Portworx volume/replica metrics rise, FC stays quiet | Portworx pool, replica, peer Ethernet |
| Multipath await rises, array latency stays low | HBA, pathing, MDS fabric |
| MDS credit pressure or TxWait rises | Downstream congestion or slow drain |
| Array host/volume latency rises with workload | Array front end, volume, or back end |
| Writes degrade much more than reads | Replica path, remote path, or write-sensitive workload |

## Automated collection

Use `scripts/ocpv_oc_performance_capture.sh` from an administrative workstation and `scripts/ocpv_node_performance_capture.sh` on the worker or Portworx replica node. Give both the same `--run-id` and collection duration.

The OpenShift collector gathers cluster, VM/VMI, pod, node, PVC/PV, CSI, StorageClass, VolumeAttachment, events, logs, active domain XML, cgroup data, and Portworx Kubernetes evidence.

The node collector gathers CPU, memory, NUMA, pressure, interrupts, QEMU, cgroups, NICs, FC/HBA, multipath, block I/O, Portworx, and kernel evidence.

## Test discipline

Never change several variables at once. Preserve the same workload and placement for each comparison. Record the exact UTC start and end time. Save before-and-after VM YAML and active XML when configuration changes require a restart.

Never run raw destructive writes against production storage, imported VMDKs, Portworx cloud-drive LUNs, or devices containing data.
