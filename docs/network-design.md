# Multi-Cloud Connectivity Design

**Application:** frontend on **AWS EKS**, backend API on **Azure Kubernetes Service**, **Azure Database for PostgreSQL**.
**Requirement:** secure, scalable connectivity with **no public endpoints** on the workloads.
**Diagram:** [`network-diagram.drawio`](network-diagram.drawio) (editable in diagrams.net) · PNG below.

![Multi-cloud network diagram](network-diagram.png)

---

## 1. Summary of the design

- **Hub-and-spoke in each cloud.** AWS: a **Transit Gateway** hub with an EKS spoke VPC and a shared-services VPC. Azure: a **hub VNet** (VPN Gateway, Azure Firewall, DNS Private Resolver) peered with an AKS spoke and a data spoke. New workloads attach as spokes without changing the cross-cloud link.
- **Cross-cloud link:** site-to-site **IPsec VPN with BGP**, Transit Gateway ↔ active-active, zone-redundant Azure VPN Gateway. That gives **4 tunnels** with ECMP. It is quick to build, inexpensive and encrypted. The **upgrade path** is AWS Direct Connect + Azure ExpressRoute through a cloud exchange, with the VPN kept as backup.
- **Private everywhere:** internal load balancers only, private EKS and AKS API endpoints, PostgreSQL via **private endpoint** with public access disabled. Inter-cloud traffic is inspected by **Azure Firewall**. Egress to the internet goes only through central, allow-listed egress points.
- **Split-horizon private DNS**, with conditional forwarding between **Route 53 Resolver** and **Azure DNS Private Resolver**.

**Regions:** AWS `eu-central-1` (Frankfurt) and Azure `Germany West Central` (Frankfurt). Placing both in the same metro keeps round-trip time for the frontend → backend call around 2–5 ms plus IPsec overhead. Region proximity is the single biggest factor in cross-cloud latency.

## 2. Network topology and CIDR plan

The address plan is non-overlapping and summarizable, so a new spoke never needs a new route between the clouds: AWS advertises `10.10.0.0/15`, Azure advertises `10.20.0.0/14`.

| Range | Where | Purpose / notes |
| --- | --- | --- |
| `10.10.0.0/16` | AWS EKS spoke VPC | 3 × /19 private node subnets (one per AZ), 3 × /24 for internal ALB, /28s for endpoints |
| `100.64.0.0/16` | AWS EKS pods | Secondary VPC CIDR, VPC CNI custom networking; **not advertised** (pods SNAT to node IPs) |
| `10.11.0.0/24` | AWS shared-services VPC | Route 53 Resolver endpoints, central egress (NAT + Network Firewall) |
| `10.20.0.0/22` | Azure hub VNet | GatewaySubnet /27, AzureFirewallSubnet /26, DNS resolver inbound /28 and outbound /28 |
| `10.21.0.0/16` | Azure AKS spoke VNet | Node subnet /20, internal LB subnet /24 (ingress IP `10.21.64.10`) |
| `192.168.0.0/16` | AKS pods | Azure CNI Overlay; not routable outside the cluster |
| `10.22.0.0/24` | Azure data spoke VNet | PostgreSQL private endpoint (`10.22.0.4`) |
| `169.254.21.0/30`, `.21.4/30`, `.22.0/30`, `.22.4/30` | Tunnel inside addresses | BGP peering per tunnel; Azure requires the APIPA range for AWS interop |

Pod CIDRs stay unroutable in both clouds. The only cross-cloud flows are node → internal load balancer, which keeps the routing tables and firewall rules small and hides cluster internals.

## 3. Connectivity selection

| Option | Security | Bandwidth & latency | Lead time & cost | Verdict |
| --- | --- | --- | --- | --- |
| **Site-to-site IPsec VPN** (TGW ↔ VPN Gateway, BGP) | Encrypted, private addressing, over the internet | ~1.25 Gbps per tunnel; ECMP across 4 tunnels, capped by the VPN Gateway SKU (VpnGw3AZ ≈ 2.5 Gbps); internet jitter | Hours; low cost | **Chosen to start** |
| **Direct Connect + ExpressRoute via cloud exchange** (Equinix Fabric / Megaport) | Private circuit, no internet path; add MACsec or IPsec on top if required | 1–10 Gbps, predictable latency, SLA | Weeks; port and circuit fees | **Scale target**, when throughput or SLA needs justify it |
| Public endpoints + mTLS | Exposed endpoints, larger attack surface | Internet | Fast, cheap | Rejected: violates "no public endpoint" |
| Cloud-native Private Link | Excellent | Excellent | n/a | Not available across clouds; used **within** Azure for PostgreSQL |

**Resilience:** Azure's two active gateway instances each connect to a separate AWS customer gateway, and each AWS VPN connection has 2 tunnels, giving 4 tunnels. BGP withdraws failed paths in seconds. Transit Gateway ECMP spreads flows across healthy tunnels, and the zone-redundant gateway survives an Azure AZ failure.

## 4. Traffic flow

The numbers match the diagram.

1. **Users → frontend.** Corporate users arrive over Direct Connect/VPN into the Transit Gateway (①′). Internet users, if required, reach **CloudFront + WAF**, which connects to the **internal ALB** through a **VPC origin** (①, ②). The ALB has no public IP and only accepts CloudFront's managed prefix list.
2. **ALB → frontend pods** (③), in private subnets across three AZs.
3. **Frontend → backend.** The frontend calls `https://api.azure.corp.internal`, which resolves to `10.21.64.10` (see DNS flow). The pod's traffic is SNAT'd to the node IP (`10.10.x.x`). The VPC route `10.20.0.0/14 → TGW` sends it to the Transit Gateway (④).
4. **Transit Gateway → Azure VPN Gateway** over the IPsec tunnels, with BGP choosing among 4 ECMP paths (⑤).
5. **Hub inspection.** A route table on the GatewaySubnet sends spoke-bound traffic to **Azure Firewall** (⑥). Only `10.10.0.0/16 → 10.21.64.10:443` is allowed; everything else is denied and logged.
6. **Firewall → AKS internal load balancer and ingress controller → backend-api pods** (⑦, ⑧), TLS end to end.
7. **Backend → PostgreSQL** private endpoint `10.22.0.4:5432` over TLS (⑨). The backend authenticates with **Entra ID via AKS Workload Identity**, so no database password exists.
8. **Return traffic** follows the same path. Routing is symmetric because the firewall is the only hop between the VPN and the spokes; asymmetric paths would break stateful inspection.

**Egress:** AKS uses `outboundType: userDefinedRouting`, so pod egress to the internet exits through Azure Firewall with an FQDN allow-list. EKS egress goes through the shared-services VPC, using NAT Gateway plus AWS Network Firewall. No workload has a direct internet route.

## 5. DNS flow

| Zone | Hosted in | Records | Resolvable from |
| --- | --- | --- | --- |
| `aws.corp.internal` | Route 53 private hosted zone | frontend internal ALB alias | AWS, Azure, on-prem |
| `azure.corp.internal` | Azure Private DNS zone | `api` → `10.21.64.10` | Azure, AWS, on-prem |
| `privatelink.postgres.database.azure.com` | Azure Private DNS zone | DB private endpoint → `10.22.0.4` | **Azure only**; the frontend never needs the database |

**AWS → Azure:** EKS pod → CoreDNS → VPC resolver (`10.10.0.2`) → **Route 53 Resolver outbound endpoint** → forwarding rule for `azure.corp.internal` → **Azure DNS Private Resolver inbound endpoint** (`10.20.0.132`, `.133`) → Azure Private DNS zone → `10.21.64.10`.

**Azure → AWS:** AKS pod → CoreDNS → Azure DNS (`168.63.129.16`) → forwarding ruleset on the **Private Resolver outbound endpoint** → **Route 53 Resolver inbound endpoints** (`10.11.0.10`, `.11`) → private hosted zone.

Both endpoints are deployed in two AZs, and forwarding rules list both target IPs. DNS queries travel through the same encrypted tunnels. Not forwarding the PostgreSQL zone to AWS is deliberate: a name that can't be resolved can't be misused.

## 6. Security controls (defense in depth)

| Layer | Control |
| --- | --- |
| Edge | Only optional internet entry: CloudFront + AWS WAF (managed rules, rate limiting) to an internal ALB via VPC origin. Azure has **no** public entry point. |
| Transport | IPsec (IKEv2, AES-256-GCM, SHA-384, DH group 20, PFS) between clouds; TLS 1.2+ on every hop; optional mTLS between services via a service mesh |
| Network | AWS security groups (ALB ← CloudFront prefix list, nodes ← ALB); Azure NSGs on every subnet; **Azure Firewall Premium** on all cross-cloud and egress traffic (allow-list, IDPS, TLS inspection); Kubernetes **NetworkPolicies** default-deny per namespace (Calico on EKS, Cilium on AKS) |
| Control plane | Private EKS and AKS API endpoints, reachable only from admin networks via the hub; Entra ID / IAM Identity Center for human access |
| Data | PostgreSQL: public network access disabled, private endpoint, TLS enforced, Entra ID authentication via Workload Identity, encryption at rest with customer-managed keys |
| Governance | Azure Policy and AWS SCPs deny public IPs, public load balancers and public PaaS endpoints in workload accounts/subscriptions; IPAM owns the CIDR plan |
| Visibility | VPC Flow Logs, NSG/VNet flow logs, Azure Firewall logs, Route 53 Resolver query logs → central SIEM; tunnel and DNS health feed the alerts in [`observability.md`](observability.md) |

## 7. Scalability, restrictions and tradeoffs

- **Throughput ceiling.** IPsec is limited per tunnel (~1.25 Gbps) and by the Azure gateway SKU. Monitor tunnel utilization, and move to DX + ExpressRoute before sustained load passes ~60 % of capacity.
- **Egress cost.** Cross-cloud traffic is billed as data transfer out on both sides. A chatty frontend → backend protocol costs money as well as latency: batch requests and cache in the frontend.
- **Latency.** Each request crosses the cloud boundary at least once. Keep calls coarse-grained, set timeouts and retries with jittered backoff, and use connection pooling to avoid repeated TLS handshakes.
- **MTU.** IPsec overhead reduces the effective MTU to ~1400 bytes. Clamp TCP MSS on the gateways to avoid fragmentation and black-holed large packets.
- **Overlapping CIDRs as the organization grows.** A central IPAM (AWS VPC IPAM with Azure's IPAM) reserves ranges. The summarized advertisements (`10.10.0.0/15`, `10.20.0.0/14`) leave room to grow.
- **Platform abstraction.** Delivered as reusable Terraform modules (TGW spoke, Azure spoke, DNS forwarding rule, firewall rule collection), so product teams request connectivity through a pull request instead of a ticket.
- **Tradeoff accepted.** Azure Firewall in the path adds latency (~1 ms) and cost. It buys central inspection, logging and a single egress policy. For very high-throughput flows, a dedicated allow-listed route that bypasses inspection is a documented exception, not the default.
