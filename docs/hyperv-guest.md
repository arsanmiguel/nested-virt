# Hyper-V guest on KVM (day 2)

Host bootstrap leaves you with:

- Nested KVM enabled (`nested=1`)
- `br-default` at `10.{SiteId}.1.1/24` (Default lab switch mirror)
- NAT for `10.{SiteId}.1.0/24` via `kvm-host-nic0`
- VM disk path: `/var/lib/libvirt/images`

## 1. Confirm host ready

```bash
grep PHASE=BOOTSTRAP /var/log/amazon/launch-timing.log | tail -5
cat /sys/module/kvm_intel/parameters/nested   # Y
virt-host-validate qemu
virsh list --all
```

## 2. Install Windows Server guest (example)

Use a Windows Server 2022 ISO in `/var/lib/libvirt/images/`. Example virt-install:

```bash
sudo virt-install \
  --name win-hv-nested \
  --memory 32768 \
  --vcpus 8 \
  --cpu host-passthrough \
  --disk path=/var/lib/libvirt/images/win-hv-nested.qcow2,size=200,bus=virtio \
  --cdrom /var/lib/libvirt/images/Win2022.iso \
  --network bridge=br-default,model=virtio \
  --os-variant win2k22 \
  --graphics vnc,listen=0.0.0.0 \
  --noautoconsole
```

**CPU:** `host-passthrough` exposes VT-x to the guest so Hyper-V can install.

**Network:** `br-default` — guest gets `10.{SiteId}.1.x`, gateway `10.{SiteId}.1.1`.

## 3. Enable Hyper-V inside the guest

In the Windows guest (Server with Desktop Experience or via PowerShell):

```powershell
Install-WindowsFeature Hyper-V -IncludeManagementTools -Restart
```

After reboot, confirm:

```powershell
Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V
systeminfo | findstr /i hyper
```

## 4. Inner VM (nested layer 2)

**Automated path (recommended):** see [BUILD.md](BUILD.md) phase 4.

```bash
./deploy-inner-ubuntu.sh              # both sites
# or on metal: scripts/deploy-real-l2.sh {site}
```

Creates external vSwitch **`NestedVirt-Lab`**, Ubuntu 24.04 Gen2 VM at `10.{site}.1.20` on Hyper-V.

## 5. Cross-site proof (L2)

```bash
./invoke-routing-proof.sh --layer l2
./invoke-routing-proof.sh --layer all
```

Topology: [network-diagram.md](network-diagram.md). Triage: [nested-virt-hiccups.md](nested-virt-hiccups.md).

## Troubleshooting

| Symptom | Check |
|---------|--------|
| Hyper-V won't install in guest | `nested=Y`, CPU mode `host-passthrough`, enough vCPUs/RAM |
| Guest no internet | NAT rule on host for `10.{SiteId}.1.0/24` → `kvm-host-nic0` |
| Can't ping peer site lab | `configure-peer-routing.sh`, tags `PeerTransportEniIp` / `PeerLabSupernet` |
| Same IP on both sites | SiteId must differ (0 vs 1) |

## re:Invent demo beat

1. Show `invoke-routing-proof.sh --layer l0` (VPC transport)
2. Show `--layer l1` (peer bridge gateways)
3. RDP to Windows guest, Hyper-V Manager with inner VM running
4. Inner VM ping across AZ — the money shot
