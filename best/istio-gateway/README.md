# Istio gateway · Keycloak SSO · apps on AKS

Three layers, each installed on its own against the cluster your `kubectl` currently points at:

| Layer | What | Install | Remove | Test |
|---|---|---|---|---|
| 1. Gateway | Istio ingress + Azure LB (`helm/istio-ingress-azure`) | `scripts/install-platform.sh` (step 1) or `scripts/deploy-istio-gateway.sh` | `scripts/uninstall-platform.sh --all` | `scripts/test-gateway.sh` |
| 2. Keycloak | Keycloak `start` + PostgreSQL, realm `demoweb` with groups/users, `/auth` route (`helm/keycloak`) | `scripts/install-platform.sh` (step 2) | `scripts/uninstall-platform.sh [--purge]` | `scripts/test-keycloak.sh` |
| 3. Apps | e.g. **apps/portal**: web site + API behind oauth2-proxy, registers its own OIDC client | `apps/portal/install.sh` (checks layer 2 first) | `apps/portal/uninstall.sh` | `apps/portal/test.sh` |

```bash
az aks get-credentials -g <rg> -n <cluster>
scripts/install-platform.sh          # gateway → Keycloak+Postgres   (~5 min; prints admin URL/password)
apps/portal/install.sh               # the web site + API            (~2 min; prints http://<IP>/ and demo/demo123)
```

Layers 1+2 can live alone; add/remove apps any time. `scripts/uninstall-platform.sh` refuses to remove Keycloak
while apps are installed (use `--all` to tear everything down). Generated passwords are kept in `.demoweb/`.
Details: [docs/SSO.md](docs/SSO.md), [apps/portal/README.md](apps/portal/README.md).

```
istio-gateway/
├── helm/istio-ingress-azure/     gateway chart (Azure LB annotations, Gateway API or Istio API)
├── helm/keycloak/                Keycloak + PostgreSQL + realm import + /auth route
├── helm/nginx-test/              plain nginx to prove the gateway works (no login)
├── apps/portal/                  web site + API (own chart + scripts) — template for more apps
├── scripts/                      install-platform.sh · uninstall-platform.sh · test-keycloak.sh · deploy-istio-gateway.sh · test-gateway.sh · lib.sh
└── docs/SSO.md
```

## Quick start (Azure-managed Istio base)

If your cluster already has the Azure-managed Istio (istiod in `aks-istio-system`, `istio.io/rev=default`,
GatewayClass `approuting-istio`) the scripts detect it and use the Kubernetes Gateway API — nothing is installed
in the control plane, no `az` calls are made:

```bash
az aks get-credentials -g <rg> -n <cluster>          # make the AKS cluster the current context
scripts/deploy-istio-gateway.sh --with-test
#   ==> detected Istio flavour: aks-gateway-api
#   ✓ istiod: mcr.microsoft.com/oss/v2/istio/pilot:v1.31.3-1
#   ✓ GatewayClass approuting-istio: accepted
#   ==> helm upgrade --install istio-ingress -n istio-ingress
#   ✓ Gateway Programmed
#   ✓ external IP: 20.x.x.x
#   ✓ HTTP 200 · server: istio-envoy
```

What gets created in `istio-ingress`: a `gateway.networking.k8s.io/v1` **Gateway** (class `approuting-istio`) with
HTTP (and optionally HTTPS) listeners, and a ConfigMap referenced by `infrastructure.parametersRef` that sets
replicas/HPA/resources for the pods. The AKS Istio controller then provisions `Deployment` + `Service`
`default-gateway-approuting-istio`; the Azure LB annotations are passed through `spec.infrastructure.annotations`.
Apps attach with an **HTTPRoute**:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
spec:
  parentRefs: [{ name: default-gateway, namespace: istio-ingress }]
  hostnames: ["myapp.example.com"]
  rules: [{ backendRefs: [{ name: myapp, port: 80 }] }]
```

Join an app namespace to the mesh with `istio-injection=enabled` (revision is `default`), or
`istio.io/dataplane-mode=ambient` for sidecar-less (your istiod trusts `ztunnel`); `test-gateway.sh --ambient` tries the latter.

If the cluster has istiod configured for the Gateway API but the Gateway API CRDs / the `approuting-istio`
GatewayClass are not installed yet (common on a fresh cluster), the script installs the standard-channel CRDs
(`GATEWAY_API_VERSION`, default v1.5.1 — Istio 1.30+ needs v1.5.x) with `kubectl apply --server-side` and creates
the GatewayClass pointing at `istio.aks.azure.com/gateway-controller`, then waits for istiod to accept it.

Other clusters work the same command: a classic add-on (`asm-x-y` revision) → `aks-addon` mode; no Istio at all →
self-managed Istio 1.31 is installed first. Force a mode with `--mode`.

Expected tail of the output:

```
==> load balancer
  ✓ external IP: 20.51.x.x
  ✓ gateway healthy at 20.51.x.x:15021/healthz/ready
==> GET http://20.51.x.x/
  ✓ HTTP 200
  ✓ server: istio-envoy — the request went through the Istio gateway
    pod: nginx-test-7c9d…
  ✓ gateway test passed
```

Other shapes:

```bash
# classic AKS add-on (explicit). az is only called if the add-on's ingress gateway isn't enabled yet;
# the RG/cluster are inferred from the context via `az aks list`, or pass AZ_RG/AZ_CLUSTER.
scripts/deploy-istio-gateway.sh --mode aks-addon --with-test

# internal (VNet-only) load balancer
scripts/deploy-istio-gateway.sh --internal --set azure.internalSubnet=snet-ingress

# production-ish: static public IP in another RG, DNS label, TLS with http->https redirect
cat > prod.yaml <<'EOF'
azure:
  publicIPName: pip-ingress-prod
  publicIPResourceGroup: rg-network
  dnsLabel: myapp-ingress
gatewayAPI:                                               # (aks-gateway-api mode; use istioGateway: for the other modes)
  hosts: ["myapp.example.com"]
  tls: { enabled: true, certificateRef: myapp-tls, redirectHttp: true }   # kubectl -n istio-ingress create secret tls myapp-tls --cert … --key …
EOF
VALUES_FILE=prod.yaml scripts/deploy-istio-gateway.sh
scripts/test-gateway.sh --host myapp.example.com --keep

scripts/undeploy-istio-gateway.sh [--istio | --aks-addon]
```

## Modes

| mode | who runs the gateway pods + LB | chart creates | apps attach with |
|---|---|---|---|
| `aks-gateway-api` (auto on Azure-managed Istio) | AKS Istio controller, from the Gateway | Gateway API `Gateway` + infra ConfigMap (+ redirect HTTPRoute) | `HTTPRoute` |
| `aks-addon` | the add-on (`az aks mesh enable-ingress-gateway`) | Istio `Gateway` in `aks-istio-ingress` | `VirtualService` |
| `selfmanaged` | this chart | Deployment, LB Service, HPA, PDB, SDS Role, Istio `Gateway` | `VirtualService` |

## What the chart creates (self-managed mode)

| Object | Purpose |
|---|---|
| `Deployment istio-ingressgateway` | Pod template with `inject.istio.io/templates: gateway` and `image: auto`; istiod injects the Envoy proxy matching the control plane version. Non-root, binds 80/443 via the `ip_unprivileged_port_start` sysctl, spread across zones. |
| `Service istio-ingressgateway` (LoadBalancer) | The Azure LB. Annotations from `values.azure`: internal LB + subnet, static public IP by name/RG (or `staticIP`), DNS label, HTTP health probes against Envoy's `/healthz/ready` on 15021, TCP idle timeout. `externalTrafficPolicy: Local` keeps client IPs. |
| `HorizontalPodAutoscaler`, `PodDisruptionBudget` | 2–5 replicas, at least 1 during node drains. |
| `ServiceAccount` + `Role/RoleBinding` | Lets the gateway read TLS Secrets in its namespace (SDS, `credentialName`). |
| `Gateway default-gateway` (networking.istio.io) | Listeners: HTTP/80 (optionally redirecting), HTTPS/443 (SIMPLE / MUTUAL / PASSTHROUGH). |

In `mode: aks-addon` the add-on owns the gateway pods and LB (`az aks mesh enable-ingress-gateway`), so the chart
only creates the `Gateway` in `aks-istio-ingress` selecting `istio: aks-istio-ingressgateway-external|internal`.

Applications attach with a VirtualService:

```yaml
spec:
  hosts: ["myapp.example.com"]
  gateways: ["istio-ingress/default-gateway"]
  http: [{ route: [{ destination: { host: myapp.myns.svc.cluster.local, port: { number: 80 } } }] }]
```

## Azure prerequisites and gotchas

* **Static public IP**: create it with `--sku Standard` in the region of the cluster. If it lives outside the node
  resource group, the cluster's managed identity needs *Network Contributor* on that resource group — otherwise the
  Service stays `<pending>` and `kubectl describe svc` shows an authorization error.
* **Internal LB**: the subnet must be in the cluster VNet; AKS creates the internal LB on first use (~2 min).
* **NSGs**: a public LB needs the node NSG to allow 80/443 (AKS adds rules automatically for LoadBalancer Services).
  The script's check of `:15021/healthz/ready` from your machine may fail if that port is filtered; the LB's own probes
  still work because they come from `AzureLoadBalancer`.
* **Health probes**: with `externalTrafficPolicy: Local` Azure probes the per-node health-check port, so nodes without a
  gateway pod are taken out of rotation; the HTTP probe annotations additionally point rules at Envoy's readiness.
* **TLS secret** goes in the *gateway's* namespace (`istio-ingress`), not the application's.
* **Istio versions**: the script installs `ISTIO_VERSION` (default 1.31.1) from `ISTIO_CHART_REPO`. Override both for
  air-gapped mirrors or OCI (`oci://ghcr.io/istio/release/charts`).

## Verifying by hand

```bash
kubectl -n istio-ingress get svc,pods,gateway
IP=$(kubectl -n istio-ingress get svc istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -sI http://$IP/ -H 'Host: myapp.example.com'          # expect "server: istio-envoy"
istioctl analyze -A
istioctl proxy-config listeners deploy/istio-ingressgateway -n istio-ingress
```
