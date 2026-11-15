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
| **web** (nginx) | the protected page; shows who is logged in | Deployment, Service, ConfigMap |
| **Routes** | `HTTPRoute`s (Gateway API) or one `VirtualService` (Istio API) on the gateway | `routes.yaml` |
| **Mesh policies** | `PeerAuthentication` STRICT, `AuthorizationPolicy` (web only from oauth2-proxy), `VirtualService` + `DestinationRule` for web (timeouts, retries, outlier detection, subsets) | `mesh-policies.yaml` |

## Deploy

```bash
az aks get-credentials -g <rg> -n <cluster>
scripts/deploy-demoweb.sh                      # ~5 min; prints the URL and credentials at the end
scripts/test-sso.sh                            # proves login is required and works, and that bypass is blocked
```

Options: `--allow-my-ip` (only your laptop can reach the LB), `DNS_LABEL=demoweb-sso scripts/deploy-demoweb.sh`
(stable hostname `demoweb-sso.<region>.cloudapp.azure.com` instead of the raw IP — recommended; the IP changes if the
gateway is recreated), `PUBLIC_URL=https://sso.example.com` when you put your own DNS/TLS in front.

Secrets (OIDC client secret, cookie secret, Keycloak admin password) are generated once and kept in
`.demoweb/<kube-context>.env` so re-running upgrades in place. Delete that file to rotate them.

## Logging in

1. Open `http://<IP>/` → redirected to Keycloak (`/auth/realms/demoweb/...`).
2. Sign in with **demo / demo123** (values `keycloak.realm.user`).
3. You land on the nginx page showing your username/e-mail; the `_demoweb_sso` cookie (8 h, refreshed every 5 min) now
   grants access to *every* path behind oauth2-proxy. "Sign out" ends both the proxy session and the Keycloak session.

Keycloak admin console: `http://<IP>/auth/admin/` — user `admin`, password in `.demoweb/<context>.env`
(`kubectl -n demoweb get secret keycloak-admin -o jsonpath='{.data.password}' | base64 --decode`).

## Adding more services behind the same login

Add an entry to `apps` (values or a `-f my-values.yaml` passed with `VALUES_FILE=`), re-run `scripts/deploy-demoweb.sh`:

```yaml
apps:
  - { name: web,  path: /,      service: web,    port: 80 }                      # keep: owns "/"
  - { name: api,  path: /api/,  service: my-api, namespace: backend, port: 8080 }
  - { name: grafana, path: /grafana/, service: grafana, namespace: monitoring, port: 3000 }
```

Each becomes an oauth2-proxy upstream; the longest matching path wins; the path is forwarded unchanged (serve the
app under that prefix, e.g. Grafana `GF_SERVER_ROOT_URL=…/grafana/ GF_SERVER_SERVE_FROM_SUB_PATH=true`). The app
receives the identity in headers: `X-Forwarded-User`, `X-Forwarded-Email`, `X-Forwarded-Preferred-Username`,
`X-Forwarded-Groups` (realm roles). No code change in the app is needed for login.

To make the new service accept traffic **only** via oauth2-proxy too, copy the `web` `AuthorizationPolicy` with a
selector for that app (its namespace must be sidecar-injected: `kubectl label ns backend istio-injection=enabled`).

Restrict who may log in: set `oauth2Proxy.allowedRole: web-user` — the realm has that role, the demo user holds it,
and new users get in only once you assign it in Keycloak (Users → Role mapping).

Per-app traffic control is where the mesh-side **VirtualService/DestinationRule** come in: copy `mesh-policies.yaml`'s
`web` pair for the new service to set timeouts, retries, circuit breaking, or to run a `v2` subset and shift weight
(canary) — oauth2-proxy → service traffic obeys them because both sides have sidecars.

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
| Browser loops between `/` and Keycloak | `publicUrl` ≠ what the browser uses (IP changed? DNS label?). `helm -n demoweb get values demoweb` and re-run deploy. |
| Keycloak "Invalid parameter: redirect_uri" | same cause: the OIDC client's redirect URI is `<publicUrl>/oauth2/callback`. |
| oauth2-proxy 500 "Error redeeming code" | `kubectl -n demoweb logs deploy/oauth2-proxy` — usually client secret mismatch (rotate by deleting `.demoweb/*.env` and redeploying). |
| Keycloak pod not Ready | `kubectl -n demoweb logs deploy/keycloak` — realm import errors show here; probes are on 9000. |
| Page 403 "RBAC: access denied" | something other than oauth2-proxy reached web — intended; check `AuthorizationPolicy web-only-via-oauth2-proxy`. |
| Direct in-cluster call to web **succeeds** in `test-sso.sh` step 4 | namespace not injected (`kubectl get ns demoweb --show-labels`), or `mesh.lockdownWeb=false`. |
| `HTTPRoute` not Accepted | `kubectl -n demoweb get httproute -o yaml` status; the Gateway must allow routes from that namespace. |
