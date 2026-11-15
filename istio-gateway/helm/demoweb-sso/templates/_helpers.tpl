{{- define "sso.labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "sso.gwNs" -}}{{ (split "/" .Values.gateway)._0 }}{{- end -}}
{{- define "sso.gwName" -}}{{ (split "/" .Values.gateway)._1 }}{{- end -}}
{{- define "sso.kcUrl" -}}{{ .Values.publicUrl }}{{ .Values.keycloak.relativePath }}{{- end -}}
{{- define "sso.kcInternal" -}}http://keycloak.{{ .Release.Namespace }}.svc.cluster.local:8080{{ .Values.keycloak.relativePath }}{{- end -}}
{{- define "sso.issuer" -}}{{ include "sso.kcUrl" . }}/realms/{{ .Values.keycloak.realm.name }}{{- end -}}
{{- define "sso.issuerInternal" -}}{{ include "sso.kcInternal" . }}/realms/{{ .Values.keycloak.realm.name }}{{- end -}}
