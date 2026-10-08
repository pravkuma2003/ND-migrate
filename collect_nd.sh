#!/usr/bin/env bash
# Read-only Nexus Dashboard (ND 3.0.x + NDFC 12.1.x) inventory collector.
# Only issues GET requests after login. Nothing is changed on the ND.
#
# Usage:  ./collect_nd.sh <nd-mgmt-ip> [username] [login-domain]
#         Password is prompted (or taken from $ND_PASS) — never passed on the command line.
# Output: ./nd_<ip>_<timestamp>/  (one JSON file per API call + summary.txt)
set -euo pipefail

ND=${1:?usage: $0 <nd-ip> [user] [domain]}
USER_NAME=${2:-admin}
DOMAIN=${3:-DefaultAuth}
if [[ -z "${ND_PASS:-}" ]]; then read -rsp "Password for $USER_NAME@$ND: " ND_PASS; echo; fi

OUT="nd_${ND}_$(date +%Y%m%d_%H%M%S)"
umask 077
mkdir -p "$OUT"
JAR=$(mktemp); trap 'rm -f "$JAR"' EXIT   # session cookie: some APIs (e.g. sitemanagement) need it, not just the Bearer token

# --- 1. Login (POST /login) -> JWT token ----------------------------------
LOGIN_BODY=$(python3 -c 'import json,sys;print(json.dumps({"userName":sys.argv[1],"userPasswd":sys.argv[2],"domain":sys.argv[3]}))' \
             "$USER_NAME" "$ND_PASS" "$DOMAIN")
TOK=$(curl -sk -m 30 -c "$JAR" -H 'Content-Type: application/json' --data-binary @- "https://$ND/login" <<<"$LOGIN_BODY" \
      | python3 -c 'import json,sys;print(json.load(sys.stdin)["jwttoken"])')
unset ND_PASS LOGIN_BODY

# --- 2. GET endpoints (name|path) -------------------------------------------
NDFC=/appcenter/cisco/ndfc/api/v1
ENDPOINTS=(
  "version|/version.json"
  # ND platform / cluster
  "nodes_platform|/nexus/infra/api/platform/v1/nodes"
  "clusters_platform|/nexus/infra/api/platform/v1/clusters"
  "nodes|/api/config/class/nodes/"
  "cluster|/api/config/class/v2/cluster/"
  "routes|/api/config/class/routes/"
  "external_service_pools|/api/config/class/externalservices/"
  "k8s_node_resources|/sedgeapi/v1/k8s-mon/api/node"
  "k8s_health|/sedgeapi/v1/k8s-mon/api/sehealth"
  # ND apps / services
  "apps_installed|/api/config/class/apps"
  "app_instances|/api/config/class/appinstances"
  "scale_profiles|/api/config/class/scaleprofiles"
  "sites|/nexus/api/sitemanagement/v4/sites"
  # ND admin / security
  "local_users|/api/config/class/localusers/"
  "remote_users|/api/config/class/remoteusers/"
  "login_domains|/api/config/class/logindomain/"
  "security_domains|/api/config/class/aaadomain/"
  "roles|/api/config/class/aaarole/"
  "trusted_cas|/api/config/class/ndtrustedcas"
  "syslog_destinations|/api/config/class/syslogs/"
  "config_backups_exports|/api/config/class/exports/"
  "config_imports|/api/config/class/imports/"
  # NDFC
  "ndfc_version|$NDFC/fm/about/version"
  "ndfc_features|$NDFC/fm/features"
  "ndfc_fabrics|$NDFC/lan-fabric/rest/control/fabrics"
  "ndfc_switches|$NDFC/lan-fabric/rest/inventory/allswitches"
  "ndfc_images|$NDFC/imagemanagement/rest/imageupload/uploaded-images-table"
  "ndfc_image_policies|$NDFC/imagemanagement/rest/policymgnt/policies"
)

for e in "${ENDPOINTS[@]}"; do
  name=${e%%|*}; path=${e#*|}
  code=$(curl -sk -m 120 -b "$JAR" -H "Authorization: Bearer $TOK" -o "$OUT/$name.json" -w '%{http_code}' "https://$ND$path" || echo ERR)
  printf '%-24s %s %s\n' "$name" "$code" "$path" | tee -a "$OUT/_http_status.txt"
done
unset TOK

# --- 3. Human-readable summary ----------------------------------------------
python3 - "$OUT" > "$OUT/summary.txt" <<'PY'
import json, sys, os
d = sys.argv[1]
def L(n):
    try: return json.load(open(os.path.join(d, n + ".json")))
    except Exception as ex: return None
def sec(t): print(f"\n== {t}")

sec("Nodes")
for n in L("nodes") or []:
    o = n.get("operStatus", {})
    print(n["name"], n["serial"], n["nodeRole"], o.get("version"), o.get("nodePlatformType"), o.get("model"), o.get("currentState"))
    print("  mgmt", n["oobIP"], "gw", n["oobGW"], "| data", n["inbandIP"], "gw", n["inbandGW"], "vlan", n.get("inbandVlanid"))
for k in L("k8s_node_resources") or []:
    for n in k.get("nodes", []):
        r = n["allocatedResources"]
        print("  k8s", n["objectMeta"]["name"], f'vCPU={r["cpuCapacity"]/1000:g}', f'RAM={r["memoryCapacity"]/2**30:.1f}GiB',
              f'cpuReq={r["cpuRequestsFraction"]:.0f}%', f'memReq={r["memoryRequestsFraction"]:.0f}%', f'pods={r["allocatedPods"]}/{r["podCapacity"]}')
print("  health:", L("k8s_health"))

sec("Cluster")
for c in L("cluster") or []:
    print(json.dumps({k: v for k, v in c.items() if k != "meta"}, indent=1))
sec("Static routes");          print(json.dumps(L("routes"), indent=1))
sec("External service pools")
for p in L("external_service_pools") or []:
    print(p["target"], p["pool"]); [print("   ", ip, v.get("service")) for ip, v in p.get("operStatus", {}).get("pool", {}).items()]

sec("App instances (running)")
for a in L("app_instances") or []:
    for i in a.get("instances", []):
        print(f'{a["appName"]:50} {i.get("version")}  {(i.get("profileSelection") or {}).get("profile")}')
sec("Apps installed")
for a in L("apps_installed") or []: print(" ", a["appID"])

sec("NDFC")
print(L("ndfc_version"))
f = (L("ndfc_features") or {}).get("data", {}).get("features", {})
print("enabled features:", [k for k, v in f.items() if v.get("admin_state") == "enabled"])
for fb in L("ndfc_fabrics") or []:
    nv = fb.get("nvPairs", {})
    print(f'  fabric {fb["fabricName"]:20} {fb["templateName"]:16} ASN={fb.get("asn")} repl={nv.get("REPLICATION_MODE")} underlay={nv.get("LINK_STATE_ROUTING")} health={fb.get("operStatus")}')
for s in L("ndfc_switches") or []:
    print(f'  sw {s.get("fabricName"):14} {s.get("logicalName"):14} {s.get("ipAddress"):15} {s.get("model")} {s.get("release")} {s.get("serialNumber")} {s.get("switchRole")} {s.get("status")}')
for i in (L("ndfc_images") or {}).get("lastOperDataObject", []): print("  image", i.get("name"))
for i in (L("ndfc_image_policies") or {}).get("lastOperDataObject", []): print("  image-policy", i.get("policyName"), i.get("nxosVersion"))

sec("Sites (ND)")
for s in (L("sites") or {}).get("items", []):
    print(" ", s["spec"]["name"], s["spec"]["siteType"], s.get("status", {}).get("apps"))

sec("Admin")
print("local users:", [u.get("loginID") for u in L("local_users") or []])
print("remote users:", len(L("remote_users") or []))
print("login domains:", [x.get("domain") for x in L("login_domains") or []])
print("security domains:", [x.get("name") for x in L("security_domains") or []])
print("roles:", len(L("roles") or []))
print("syslog destinations:", L("syslog_destinations"))
print("trusted CAs:", len(L("trusted_cas") or []))
print("config backups (exports):", len(L("config_backups_exports") or []))
PY

echo; echo "Done -> $OUT/summary.txt"
