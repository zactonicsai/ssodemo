# SSO for web apps behind the Istio gateway (Keycloak + oauth2-proxy)

Everything runs in namespace **`demoweb`** on your AKS cluster and is reachable from any browser.

```
browser ──► Azure LB ──► Istio ingress gateway (Gateway API, class approuting-istio)
                              │
                              ├─ /auth/*   ──► keycloak:8080        (login pages, tokens, admin console)
                              │
                              └─ /*        ──► oauth2-proxy:4180    ── has a valid session cookie? ──► web:80 (nginx)
                                                   │                                                   ▲
                                                   └─ no → 302 to Keycloak login → /oauth2/callback ───┘
                                             (mTLS; web accepts only oauth2-proxy's identity — AuthorizationPolicy)
```

| Component | Role | Chart objects |
|---|---|---|
| **Istio gateway** | public entry point, Azure LB | `helm/istio-ingress-azure` (release `demoweb-gateway`) |
| **Keycloak** (`start-dev`, realm imported on boot) | identity provider: users, OIDC client, SAML client | Deployment, Service, realm Secret, post-install Job |
| **oauth2-proxy** | enforces login; one cookie for every app behind it; passes identity headers upstream | Deployment, Service, ConfigMap, Secret |
| **web** (Python, `files/web/app.py` + `index.html`) | the portal page + `/api` stub functions; reads identity/groups from the oauth2-proxy headers | Deployment (python:3.12-slim), Service, ConfigMap |
| **Routes** | `HTTPRoute`s (Gateway API) or one `VirtualService` (Istio API) on the gateway | `routes.yaml` |
| **Mesh policies** | `PeerAuthentication` STRICT, `AuthorizationPolicy` (web only from oauth2-proxy), `VirtualService` + `DestinationRule` for web (timeouts, retries, outlier detection, subsets) | `mesh-policies.yaml` |

## Deploy (two steps, independent)

```bash
az aks get-credentials -g <rg> -n <cluster>
scripts/install-platform.sh        # 1+2: gateway, then Keycloak + PostgreSQL (realm, groups, users)
scripts/test-keycloak.sh           #      discovery through the gateway, admin login, groups/users
apps/portal/install.sh             # 3:   web site + API; refuses to run unless Keycloak is installed and answering
apps/portal/test.sh                #      login flow + bypass check
```

Options for the platform: `--allow-my-ip` (only your laptop can reach the LB), `DNS_LABEL=demoweb-sso`
(stable hostname instead of the raw IP — recommended), `PUBLIC_URL=https://sso.example.com` behind your own DNS/TLS,
`KC_VALUES=my-keycloak.yaml` for users/groups/Postgres size. Passwords are generated once into `.demoweb/<context>.env`
(platform) and `.demoweb/<context>-portal.env` (app); delete a file to rotate.

Keycloak runs in production `start` mode on PostgreSQL (StatefulSet, 8Gi PVC). The realm JSON is imported only on the
**first** start; afterwards the database is the source of truth and you manage users/groups/clients in the admin
console (or set `realm.reimportOnUpgrade=true` to overwrite on every start — demo only). Uninstalling Keycloak keeps
the PVC unless `--purge`, so a reinstall comes back with all users and clients.

Each application registers its **own** OIDC client through a Helm hook Job using the admin Secret, and removes it on
uninstall — so the Keycloak chart contains no app-specific configuration.

## Logging in

1. Open `http://<IP>/` → redirected to Keycloak (`/auth/realms/demoweb/...`).
2. Sign in with **demo / demo123** (values `keycloak.realm.user`).
3. You land on the nginx page showing your username/e-mail; the `_demoweb_sso` cookie (8 h, refreshed every 5 min) now
   grants access to *every* path behind oauth2-proxy. "Sign out" ends both the proxy session and the Keycloak session.

Keycloak admin console: `http://<IP>/auth/admin/` — user `admin`, password in `.demoweb/<context>.env`
(`kubectl -n demoweb get secret keycloak-admin -o jsonpath='{.data.password}' | base64 --decode`).

## The portal app and its API

`apps/portal/helm/portal/files/web/` holds the whole web tier and is shipped to the cluster as a ConfigMap, so editing
either file and re-running `apps/portal/install.sh` rolls it out — no image build, no registry:

* `index.html` — the Developer Workspaces portal. Tailwind is compiled **inline** (no external `src`/`href` at all,
  works offline). It calls the API for identity, catalog, workspaces and events; create/start/stop/delete POST to
  the API; the boot animation and the shell are simulated in the browser until the backend exists. The **API** tab
  lists every function and lets you call it.
* `app.py` — standard-library Python (`http.server`, no pip). `ROUTES` maps `METHOD regex` → function; each function
  returns `(status, json)`. All of them return **static JSON** today. To build one out, replace its body (e.g. call
  kubectl/helm or the Kubernetes API) — the routing, auth check and the page stay as they are. Add a function by
  adding it to `ROUTES`; the API tab picks it up from `GET /api`.

| Function | Today |
|---|---|
| `GET /api/me` | user, e-mail, groups, `isAdmin`, namespace — from `X-Forwarded-*` headers |
| `GET /api/catalog` | languages/tools/sizes/profiles; `hardware` profile only for the admin group |
| `GET /api/groups` | the groups the portal knows and what they unlock |
| `GET/POST /api/workspaces`, `GET /api/workspaces/{name}`, `/logs` | sample list; create validates and echoes |
| `POST /api/workspaces/{name}/{start|stop|delete}`, `DELETE …` | acknowledgement + the command the real version will run |
| `GET /api/admin/workspaces` | admins only (403 otherwise) |
| `GET /api/health`, `GET /api` | public: health, and the function index |

Identity is trusted from headers, so the app must only be reachable through oauth2-proxy: it answers **401** when the
headers are missing (`web.requireAuth`), and the NetworkPolicy / AuthorizationPolicy keep other pods from reaching it
directly (a pod that could reach it could otherwise forge the headers).

## Groups

The realm has groups **`developers`** and **`admins`** (values `keycloak.realm.groups`). `demo` is in both; `dev2 /
dev2pass` is in `developers` only (`keycloak.realm.extraUsers`). Keycloak puts group membership in the token
(`groups` claim, OIDC client mapper) and the SAML assertion (`groups` attribute); oauth2-proxy forwards it as
`X-Forwarded-Groups` and only lets members of `oauth2Proxy.allowedGroups` (default `[developers]`) log in at all.
In the portal: `admins` unlocks the hardware profile and `/api/admin/*`. Manage membership in Keycloak → Groups;
add a group to `keycloak.realm.groups` and redeploy to create it.

## Adding more services behind the same login (one app = one directory)

Copy `apps/portal` to `apps/<name>`, change `path` (e.g. `/grafana/`), `client.id`, `oauth2Proxy.cookieName`,
`allowedGroups`, and the upstream (keep the bundled Python web, or drop the `web` template and point
`upstreams` at an existing Service in any namespace). Run `apps/<name>/install.sh`. The app gets its own OIDC client,
cookie and route; the user has one Keycloak session, so moving between apps needs no second login.

Restrict who may use an app with `oauth2Proxy.allowedGroups` (Keycloak groups) — e.g. `[admins]` for an ops tool.
The app receives identity in `X-Forwarded-User`, `X-Forwarded-Email`, `X-Forwarded-Preferred-Username`,
`X-Forwarded-Groups`. Per-app traffic control (timeouts, retries, canary subsets) is in each app's `policies.yaml`
(VirtualService/DestinationRule, rendered when the Istio CRDs exist).

## SAML

The browser login the gateway enforces is OIDC: Envoy/oauth2-proxy can validate OIDC tokens but nobody terminates
SAML at an ingress proxy. SAML still works with the same realm and users for applications that are themselves SAML
service providers (Jenkins, GitLab, Grafana, Tableau, ...):

* IdP metadata: `http://<IP>/auth/realms/demoweb/protocol/saml/descriptor`
* A ready client `nginx-saml` (values `keycloak.realm.samlClientId`) with signed assertions, POST binding, NameID =
  e-mail, `email` and `Role` attributes. Change its `redirectUris` / add the SP's own metadata in the admin console
  (Clients → nginx-saml), or add further SAML clients the same way.
* Such an app can sit behind the gateway *without* oauth2-proxy: route it directly (another `HTTPRoute`) and let it
  do its own SAML dance against Keycloak — the user already has a Keycloak session from the OIDC login, so it is
  still single sign-on.

## Istio APIs vs. Gateway-API-only managed Istio

Some Azure-managed Istio installs (istiod in `aks-istio-system` with GatewayClass `approuting-istio`) ship **no
`networking.istio.io` / `security.istio.io` CRDs** — only the Kubernetes Gateway API. The chart checks the API server
(`.Capabilities.APIVersions.Has`) and:

| Cluster | Routes | Pod access control | Traffic control |
|---|---|---|---|
| Gateway-API-only managed Istio | `HTTPRoute` | `NetworkPolicy` (web ← oauth2-proxy only; needs a network-policy engine: `az aks show … --query networkProfile.networkPolicy`, enable with `az aks update --network-policy azure` / cilium) | `HTTPRoute` filters/timeouts; no VirtualService |
| Classic add-on / self-managed Istio (CRDs present) | `HTTPRoute` or `VirtualService` | `NetworkPolicy` **and** `PeerAuthentication` STRICT + `AuthorizationPolicy` (identity-based, needs sidecars) | `VirtualService` + `DestinationRule` (timeouts, retries, outlier detection, subsets/canary) |

In both cases the login is enforced for everything coming through the gateway; the difference is only how much
in-cluster traffic to the web pods is restricted. `apps/portal/test.sh` step 4 tells you which you have.

## Why these settings

* **Keycloak over plain HTTP on an IP**: `--hostname=http://<IP>/auth --hostname-strict=false --proxy-headers=xforwarded`
  plus `sslRequired=NONE` on the `master` and `demoweb` realms (set by the post-install Job). Switch to HTTPS by
  putting TLS on the gateway (`gatewayAPI.tls` in the gateway chart) and setting `PUBLIC_URL=https://...`.
* **Health probes on port 9000**: Keycloak 26 serves `/health/*` on the management interface, not 8080 — probing 8080
  gives 404s and a CrashLoopBackOff.
* **`--hostname-backchannel-dynamic=true` + internal URLs** in oauth2-proxy (`redeem_url`, `oidc_jwks_url`): the
  token exchange goes pod-to-pod over mTLS instead of hair-pinning through the public LB, while the browser-facing
  `login_url` and the token issuer use the public URL.
* **`start-dev` + H2 on an emptyDir**: a demo. Realm and users are re-imported from the chart on every restart, so
  anything created in the admin console is lost on pod restart. For real use switch to `start` with Postgres
  (and remove `--hostname-strict=false`).

## Troubleshooting

| Symptom | Look at |
|---|---|
| Browser loops between `/` and Keycloak | `publicUrl` ≠ what the browser uses (IP changed? DNS label?). `helm -n demoweb get values portal` / `keycloak` and re-run the install scripts. |
| Keycloak "Invalid parameter: redirect_uri" | same cause: the OIDC client's redirect URI is `<publicUrl>/oauth2/callback`. |
| oauth2-proxy 500 "Error redeeming code" | `kubectl -n demoweb logs deploy/oauth2-proxy` — usually client secret mismatch (rotate by deleting `.demoweb/*.env` and redeploying). |
| Keycloak pod not Ready | `kubectl -n demoweb logs deploy/keycloak` — realm import errors show here; probes are on 9000. |
| Page 403 "RBAC: access denied" | something other than oauth2-proxy reached web — intended; check `AuthorizationPolicy web-only-via-oauth2-proxy`. |
| Direct in-cluster call to web **succeeds** in `apps/portal/test.sh` step 4 | namespace not injected (`kubectl get ns demoweb --show-labels`), or `policies.networkPolicy=false`. |
| `HTTPRoute` not Accepted | `kubectl -n demoweb get httproute -o yaml` status; the Gateway must allow routes from that namespace. |
