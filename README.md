# Nexus Dashboard pre-migration inventory — collection runbook

Tested against ND 3.0.1i + NDFC 12.1.3b. Every call is **read-only (HTTP GET)** except `POST /login`.
Run from any host with `bash`, `curl`, and `python3` that can reach the ND management IP on TCP 443.

## Quick way: the script

```bash
chmod +x collect_nd.sh
./collect_nd.sh <nd-mgmt-ip> admin DefaultAuth     # prompts for the password
# remote/AAA user: ./collect_nd.sh <ip> <user> <login-domain-name>
```

Output goes to `nd_<ip>_<timestamp>/`: one JSON file per API call, `_http_status.txt`, and `summary.txt`.
Hand `summary.txt` back for the migration plan, and keep the JSON folder as the record.
The JSON files have no passwords, but they do include IPs, serials, and topology, so treat the folder as internal.

## Manual way: the individual calls

### 1. Login
```bash
ND=<nd-mgmt-ip>
read -rsp "ND password: " P; echo
TOK=$(curl -sk -c /tmp/nd.jar -H 'Content-Type: application/json' \
  -d "{\"userName\":\"admin\",\"userPasswd\":\"$P\",\"domain\":\"DefaultAuth\"}" \
  https://$ND/login | python3 -c 'import json,sys;print(json.load(sys.stdin)["jwttoken"])')
unset P
get() { curl -sk -b /tmp/nd.jar -H "Authorization: Bearer $TOK" "https://$ND$1" | python3 -m json.tool; }
```
Send both the session cookie (`-b`) and the bearer token: `/nexus/api/sitemanagement/...` returns 401 with the token alone. Delete `/tmp/nd.jar` when you're done.
`-k` skips certificate verification, which you need while ND uses its default self-signed certificate. Drop it if production has a CA-signed certificate.

### 2. Calls and what each one answers

| What | API call | Migration relevance |
|---|---|---|
| ND build | `get /version.json` | Exact version to deploy on KVM |
| Nodes (IPs, serial, role, OVA/ESX, version) | `get /api/config/class/nodes/` and `get /nexus/infra/api/platform/v1/nodes` | Mgmt/data IPs, gateways, data VLAN, node count |
| Cluster (name, app/service subnets, DNS, NTP, proxy) | `get /api/config/class/v2/cluster/` and `get /nexus/infra/api/platform/v1/clusters` | Values to re-enter in the KVM bootstrap |
| Static routes | `get /api/config/class/routes/` | Re-create after rebuild |
| External service pools (persistent IPs) | `get /api/config/class/externalservices/` | **Critical**: switches send syslog/traps and POAP to these IPs, so keep them the same |
| vCPU / RAM / pod usage | `get /sedgeapi/v1/k8s-mon/api/node` | Sizing for the KVM VM |
| Cluster health | `get /sedgeapi/v1/k8s-mon/api/sehealth` | Must be healthy before backup |
| Installed apps | `get /api/config/class/apps` | Which services/versions to reinstall |
| Running app instances and profiles | `get /api/config/class/appinstances` | Shows what is actually enabled vs only installed |
| Scale profile | `get /api/config/class/scaleprofiles` | Deployment profile |
| Sites onboarded | `get /nexus/api/sitemanagement/v4/sites` | Fabrics/sites to come back after restore |
| Local / remote users | `get /api/config/class/localusers/` and `get /api/config/class/remoteusers/` | |
| Login domains (LDAP/RADIUS/TACACS) | `get /api/config/class/logindomain/` | AAA servers to re-point/allow from new IPs |
| Security domains / roles | `get /api/config/class/aaadomain/` and `get /api/config/class/aaarole/` | |
| Trusted CAs | `get /api/config/class/ndtrustedcas` | Certificates to re-import |
| Syslog destinations | `get /api/config/class/syslogs/` | |
| ND config backups / imports | `get /api/config/class/exports/` and `get /api/config/class/imports/` | Confirms whether a backup exists |
| NDFC version / mode | `get /appcenter/cisco/ndfc/api/v1/fm/about/version` | |
| NDFC feature sets | `get /appcenter/cisco/ndfc/api/v1/fm/features` | Filter for `admin_state == enabled` |
| NDFC fabrics | `get /appcenter/cisco/ndfc/api/v1/lan-fabric/rest/control/fabrics` | |
| NDFC switch inventory | `get /appcenter/cisco/ndfc/api/v1/lan-fabric/rest/inventory/allswitches` | Switch IPs/serials/roles/reachability |
| NDFC image repo / policies | `get /appcenter/cisco/ndfc/api/v1/imagemanagement/rest/imageupload/uploaded-images-table` and `.../policymgnt/policies` | Images to re-upload (not always included in backups) |

Example: `get /api/config/class/externalservices/`

### Not collected on purpose
- `/appcenter/cisco/ndfc/api/v1/lan-fabric/rest/lanConfig/getLanSwitchCredentials`: returns the per-switch credential entries, so I skipped it. To confirm the switch credentials, check the NDFC UI.

## Gather outside ND (hypervisor side)
The ND API does not expose these, so get them from vCenter/ESXi (`govc vm.info -e -r <vm>`, or the VM's Edit Settings):
- VM vCPU / RAM / reservations, and every VMDK with its size and thin/thick provisioning
- Port groups/VLANs for the two vNICs (mgmt = vNIC1, data = vNIC2) and MAC addresses
- Datastore and current used disk space
- On the target KVM host: CPU model/flags, free RAM, storage type/IOPS, and bridge names for mgmt and data
