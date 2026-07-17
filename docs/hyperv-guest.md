# Hyper-V guest on KVM (day 2)

Manual and semi-automated notes for the Windows L1 guest. The **automated path** is the drop-in CFN pipeline ([DEPLOY-FROM-CFN.md](DEPLOY-FROM-CFN.md)).

**Related:** [Network topology](network-diagram.md) · [Troubleshooting](nested-virt-hiccups.md) · [Security design](SECURITY-EXCEPTIONS.md) (VNC localhost)

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

## 2. Install Windows Server guest (manual example)

Drop-in CFN deploy prefetches `Win2022.iso` automatically (`ensure-lab-image-cache.sh` → Microsoft evaluation CDN by default). For manual installs, ensure the ISO is in `/var/lib/libvirt/images/`.

The repo’s automated provisioner uses **`listen=127.0.0.1`** for VNC (see [SECURITY-EXCEPTIONS.md](SECURITY-EXCEPTIONS.md)). Manual example:

```bash
sudo virt-install \
  --name win-hv-nested \
  --memory 32768 \
  --vcpus 8 \
  --cpu host-passthrough \
  --disk path=/var/lib/libvirt/images/win-hv-nested.qcow2,size=200,bus=virtio \
  --cdrom /var/lib/libvirt/images/Win2022.iso \
  --network bridge=br-default,model=e1000 \
  --os-variant win2k22 \
  --graphics vnc,listen=127.0.0.1,port=5900 \
  --noautoconsole
```

**CPU:** `host-passthrough` exposes VT-x to the guest so Hyper-V can install (production path uses `Cascadelake-Server-noTSX` - hiccup #17).

**Network:** `br-default` - guest gets `10.{SiteId}.1.x`, gateway `10.{SiteId}.1.1`.

**VNC access:** SSH tunnel to the metal host, then connect to `localhost:5900`.

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

For nested Hyper-V on KVM, use `enable-hyperv-nested-host.ps1` after `fix-kvm-nested-hyperv-xml.sh` (see [nested-virt-hiccups.md](nested-virt-hiccups.md#17-windows-boot-loop-after-hyper-v-enable-on-8488c-skylake-cpu-model)).

## 4. Inner VM (nested layer 2)

**Automated path (recommended):** drop-in CFN deploy — see [DEPLOY-FROM-CFN.md](DEPLOY-FROM-CFN.md). L2 issues: [nested-virt-hiccups.md](nested-virt-hiccups.md#18-inner-ubuntu-on-hyper-v-gen2-boot-order-cloud-init-and-image-version).

```bash
./bin/deploy-inner-ubuntu.sh              # both sites (developer workflow)
# or on metal: scripts/deploy-real-l2.sh {site}
```

Creates external vSwitch **`NestedVirt-Lab`**, Ubuntu 24.04 Gen2 VM at `10.{site}.1.20` on Hyper-V.

## 5. Cross-site proof (L2)

```bash
./bin/invoke-routing-proof.sh --layer l2
./bin/invoke-routing-proof.sh --layer all
```

## Troubleshooting

| Symptom | Check |
|---------|--------|
| Hyper-V won't install in guest | `nested=Y`, CPU model, KVM XML (`fix-kvm-nested-hyperv-xml.sh`), hiccup #2 |
| Guest no internet | NAT rule on host for `10.{SiteId}.1.0/24` → `kvm-host-nic0`; guest DNS (hiccup #8) |
| Can't ping peer site lab | `bin/configure-peer-routing.sh`, GRE (hiccup #10) |
| Same IP on both sites | SiteId must differ (0 vs 1); hiccup #11 |

## Demo beat (optional)

1. Show `invoke-routing-proof.sh --layer l0` (VPC transport)
2. Show `--layer l1` (peer bridge gateways)
3. RDP to Windows guest, Hyper-V Manager with inner VM running
4. Inner VM ping across AZ
