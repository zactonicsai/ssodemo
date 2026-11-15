{{- define "kc.labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}
{{- define "kc.url" -}}{{ .Values.publicUrl }}{{ .Values.relativePath }}{{- end -}}
{{- define "kc.internalUrl" -}}http://keycloak.{{ .Release.Namespace }}.svc.cluster.local:8080{{ .Values.relativePath }}{{- end -}}
{{- define "kc.gwNs" -}}{{ (split "/" .Values.gateway)._0 }}{{- end -}}
{{- define "kc.gwName" -}}{{ (split "/" .Values.gateway)._1 }}{{- end -}}
{{- define "kc.jdbc" -}}
{{- if .Values.postgres.enabled -}}jdbc:postgresql://keycloak-postgres.{{ .Release.Namespace }}.svc.cluster.local:5432/{{ .Values.postgres.database }}
{{- else -}}{{ .Values.postgres.externalUrl }}{{- end -}}
{{- end -}}
