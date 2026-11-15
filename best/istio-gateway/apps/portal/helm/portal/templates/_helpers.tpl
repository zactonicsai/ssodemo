{{- define "app.name" -}}{{ .Release.Name }}{{- end -}}
{{- define "app.labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}
{{- define "app.web" -}}{{ .Release.Name }}-web{{- end -}}
{{- define "app.proxy" -}}{{ .Release.Name }}-oauth2-proxy{{- end -}}
{{- define "app.gwNs" -}}{{ (split "/" .Values.gateway)._0 }}{{- end -}}
{{- define "app.gwName" -}}{{ (split "/" .Values.gateway)._1 }}{{- end -}}
{{- define "app.issuer" -}}{{ .Values.keycloak.publicUrl }}/realms/{{ .Values.keycloak.realm }}{{- end -}}
{{- define "app.issuerInternal" -}}{{ .Values.keycloak.internalUrl }}/realms/{{ .Values.keycloak.realm }}{{- end -}}
{{- define "app.callback" -}}{{ .Values.publicUrl }}{{ trimSuffix "/" .Values.path }}/oauth2/callback{{- end -}}
{{- define "app.logoutUrl" -}}{{ trimSuffix "/" .Values.path }}/oauth2/sign_out?rd={{ include "app.issuer" . }}/protocol/openid-connect/logout?client_id={{ .Values.client.id }}%26post_logout_redirect_uri={{ .Values.publicUrl }}{{ .Values.path }}{{- end -}}
