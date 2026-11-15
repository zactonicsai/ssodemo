# AKS + Istio + Helm + Keycloak + Java 25: a beginner's guide

> Based on `Archive.zip` supplied November 15, 2026. This guide describes **what is already in the archive** separately from **what you would build next**. Read the existing `README.md` and `docs/SSO.md` for more detail about deploying the gateway and logging in.

## 1. The big picture (school and grocery-store examples)

Imagine a **school**:

| Technology | School example | Grocery-store example | Actual purpose |
|---|---|---|---|
| Azure AKS | School campus | Entire store | Hosts the Kubernetes cluster and its nodes. |
| Namespace | One school's hallway | One store department | Groups resources and helps separate teams. |
| Helm chart | Instructions for setting up classrooms | Store opening checklist | Generates Kubernetes objects from templates and settings. |
| `values.yaml` | Class schedule and supplies list | Store settings sheet | Customizable defaults for a Helm release. |
| Istio gateway | School front door | Store entrance | Receives external traffic and forwards it based on routes. |
| Azure Load Balancer | Road and driveway into the school | Parking lot entrance | Assigns/exposes IP access to gateway services. |
| HTTPRoute / VirtualService | Hallway signs | Aisle signs | Tells requests which Kubernetes Service to reach. |
| Kubernetes Service | Main office extension | Department phone number | Stable destination for a set of pods. |
| Deployment / Pod | Classroom and teacher | Checkout station and cashier | Runs and maintains copies of an application. |
| Keycloak | ID badge office | Employee login desk | Authenticates users and manages identities/roles. |
| oauth2-proxy | Badge checker at classroom door | Door guard | Redirects unauthenticated browser users to login. |
| NetworkPolicy | Locked hallway doors | Staff-only warehouse door | Limits network paths, assuming a supporting network policy implementation. |
| Istio mTLS + AuthorizationPolicy | Trusted staff badges | Staff-only stockroom | Encrypts mesh connections and checks workload identity when the relevant Istio APIs/proxies exist. |
| Java 25 Spring Boot (NEW) | School office handling forms | Store manager handling orders | API for workspace create/list/start/stop/events. |
| PersistentVolumeClaim (NEW) | Student's assigned locker | Backroom labeled storage bin | Keeps workspace files when pods stop or restart. |

**Important:** Helm does not replace Kubernetes; it is a packaging tool that asks Kubernetes to create/update resources. Keycloak checks identity, but every privileged operation must still be authorized in the Spring server. A Kubernetes `Service` is not itself a firewall.

## 2. What was actually in the uploaded ZIP

```text
Archive.zip
├── index.html                         # standalone Workspaces Simulation; NOT deployed by existing Helm charts
└── istio-gateway/
    ├── README.md                      # original gateway setup documentation
    ├── docs/SSO.md                    # original SSO guide
    ├── .demoweb/demo1.env             # generated demo secrets; handle as secrets
    ├── scripts/
    │   ├── lib.sh                     # common functions, mode and cluster detection
    │   ├── deploy-istio-gateway.sh    # install/configure ingress
    │   ├── test-gateway.sh            # test plain nginx path
    │   ├── undeploy-istio-gateway.sh
    │   ├── deploy-demoweb.sh          # gateway + Keycloak + oauth2-proxy + protected nginx
    │   ├── test-sso.sh                # test login and bypass protection
    │   └── undeploy-demoweb.sh
    └── helm/
        ├── istio-ingress-azure/       # gateway resources, Azure LB, routing settings
        ├── nginx-test/               # anonymous hello-page/ingress smoke test
        └── demoweb-sso/              # Keycloak, OAuth2 Proxy, protected nginx, policies
```

There is **no Spring Boot application, Java source, Postgres deployment, real terminal service, or workspace-provisioning controller** in the original ZIP. `index.html` lives at the ZIP top level; the chart's `templates/web-config.yaml` instead embeds a much smaller hard-coded nginx welcome page. Changing the standalone `index.html` does **not** automatically update the deployed site.

## 3. End-to-end request paths

**What the existing system does:**

```text
Browser
  │ http://<Azure-public-IP>/
  ▼
Azure LB → Istio Gateway → HTTPRoute `/` → oauth2-proxy:4180
                                            │
                              no cookie? → Keycloak `/auth/*`
                                            │ login and callback
                                            ▼
                                     web Service:80 → nginx Pod:8080

Browser `/auth/*` → Istio Gateway → Keycloak Service:8080
```

**Proposed extension:**

```text
Browser/index.html → /api/v1/workspaces → Istio → oauth2-proxy
                                                 → Spring Boot Service:8080
                                                        │
                                             demo: in-memory simulation
                                             future: Kubernetes API + PVCs
```

In the `demoweb-sso` chart, the gateway has one route for `/auth/*` to Keycloak and another catch-all `/` route to oauth2-proxy. It is oauth2-proxy's **upstream mapping** (`apps:`), not a new unauthenticated public gateway rule, that forwards `/api/` to the backend. Keep it behind login.

## 4. Helm chart 1: `helm/istio-ingress-azure`

Files and roles:

| File | What it does | Easy explanation |
|---|---|---|
| `Chart.yaml` | Names/versions the Helm package. | Label on the box. |
| `values.yaml` | Defines mode, Azure IP/LB, gateway host/TLS, replicas/resources. | School's settings sheet. |
| `templates/_helpers.tpl` | Shared template names/labels and conditionals. | Reusable instructions. |
| `templates/k8s-gateway.yaml` | In managed Gateway API mode, creates Gateway, infrastructure ConfigMap and optional HTTPS redirect HTTPRoute. | Gateway/front-door blueprint. |
| `templates/gateway.yaml` | Istio `networking.istio.io` Gateway in supported classic modes. | Alternate front-door instructions. |
| `templates/deployment.yaml` | In self-managed mode, runs gateway pods plus HPA and PodDisruptionBudget. | Staff, staffing increases, minimum coverage. |
| `templates/service.yaml` | In self-managed mode, creates Azure LoadBalancer Service. | Public entrance address. |
| `templates/serviceaccount.yaml` | In self-managed mode, creates gateway identity and permissions to read TLS secrets. | Keys for the door staff. |
| `templates/NOTES.txt` | Prints useful post-install instructions. | Setup receipt. |

The deployment script selects one of three modes:

1. **`aks-gateway-api`**: Azure-managed Istio controller owns gateway workload; Helm primarily defines the Gateway and supporting configuration. Apps use `HTTPRoute`.
2. **`aks-addon`**: AKS Istio add-on owns gateway pods; Helm creates an Istio `Gateway`. Apps use `VirtualService`.
3. **`selfmanaged`**: Helm owns gateway Deployment, Service, autoscaling and related resources; apps use `VirtualService`.

**Do not force the mode until you know which Istio APIs your cluster supports.** To inspect:

```bash
kubectl config current-context
kubectl get gatewayclass
kubectl api-resources --api-group=gateway.networking.k8s.io
kubectl api-resources --api-group=networking.istio.io
kubectl get pods -A | grep -E 'istio|gateway'
```

### Understanding three common YAML fields

```yaml
apiVersion: apps/v1             # Which Kubernetes instruction vocabulary?
kind: Deployment               # What kind of item are we creating?
metadata:
  name: sample                 # Item name on the cluster
spec:
  replicas: 2                  # Ask Kubernetes to keep two copies running
```

For Helm templates, `{{ .Values.web.replicas }}` means: **read the value from `values.yaml`**, like a school form that says "look up classroom count in the supply sheet." `{{ if ... }}` means "include this part only when the condition is true." `{{ include ... }}` reuses a helper function. `helm template` shows the final YAML that Kubernetes sees.

## 5. Helm chart 2: `helm/nginx-test`

- `Chart.yaml`: package information.
- `values.yaml`: nginx image, resource limits, gateway binding, hostname/path controls.
- `templates/configmap.yaml`: a small HTML page stored as configuration.
- `templates/nginx.yaml`: nginx Deployment, Service, and mode-dependent `HTTPRoute` or `VirtualService`.

This is a **smoke test**: it proves that the network path reaches an nginx pod; it does **not** prove SSO or workspace operations.

```bash
cd istio-gateway
scripts/deploy-istio-gateway.sh --with-test
scripts/test-gateway.sh
```

Confirm the cluster context before installing resources. The script can create publicly accessible endpoints and incur Azure charges.

## 6. Helm chart 3: `helm/demoweb-sso`

| Template | Kubernetes resources | School analogy |
|---|---|---|
| `keycloak.yaml` | Keycloak admin Secret, ServiceAccount, Deployment, Service, post-install Job | Badge office plus setup clerk |
| `keycloak-realm.yaml` | Secret containing realm import: demo user, roles, OIDC and SAML clients | Roster of students and badge types |
| `oauth2-proxy-config.yaml` | Secret and ConfigMap for OIDC endpoints, cookies, upstreams | Badge-checker rule book |
| `oauth2-proxy.yaml` | ServiceAccount, Deployment and Service | Badge checker at the classroom door |
| `web-config.yaml` | ConfigMap with nginx config and **embedded sample HTML** | The current classroom notice board |
| `web.yaml` | ServiceAccount, Deployment and Service for nginx | The website classroom |
| `routes.yaml` | Two HTTPRoutes or one VirtualService, depending on mode | Signs: `/auth/` → badges; everything else → badge checker |
| `networkpolicy.yaml` | Policies for web and Keycloak ingress | Network hallway locks |
| `mesh-policies.yaml` | Conditional PeerAuthentication, AuthorizationPolicy, VirtualService and DestinationRule | Staff identity check and traffic rules |
| `_helpers.tpl`, `NOTES.txt` | Shared naming and install instructions | Standard names and setup receipt |

The current `values.yaml` has an `apps:` array. It starts with the `web` service at `/`. oauth2-proxy uses that array to choose where authenticated traffic goes. An API entry at `/api/` is matched more specifically than `/`.

It currently configures a demonstration Keycloak identity (`demo`), a realm (`demoweb`), and an OIDC client (`oauth2-proxy`). It also defines a sample SAML client for apps that speak SAML directly. The actual browser login for this site is OIDC, not SAML.

**Demo-only security caution:** supplied defaults include example passwords, public HTTP URLs, `cookieSecure: false`, and a Keycloak `start-dev` configuration with temporary H2 storage. Do not expose this unchanged as a production system. Protect the `.demoweb/*.env` files; they hold credentials. The current archive contains an environment file, so review/rotate values before distributing copies.

## 7. Deploy, inspect, test, and roll back the original setup

Prerequisites: `az`, `kubectl`, `helm`, `openssl`, `curl`, `python3`; access to a suitable AKS cluster and permissions to install resources. Managed Istio / Gateway API configurations differ, so inspect the context first.

```bash
# Log in and select the correct cluster
az login
az aks get-credentials --resource-group YOUR_RG --name YOUR_AKS_CLUSTER
kubectl config current-context
kubectl get nodes

# From the extracted istio-gateway/ folder:
cd istio-gateway
scripts/deploy-demoweb.sh          # gateway + SSO + protected nginx
scripts/test-sso.sh                # redirects, login, protected access, bypass test

# Look behind the scenes
helm list -A
helm -n demoweb get values demoweb
helm -n demoweb get manifest demoweb
kubectl -n demoweb get deployments,svc,pods,configmaps,secrets
kubectl -n demoweb get httproute
kubectl -n demoweb logs deploy/oauth2-proxy --tail=100
kubectl -n demoweb logs deploy/keycloak --tail=100
kubectl -n demoweb describe pod POD_NAME

# Review BEFORE deploying a Helm update
helm lint helm/demoweb-sso
helm template demoweb helm/demoweb-sso --namespace demoweb \
  --set publicUrl=http://EXAMPLE-IP > /tmp/demoweb-rendered.yaml

# Release history and rollback (rollback restores Helm-managed objects, not external data)
helm -n demoweb history demoweb
helm -n demoweb rollback demoweb REVISION
```

The `helm template` command above is for reading YAML. Placeholder secret values must not be deployed as real credentials. To uninstall see `scripts/undeploy-demoweb.sh --help`; deletion of workloads may leave PVs or Azure resources needing cleanup.

## 8. What `index.html` actually does today

The separate `index.html` file is titled **Workspaces — Simulation**. It uses JavaScript and browser `localStorage` key **`ws.sim`**. It never calls `fetch()`. Therefore no current screen action calls the cluster or the identity service.

| Existing screen or function | What happens now | What Spring / AKS should eventually do |
|---|---|---|
| Home and `render()` | Show current browser-local data. | Display API-returned state. |
| Create / `doCreate()` | Validate name and create an object in `S.workspaces`. | `POST /api/v1/workspaces`; validate name, quota, permitted options. |
| My workspaces / `list()` | Read JavaScript object. | `GET /api/v1/workspaces` scoped to logged-in user. |
| Details / `detail()` | Show fake pod/node, terminal and simulated filesystem. | `GET /api/v1/workspaces/{name}` plus status/log APIs. |
| `startBoot()` | `setTimeout` fabricates boot log and status. | `POST /api/v1/workspaces/{name}/start`; async reconciliation/status polling. |
| `stopWs()` | Changes JavaScript object to Stopped. | `POST /api/v1/workspaces/{name}/stop`. |
| Delete button | Deletes or marks a simulated workspace. | `DELETE /api/v1/workspaces/{name}` with explicit PVC retention policy. |
| `shell()` | Parses fake commands within the browser. | Safe interactive terminal gateway (separate phase; do NOT execute arbitrary host commands in the Spring API). |
| `reaper()` | Every 5 seconds, stops idle demo workspaces. | Server-side scheduled policy/controller; cannot rely on open browser. |
| Events / `event()` | Browser-local event array (last 200). | `GET /api/v1/events`; audit and ownership enforcement. |
| Reset demo | Clears `ws.sim`. | Keep as a local-only simulation reset; never map directly to destructive cluster-wide deletion. |
| Theme | Saves dark-mode preference locally. | Keep in localStorage; does not need a backend. |

The form supports languages `go`, `python`, `rust`, `node`, `java`, `cpp`; tools such as `cmake`, `gdb`, `kubectl`, `ripgrep`, `fd`, `gh`, `k9s`, `mcast`; sizes `small`, `medium`, `large`; profiles `standard`, `hardware`; repository URL, multicast setting and idle timeout. The simulated Java version in the browser catalog is **21**: changing your **API server** to Java 25 does **not** automatically change workspace Java images. Those are separate decisions.

The UI's demo timeout is **3 minutes**, while its text says a real deployment would normally use four hours. Make real timeout policy a server-admin configuration, not a user-controlled unlimited-cost setting.

## 9. Plan: upgrade the website in three stages

### Stage A — keep the current demonstration

Preserve `index.html` unchanged as `index.simulation.html`. Keep its fake terminal and localStorage for offline education. Explain visibly when the page is in "Simulation" mode. This prevents a student from confusing a drawn classroom with a real classroom.

### Stage B — add a Java 25 Spring Boot REST API (sample included)

The accompanying `examples/spring-workspace-api/` is a small **in-memory teaching API**. It creates, lists, starts, stops and deletes pretend workspace records. It includes health and events endpoints; it does **not** create AKS pods, authenticate users, or provide a real terminal. Use Java 25 with Spring Boot 4.1.x; verify JDK and Boot support and dependency updates in the official documentation.

Suggested endpoint contract:

| HTTP method | Path | Purpose | Example result |
|---|---|---|---|
| GET | `/api/v1/health` | Demo backend health | `{"status":"UP","mode":"simulation"}` |
| GET | `/api/v1/workspaces` | List demo records | `[{"name":"science-lab","status":"Running"}]` |
| POST | `/api/v1/workspaces` | Create workspace record | `201 Created` |
| GET | `/api/v1/workspaces/{name}` | See one record | Workspace JSON |
| POST | `/api/v1/workspaces/{name}/start` | Mark Running | Workspace JSON |
| POST | `/api/v1/workspaces/{name}/stop` | Mark Stopped | Workspace JSON |
| DELETE | `/api/v1/workspaces/{name}` | Delete demo record | `204 No Content` |
| GET | `/api/v1/events` | View recent events | List of events |

Example request:

```bash
curl -i http://localhost:8080/api/v1/health
curl -i -X POST http://localhost:8080/api/v1/workspaces \
  -H 'Content-Type: application/json' \
  -d '{"name":"science-lab","languages":["java"],"tools":["kubectl"],"size":"small","profile":"standard","idleMinutes":3}'
curl http://localhost:8080/api/v1/workspaces
curl -X POST http://localhost:8080/api/v1/workspaces/science-lab/stop
curl -X POST http://localhost:8080/api/v1/workspaces/science-lab/start
```

Local starter run:

```bash
cd examples/spring-workspace-api
java -version                         # must print Java 25
mvn spring-boot:run
# in another terminal: curl http://localhost:8080/api/v1/health
```

The API deliberately has **no authentication and uses volatile in-memory storage**; listen on `127.0.0.1` locally and **do not publish this example as a real remotely accessible management API** until authentication, user-level authorization, audit, data storage and deployment controls are added.

### Stage C — replace the pretend actions with real AKS operations

A real implementation should use a carefully scoped Kubernetes ServiceAccount, workspace CRDs/Operator or a trusted Kubernetes client, owner metadata, resource quotas and permitted image profiles. Use a `StatefulSet`/Deployment and PVC as appropriate; do not let clients submit raw Pod YAML. Workspaces should have non-root security contexts, restricted capabilities, network policies, no privileged host access, storage quotas and idle cleanup. Keep profile `hardware` disabled until there is a separate, formally authorized and isolated lab node pool.

**School example:** a student asks the office for a classroom. The office validates that the student belongs to the school and is allowed a classroom. The office tells the caretaker to prepare one. It does not hand over the entire campus master key.

## 10. Exactly how to connect the page to Spring

**Option recommended for students:** host `index.html` through nginx and `/api/` through the same public origin. Avoid browser CORS and do not store OAuth tokens in localStorage.

**A. Preserve your existing UI and add an API adapter near the beginning of its `<script>`:**

```javascript
const API_BASE = '/api/v1';
const MODE = 'api';  // 'simulation' or 'api'

async function api(path, {method='GET', body} = {}) {
  const response = await fetch(`${API_BASE}${path}`, {
    method,
    credentials: 'same-origin',
    headers: body ? {'Content-Type':'application/json'} : {},
    body: body ? JSON.stringify(body) : undefined
  });
  if (!response.ok) {
    throw new Error(`API ${response.status}: ${await response.text()}`);
  }
  if (response.status === 204) return null;
  return response.json();
}
```

**B. Create action: rewrite `doCreate()` to use the server instead of `S.workspaces` in API mode.** The payload should use `draft.name`, `draft.languages`, `draft.tools`, `draft.size`, `draft.repo`, `draft.profile`, `draft.multicast`, `draft.idle` (rename the last field to `idleMinutes` for the sample API). The backend must revalidate every field; checks in JavaScript can be bypassed.

```javascript
async function createFromApi() {
  const body = {
    name: draft.name || draft.languages[0], languages: draft.languages,
    tools: draft.tools, size: draft.size, profile: draft.profile,
    idleMinutes: draft.idle
  };
  const created = await api('/workspaces', {method:'POST',body});
  await refreshWorkspaces();
  S.sel = created.name; S.tab = 'detail'; render();
}

async function refreshWorkspaces() {
  const items = await api('/workspaces');
  S.workspaces = Object.fromEntries(items.map(w => [w.name, w]));
  render();
}
```

Note: this is an **integration pattern, not a complete patch**. The supplied `detail()`, `shell()`, `wsCards()`, `bootSteps()` and status model expect extra simulation fields (`homeFS`, `term`, `pod`, `cwd`, etc.). Either adapt those render functions to the new DTO or add a safe display mapper. **Do not simply call the new API and assume the page will work unchanged.** For API mode, replace the demo's `setTimeout`-based boot steps with server polling, and disable the fake shell until there is a secure terminal service.

**C. On button clicks, replace local mutations:**

```javascript
await api(`/workspaces/${encodeURIComponent(name)}/start`, {method:'POST'});
await api(`/workspaces/${encodeURIComponent(name)}/stop`,  {method:'POST'});
await api(`/workspaces/${encodeURIComponent(name)}`,       {method:'DELETE'});
await refreshWorkspaces();
```

**D. Get server events and status:**

```javascript
async function refreshEvents() {
  S.events = await api('/events');
  render();
}
// Schedule refresh when the workspaces/events tabs are visible.
// On real Kubernetes, prefer state transitions (Pending/Starting/Running/Stopped/Error)
// that come from the server, not the browser's timers.
```

**E. Make runtime mode obvious:** display a header badge saying `SIMULATION — no Kubernetes resources` or `API CONNECTED — server mode`. Do not rely on the hostname alone to claim live status.

## 11. Helm changes required to actually deploy the custom website and API

The uploaded `demoweb-sso` chart has `web-config.yaml` containing inline HTML. Your separate `index.html` will **not** be deployed unless you change that chart. Two reasonable approaches:

1. **Best long-term:** build an nginx Docker image containing your versioned `index.html`; change `web.image` in `values.yaml` to the image tag and `helm upgrade` it. Then remove/disable the chart's old `web-html` HTML volume mount so the ConfigMap does not hide the image's HTML. This gives repeatable rollbacks.
2. **Quick classroom demo:** modify `web-config.yaml` to load an external Helm file using `.Files.Get`, e.g. put the page at `helm/demoweb-sso/files/index.html`, and use `index.html: |` followed by `{{ .Files.Get "files/index.html" | nindent 4 }}`. A ConfigMap has size limits, and this archive's page is about 59 KB; a container image is better for larger sites. Verify that the nginx `web.yaml` volume mounts still use the generated `web-html` ConfigMap. Do not use `.Files.Get` to refer to the ZIP-root file outside the chart; Helm cannot package arbitrary parent-directory files.

For the Spring backend, add a **separate** Helm chart or a new optional subchart so it can be upgraded independently from login infrastructure. The new chart should create a Deployment, ClusterIP Service, non-root configuration, readiness/liveness probes, resource limits and a least-privileged ServiceAccount. Set `replicas: 1` for the teaching API with in-memory state (two replicas would disagree); use a shared database before horizontal scaling.

**Add this entry to `helm/demoweb-sso/values.yaml` in `apps:` (in addition to the existing `web` entry):**

```yaml
apps:
  - name: web
    path: /
    service: web
    port: 80
  - name: api
    path: /api/
    service: workspace-api
    namespace: demoweb
    port: 8080
```

This tells oauth2-proxy: "for an authenticated path beginning `/api/`, send traffic to `workspace-api:8080`." The provided config forwards the `/api/` prefix unchanged, matching the sample Java routes.

**Security warning:** the archive's `NetworkPolicy` and `AuthorizationPolicy` specifically protect the **web** pods, not this new API. Copy and adapt their intent for `workspace-api` so only oauth2-proxy can call it through approved ingress; do not assume Helm `apps:` creates those policies for you. At the Java layer, authenticate requests using a verified identity (e.g. Spring Security OAuth2 resource server with Keycloak-issued JWTs; a properly verified trusted proxy identity is another specialized option). Never trust `X-Forwarded-User`, `X-Forwarded-Groups`, a JavaScript form field or cookie content provided directly by an untrusted caller. Even a valid login must be followed by authorization checks: users see only their own workspaces, and admin operations are separate. Provide CSRF defenses for cookie-authenticated state-changing API calls.

## 12. Recommended future production components

| Component | Why | Minimum acceptance test |
|---|---|---|
| Postgres or another shared database | Persist workspace metadata and audit logs. | Restart API, workspace list remains. |
| Workspace reconciler/operator | Creates real pods safely and tracks lifecycle. | API returns actual Kubernetes status. |
| PVC + StorageClass | Keep `/home/dev` data across workspace restart. | Create file, stop/start, file remains. |
| Per-user RBAC/ownership | Stop one user from changing another's workspace. | User A gets 403 for User B's workspace. |
| Namespace quotas and admission rules | Cap CPU, RAM, storage, images, privileges. | Oversized/privileged requests rejected. |
| HTTPS + secure cookies | Protect login and traffic. | No external plaintext token/cookie exchange. |
| Persistent event/audit table | Keep account of actions across restarts. | Actions can be traced to verified user. |
| Secure terminal broker (later) | Controlled WebSocket + PTY to user's own pod. | User cannot connect to someone else's pod. |
| Server-side idle reconciler | Shutdown works when browser is closed. | Pod stops after tested idle policy. |
| Separate deploy pipelines | Upgrade gateway, SSO, API, web independently. | Roll back API without changing IdP. |

Do not give the Spring API `cluster-admin` or accept raw `kubectl` commands from the browser. Use minimum RBAC scope. For a "hardware" profile, require an explicit approval and dedicated node/network isolation rather than permitting generic privileged containers.

## 13. Troubleshooting checklist

| Symptom | Likely cause | First inspection |
|---|---|---|
| IP is pending | Azure LB/subnet/permission or gateway controller issue. | `kubectl -n demoweb get svc,gateway -o wide` |
| Gateway returns 404 | No matching route/host or backend. | `kubectl -n demoweb describe httproute` |
| Login redirects forever | `publicUrl`, Keycloak issuer or callback mismatch. | `helm -n demoweb get values demoweb` |
| Login succeeds but page still shows old HTML | Chart hardcoded `web-config.yaml`; root `index.html` not deployed. | `kubectl -n demoweb get cm web-html -o yaml` |
| `/api/` returns HTML | oauth2-proxy upstream API entry missing or prefix mismatch. | `helm -n demoweb get values demoweb`; proxy logs |
| `/api/` gives 503 | Service/pods/endpoints missing or wrong port. | `kubectl -n demoweb get svc,endpointslices,pods` |
| `/api/` gives 403 | Explicit auth policy rejects call, or user not authorized. | `kubectl -n demoweb get authorizationpolicy,networkpolicy` |
| API entries disappear on restart | Sample uses in-memory map. | Add shared database. |
| Works locally, not on AKS | Ingress route, security, backend container, probes, or environment configuration. | `kubectl -n demoweb logs deploy/workspace-api` |
| Terminal appears but no real commands run | Original shell is intentionally simulated. | Build secure terminal service later. |

## 14. Suggested team delivery sequence

1. **Infrastructure owner:** identify AKS/Istio mode; render/test all three charts; verify correct namespace and public IP restrictions.
2. **Identity owner:** confirm Keycloak/OIDC, TLS and claim/role mapping; remove demo credentials; test auth bypass prevention.
3. **Java developer:** run sample Java 25 API locally, add persistence and real authorization, implement operations as explicit service methods.
4. **Web developer:** keep simulation mode, add API adapter and robust error/loading states, replace simulated terminal/boot with server data only when supported.
5. **Platform owner:** create API chart, oauth2-proxy upstream, network/mTLS/authorization policies, resource quotas, image pull and health probes.
6. **Tester:** test create/list/start/stop/delete, unauthenticated/unauthorized requests, page reload, pod restart, API rollback, ownership and PVC retention.

These are suggested **roles**, not assignments to named people. Review each phase before moving to live Kubernetes operations.

## 15. Official references

- Kubernetes concepts: https://kubernetes.io/docs/concepts/
- Kubernetes Services: https://kubernetes.io/docs/concepts/services-networking/service/
- Helm chart template guide: https://helm.sh/docs/chart_template_guide/
- Gateway API: https://gateway-api.sigs.k8s.io/
- Istio traffic management: https://istio.io/latest/docs/concepts/traffic-management/
- Istio security: https://istio.io/latest/docs/concepts/security/
- Microsoft AKS Istio add-on: https://learn.microsoft.com/en-us/azure/aks/istio-about
- Keycloak documentation: https://www.keycloak.org/documentation
- oauth2-proxy: https://oauth2-proxy.github.io/oauth2-proxy/
- Spring Boot system requirements: https://docs.spring.io/spring-boot/system-requirements.html
- Spring Security: https://docs.spring.io/spring-security/reference/

---

**Bottom line:** existing charts supply the **front door** and **badge-checking system**, plus a small protected nginx page. The separate `index.html` is a **pretend workspace school** entirely inside a browser. Java 25 Spring Boot is the planned **school office** that will make requests real. Build and validate a simple API first; only then grant a narrowly scoped server permission to create actual AKS resources.
