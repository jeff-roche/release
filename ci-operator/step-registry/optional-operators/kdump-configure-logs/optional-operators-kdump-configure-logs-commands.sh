#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

node_role=${APPLY_NODE_ROLE:=worker}
log_path=${LOG_PATH:="/var/crash"}
infra_status=$(oc get infrastructures.config.openshift.io cluster -ojsonpath='{.status.controlPlaneTopology}') # Check if this is SNO

echo "Creating kdump configuration"
kdump_conf=$(cat <<EOF | base64 -w 0
path $log_path
core_collector makedumpfile -l --message-level 7 -d 31
EOF
)

echo "Creating kdump sysconfig"
kdump_sysconfig=$(cat <<EOF | base64 -w 0
KDUMP_COMMANDLINE_REMOVE="hugepages hugepagesz slub_debug quiet log_buf_len swiotlb"
KDUMP_COMMANDLINE_APPEND="irqpoll nr_cpus=1 reset_devices cgroup_disable=memory mce=off numa=off udev.children-max=2 panic=10 rootflags=nofail acpi_no_memhotplug transparent_hugepage=never nokaslr novmcoredd hest_disable"
KEXEC_ARGS="-s"
KDUMP_IMG="vmlinuz"
EOF
)

echo "Configuring kernel dumps on $node_role nodes"
oc create -f - <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: $node_role
  name: 99-$node_role-kdump
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
        - contents:
            source: data:text/plain;charset=utf-8;base64,${kdump_conf}
          mode: 420
          overwrite: true
          path: /etc/kdump.conf
        - contents:
            source: data:text/plain;charset=utf-8;base64,${kdump_sysconfig}
          mode: 420
          overwrite: true
          path: /etc/sysconfig/kdump
    systemd:
      units:
        - enabled: true
          name: kdump.service
  kernelArguments:
    - crashkernel=256M
EOF

echo "waiting for mcp/${node_role} condition=Updating timeout=5m"
oc wait mcp/${node_role} --for condition=Updating --timeout=5m

# When applying this configuration to the master node for single node
# we need to wait for the master node to restart before we attempt to call out to the API Server
if [[ "$node_role" == "master" && $infra_status == "SingleReplica" ]]; then
  seconds=600
  echo "master node is updating, waiting $seconds seconds for master node to restart"
  sleep $seconds
fi

# If the nodes come back up, kdump must have been configured correctly
echo "waiting for mcp/${node_role} condition=Updated timeout=30m"
oc wait mcp/${node_role} --for condition=Updated --timeout=30m
