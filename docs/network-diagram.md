# Network diagram

Color-coded map of every network in the **nested-virt** two-AZ lab. Use this with [BUILD.md](BUILD.md) for context and [nested-virt-hiccups.md](nested-virt-hiccups.md) when something breaks.

## Legend (color = network domain)

| Color | Network | CIDR / name | Role |
|-------|---------|-------------|------|
| 🔵 Blue | **AWS VPC fabric** | `172.31.0.0/16` | EC2 primary ENI, IGW, SSM, inter-host transport underlay |
| 🟣 Purple | **Transport ENI subnet** | `/28` per AZ (tag `win-metal-hv-nic-{az}`) | Dedicated uplink for `kvm-host-nic1`; GRE outer header |
| 🟢 Green | **Site 0 lab supernet** | `10.0.0.0/16` | All lab bridges, guests, dnsmasq on site 0 |
| 🟠 Orange | **Site 1 lab supernet** | `10.1.0.0/16` | Same layout, site id `1` |
| 🔴 Red (dashed) | **GRE overlay** | `gre-peer` tunnel | Encapsulates peer lab `10.x/16` inside transport IPs |
| 🩵 Teal | **Hyper-V vSwitch** | `NestedVirt-Lab` (external) | L2 extension of `br-default` inside Windows guest |
| ⚪ Gray | **Management / NAT** | `kvm-host-nic0` (primary ENI) | SSH, SSM, outbound internet; NAT for `10.{site}.1.0/24` |

### Key addresses (site 0 example)

| Address | Device | Notes |
|---------|--------|-------|
| `172.31.x.x` | `kvm-host-nic0` | Public or VPC-routable management |
| `172.31.96.x` | `kvm-host-nic1` | Transport ENI (example: `172.31.96.13`) |
| `10.0.1.1` | `br-default` on metal | Lab gateway, dnsmasq, HTTP serve for inner deploy |
| `10.0.1.10` | Windows KVM guest | Hyper-V host; MAC `52:54:00:10:00:10` |
| `10.0.1.20` | Ubuntu Hyper-V inner | MAC `52:54:00:20:00:20` |

Site 1 mirrors with `10.1.*` and its own transport IP.

---

## End-to-end topology (both AZs)

```mermaid
flowchart TB
  subgraph LEGEND[" "]
    direction LR
    L1["🔵 VPC 172.31.0.0/16"]
    L2["🟣 Transport /28"]
    L3["🟢 Site0 lab 10.0.0.0/16"]
    L4["🟠 Site1 lab 10.1.0.0/16"]
    L5["🔴 GRE gre-peer"]
    L6["🩵 Hyper-V vSwitch"]
    L7["⚪ Mgmt NAT nic0"]
  end

  subgraph AZ0["Availability Zone A — Site 0"]
    direction TB

    subgraph VPC0["🔵 VPC fabric"]
      IGW0[Internet Gateway]
      ENI0_M["⚪ kvm-host-nic0<br/>172.31.x.x<br/>SSH / SSM / NAT"]
      ENI0_T["🟣 kvm-host-nic1<br/>172.31.96.13/28<br/>transport ENI"]
    end

    subgraph METAL0["c7i.metal-48xl — AL2023 host"]
      BR0["🟢 br-default<br/>10.0.1.1/24<br/>dnsmasq + GRE endpoint"]
      GRE0["🔴 gre-peer<br/>local=transport IP<br/>remote=peer transport"]
      BR0 --- GRE0
      GRE0 --- ENI0_T
      ENI0_M --- BR0

      subgraph KVM0["KVM / libvirt"]
        WIN0["Windows Server 2022<br/>win-hv-nested<br/>🟢 10.0.1.10<br/>MAC 52:54:00:10:00:10<br/>e1000 → br-default"]
      end
      BR0 --- WIN0

      subgraph HV0["Hyper-V inside Windows"]
        VSW0["🩵 NestedVirt-Lab<br/>external vSwitch<br/>AllowManagementOS=true"]
        VETH0["vEthernet NestedVirt-Lab<br/>10.0.1.10"]
        INNER0["Ubuntu 24.04 inner<br/>ubuntu-inner Gen2<br/>🟢 10.0.1.20<br/>MAC 52:54:00:20:00:20"]
        VSW0 --- VETH0
        VSW0 --- INNER0
      end
      WIN0 --- VSW0
    end
  end

  subgraph AZ1["Availability Zone B — Site 1"]
    direction TB

    subgraph VPC1["🔵 VPC fabric"]
      ENI1_M["⚪ kvm-host-nic0"]
      ENI1_T["🟣 kvm-host-nic1<br/>172.31.96.x/28"]
    end

    subgraph METAL1["c7i.metal-48xl — AL2023 host"]
      BR1["🟠 br-default<br/>10.1.1.1/24"]
      GRE1["🔴 gre-peer"]
      BR1 --- GRE1
      GRE1 --- ENI1_T

      subgraph KVM1["KVM / libvirt"]
        WIN1["Windows<br/>🟠 10.1.1.10"]
      end
      BR1 --- WIN1

      subgraph HV1["Hyper-V"]
        VSW1["🩵 NestedVirt-Lab"]
        INNER1["Ubuntu inner<br/>🟠 10.1.1.20"]
        VSW1 --- INNER1
      end
      WIN1 --- VSW1
    end
  end

  ENI0_T <-. "🔵 L0: VPC routes transport /32" .-> ENI1_T
  GRE0 <-. "🔴 L1: GRE encap 10.1.0.0/16" .-> GRE1
  GRE1 <-. "🔴 L1: GRE encap 10.0.0.0/16" .-> GRE0
  INNER0 <-. "🟢🟠 L2: cross-site via GRE + bridges" .-> INNER1
```

---

## Single-site detail (Site 0)

```mermaid
flowchart LR
  subgraph INTERNET["Internet / AWS control plane"]
    SSM[SSM / Session Manager]
    IGW[IGW]
  end

  subgraph VPC["🔵 VPC 172.31.0.0/16"]
    NIC0["⚪ kvm-host-nic0<br/>primary ENI"]
    NIC1["🟣 kvm-host-nic1<br/>transport /28"]
  end

  subgraph HOST["Metal host network stack"]
    NAT["iptables MASQUERADE<br/>10.0.1.0/24 → nic0"]
    BR["🟢 br-default 10.0.1.1/24"]
    DNS["dnsmasq<br/>dhcp-host .10 + .20"]
    HTTP["python http.server :8090<br/>VHDX + seed + PS1"]
    GRE["🔴 gre-peer → site1 transport"]
    BR --- DNS
    BR --- HTTP
    BR --- GRE
    NIC1 --- GRE
    NAT --- NIC0
    BR --- NAT
  end

  subgraph KVM["KVM guest L1"]
    direction TB
    W["Windows 10.0.1.10<br/>Cascadelake CPU<br/>vmx + kvm_hidden"]
  end

  subgraph HYPERV["Hyper-V L2"]
    direction TB
    VS["🩵 NestedVirt-Lab external"]
    VE["vEthernet 10.0.1.10"]
    U["Ubuntu 10.0.1.20<br/>virt-customize netplan<br/>cloud-init seed ISO attached"]
    VS --- VE
    VS --- U
  end

  IGW --- NIC0
  SSM --- NIC0
  NIC0 --- NAT
  BR --- W
  W --- VS

  style VPC fill:#dbeafe,stroke:#2563eb
  style BR fill:#dcfce7,stroke:#16a34a
  style GRE fill:#fee2e2,stroke:#dc2626,stroke-dasharray:5
  style VS fill:#ccfbf1,stroke:#0d9488
  style NIC0 fill:#f3f4f6,stroke:#6b7280
  style NIC1 fill:#ede9fe,stroke:#7c3aed
```

---

## Routing layers (what each proof tests)

```mermaid
flowchart TB
  subgraph L0["L0 — Transport underlay 🔵🟣"]
    T0["Site0 kvm-host-nic1"] <-->|"ping bind transport IP"| T1["Site1 kvm-host-nic1"]
  end

  subgraph L1["L1 — Lab supernet via GRE 🔴"]
    G0["10.0.1.1 gateway"] <-->|"GRE encap 10.1.0.0/16"| G1["10.1.1.1 gateway"]
    G0 --- W10["10.0.1.10 Windows"]
    G1 --- W11["10.1.1.10 Windows"]
  end

  subgraph L2["L2 — Nested Hyper-V guest 🩵🟢🟠"]
    W10 --- I0["10.0.1.20 inner"]
    W11 --- I1["10.1.1.20 inner"]
    I0 <-->|"cross-AZ ping"| I1
  end

  L0 --> L1
  L1 --> L2
```

| Layer | Command | Proves |
|-------|---------|--------|
| L0 | `./invoke-routing-proof.sh --layer l0` | Transport ENIs reachable across VPC |
| L1 | `--layer l1` | Remote lab gateway (`10.x.1.1`) via GRE |
| L1 cross | `--layer l1-cross` | Remote Windows guest `.10` |
| L2 | `--layer l2` | Inner Ubuntu `.20` local + cross-site |
| All | `--layer all` | Full matrix |

---

## Additional lab bridges (provisioned, not on critical path)

`bootstrap.sh` creates extra bridges for future chaos / multi-segment demos. Each uses `10.{site}.*`:

| Bridge | Gateway | Purpose |
|--------|---------|---------|
| `br-default` | `10.{site}.1.1/24` | **Primary lab** — Windows + inner |
| `br-production` | `10.{site}.16.1/20` | Production segment |
| `br-dev` | `10.{site}.64.1/19` | Dev segment |
| `br-qa` | `10.{site}.96.1/22` | QA segment |
| `br-backup` | `10.{site}.100.1/24` | Backup segment |
| `br-monitoring` | `10.{site}.101.1/24` | Monitoring |
| `br-heartbeat` | `10.{site}.102.1/24` | Heartbeat |
| `br-cluster` | `10.{site}.250.1/24` | Bound to `kvm-host-nic2` |

Only `br-default` is required for the nested-virt proof stack today.

---

## Packet walk: Site 0 inner → Site 1 inner (L2 cross-site)

1. **Source** `10.0.1.20` (Hyper-V Ubuntu) → external vSwitch → Windows `vEthernet` → KVM e1000 → **`br-default`**
2. **Default route** on inner: via `10.0.1.1` (metal gateway)
3. **Metal host** matches `10.1.0.0/16` → **`gre-peer`** (src `10.0.1.1`, outer header `172.31.96.x ↔ 172.31.96.y`)
4. **VPC** delivers GRE to peer transport ENI (L0)
5. **Site 1 metal** decaps GRE → forwards into **`br-default`** / `10.1.1.0/24`
6. **Hyper-V path** on site 1 → inner `10.1.1.20`

Reverse path symmetric with `10.0.0.0/16` encap on site 1.

---

## Management / provisioning paths (dashed = out-of-band)

```mermaid
flowchart LR
  DEV[Your laptop] -->|SSH / SSM| NIC0[kvm-host-nic0]
  DEV -->|aws ssm send-command| SSM[SSM]
  SSM --> METAL[Metal host scripts]
  METAL -->|WinRM :5985| WIN[Windows 10.x.1.10]
  METAL -->|HTTP :8090 on 10.x.1.1| WIN
  WIN -->|Hyper-V API| INNER[ubuntu-inner]
```

Scripts land on metal via **S3 bootstrap bucket** + SSM; Windows is configured over **WinRM**; inner VM disk/seed served over **HTTP from lab gateway**.

---

*See [BUILD.md](BUILD.md) for how this was built and [nested-virt-hiccups.md](nested-virt-hiccups.md) when a layer lies.*
