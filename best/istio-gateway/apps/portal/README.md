# apps/portal — Developer Workspaces web site + API

An application that plugs into the platform (`scripts/install-platform.sh`: gateway + Keycloak). Self-contained:
its own Helm chart, install/uninstall/test scripts, and its own OIDC client that it registers in Keycloak.

```
apps/portal/
├── helm/portal/
│   ├── files/web/app.py        Python (stdlib only) web server + /api stub functions
│   ├── files/web/index.html    the portal page (Tailwind inlined, no external resources)
│   └── templates/              oauth2-proxy, web, HTTPRoute/VirtualService, NetworkPolicy (+ Istio policies when CRDs exist),
│                               keycloak-client.yaml: Jobs that create (post-install) / delete (pre-delete) the OIDC client
├── install.sh                  checks Keycloak is installed and answering, generates secrets, helm upgrade --install
├── uninstall.sh                helm uninstall (the pre-delete Job removes the client from Keycloak)
└── test.sh                     browser-like login from your laptop + in-cluster bypass check
```

## Use

```bash
scripts/install-platform.sh        # once (gateway + Keycloak). install.sh refuses to run without it.
apps/portal/install.sh             # → http://<IP>/   login demo/demo123 (developers+admins) or dev2/dev2pass (developers)
apps/portal/test.sh
apps/portal/uninstall.sh
```

`install.sh` reads everything it needs from the Keycloak release (`helm get values keycloak`): the public URL,
realm, gateway and route kind — so there is nothing to type twice. Secrets go to `.demoweb/<context>-portal.env`.

## What happens on install

1. `helm upgrade --install portal` creates oauth2-proxy (login enforcement), the web Deployment (python:3.12-slim
   running `app.py` + `index.html` from a ConfigMap), a Service, the route for `path` (`/`) on the gateway, and a
   NetworkPolicy so the web pods accept traffic only from this release's oauth2-proxy.
2. The **post-install Job** logs in to Keycloak with the admin Secret (`keycloak-admin`, created by the keycloak chart),
   creates or updates OIDC client **`portal`** (redirect `<publicUrl>/oauth2/callback`, PKCE, `groups` + `roles`
   claim mappers). Idempotent: re-running install updates it.
3. On `uninstall.sh`, the **pre-delete Job** deletes the client again. Keycloak is left clean.

## Adding another application

Copy this directory, then change in `helm/<app>/values.yaml` (or via `--set`): `path` (e.g. `/grafana/`),
`client.id`, `oauth2Proxy.cookieName`, `allowedGroups`, and point `upstreams`/the web Deployment at your service
(or drop the `web` template and set the upstream to an existing Service). Run its `install.sh`. Every app gets its
own OIDC client, cookie and route; the user logs in to Keycloak once and all apps accept the session (SSO).

For apps that speak SAML natively, the realm already exposes an IdP: `<publicUrl>/auth/realms/demoweb/protocol/saml/descriptor`
(client `demoweb-saml`, adjust in the admin console).

## The API

`GET /api` lists every function. All return static JSON today; each is one Python function + one `ROUTES` entry in
`app.py`. Identity comes from oauth2-proxy headers (`X-Forwarded-User/-Email/-Groups`); the API answers 401 without
them. Group `admins` (values `web.adminGroup`) unlocks the hardware profile and `/api/admin/*`. See the **API** tab
in the portal for live calls.
