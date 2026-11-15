#!/usr/bin/env bash
# Prove the SSO works end to end from this laptop, the way a browser would:
#   1. anonymous GET /          → redirected to Keycloak's login page
#   2. submit the login form    → redirected back through /oauth2/callback with a session cookie
#   3. GET / with the cookie    → 200, the nginx page shows the logged-in user
#   4. (in-cluster) direct call to the web Service without going through oauth2-proxy → refused
#
#   scripts/test-sso.sh [--user demo] [--password demo123] [--url http://IP]
source "$(dirname "$0")/lib.sh"
need kubectl helm curl python3
NAMESPACE="${NAMESPACE:-demoweb}"; RELEASE="${RELEASE:-demoweb}"
USER_="" PASS_="" URL=""
while [ $# -gt 0 ]; do case "$1" in
  --user) USER_="$2"; shift ;; --password) PASS_="$2"; shift ;; --url) URL="$2"; shift ;;
  -h|--help) sed -n '2,9p' "$0"; exit 0 ;; *) die "unknown flag $1" ;;
esac; shift; done

VALS="$(helm -n "$NAMESPACE" get values "$RELEASE" -a -o json)" || die "release $RELEASE not found in $NAMESPACE"
URL="${URL:-$(python3 -c 'import sys,json;print(json.load(sys.stdin)["publicUrl"])' <<<"$VALS")}"
USER_="${USER_:-$(python3 -c 'import sys,json;print(json.load(sys.stdin)["keycloak"]["realm"]["user"]["username"])' <<<"$VALS")}"
PASS_="${PASS_:-$(python3 -c 'import sys,json;print(json.load(sys.stdin)["keycloak"]["realm"]["user"]["password"])' <<<"$VALS")}"
JAR="$(mktemp)"; trap 'rm -f "$JAR"' EXIT
C=(curl -s -m 20 -c "$JAR" -b "$JAR")

info "1. anonymous request to $URL/"
CODE="$("${C[@]}" -o /dev/null -w '%{http_code}' "$URL/")"
[ "$CODE" = 302 ] || [ "$CODE" = 403 ] || die "expected a redirect to login, got HTTP $CODE (is the deployment finished? kubectl -n $NAMESPACE get pods)"
ok "HTTP $CODE — not allowed in without a session"

info "2. following the redirect to Keycloak and submitting the login form ($USER_)"
LOGIN_HTML="$("${C[@]}" -L "$URL/oauth2/start?rd=%2F")"
ACTION="$(python3 - "$LOGIN_HTML" <<'EOF'
import sys,re,html
m=re.search(r'<form[^>]+id="kc-form-login"[^>]+action="([^"]+)"', sys.argv[1]) or re.search(r'action="([^"]+login-actions/authenticate[^"]*)"', sys.argv[1])
print(html.unescape(m.group(1)) if m else "")
EOF
)"
[ -n "$ACTION" ] || { echo "$LOGIN_HTML" | head -c 600; die "no Keycloak login form found (see HTML above). Keycloak hostname/publicUrl mismatch?"; }
ok "got Keycloak login form"
FINAL="$("${C[@]}" -L -o /tmp/sso-page.html -w '%{http_code} %{url_effective}' --data-urlencode "username=$USER_" --data-urlencode "password=$PASS_" --data-urlencode "credentialId=" "$ACTION")"
CODE="${FINAL%% *}"; WHERE="${FINAL#* }"
[ "$CODE" = 200 ] || { grep -o 'kc-feedback-text[^<]*<[^>]*>[^<]*' /tmp/sso-page.html | head -2; die "login did not end on the app (HTTP $CODE at $WHERE)"; }
grep -q "Logged in" /tmp/sso-page.html || { head -c 400 /tmp/sso-page.html; die "ended with 200 at $WHERE but not on the protected page"; }
ok "logged in → $WHERE"
grep -o 'You are <strong>[^<]*</strong> (<code>[^<]*</code>)' /tmp/sso-page.html | sed 's/<[^>]*>//g;s/^/    page says: /'
grep -c "_demoweb_sso" "$JAR" >/dev/null && ok "session cookie _demoweb_sso set"

info "3. second request with the cookie only"
CODE="$("${C[@]}" -o /dev/null -w '%{http_code}' "$URL/")"; [ "$CODE" = 200 ] && ok "HTTP 200 without re-login (SSO session)" || die "HTTP $CODE"
info "   and the Keycloak realm is public (needed for login):"
CODE="$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$URL/auth/realms/demoweb/.well-known/openid-configuration")"; [ "$CODE" = 200 ] && ok "OIDC discovery 200" || warn "discovery HTTP $CODE"

info "4. bypass attempt: calling the web Service directly from a pod without the oauth2-proxy identity"
OUT="$(kubectl -n "$NAMESPACE" run sso-bypass-test --rm -i --restart=Never --quiet --image=curlimages/curl:8.11.1 \
  --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"false"}}}' -- \
  -s -m 8 -o /dev/null -w '%{http_code}' http://web/ 2>/dev/null || echo "conn-failed")"
case "$OUT" in 200) die "web answered 200 to a direct call — lockdown NOT effective (is the namespace injected? mesh.lockdownWeb/mtlsStrict true?)" ;;
  *) ok "direct call refused ($OUT) — only oauth2-proxy can reach the web pods" ;; esac

ok "SSO test passed"
echo "    browser: $URL/   ($USER_ / $PASS_)"
