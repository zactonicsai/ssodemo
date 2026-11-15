{{- define "ig.name" -}}{{ .Values.gateway.name }}{{- end -}}

{{- define "ig.labels" -}}
app.kubernetes.io/name: {{ include "ig.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app: {{ include "ig.name" . }}
istio: {{ .Values.gateway.selectorLabel }}
{{- end -}}

{{- define "ig.selectorLabels" -}}
app: {{ include "ig.name" . }}
istio: {{ .Values.gateway.selectorLabel }}
{{- end -}}

{{/* label the Gateway resource selects pods by */}}
{{- define "ig.gatewaySelector" -}}
{{- if eq .Values.mode "aks-addon" -}}
istio: aks-istio-ingressgateway-{{ ternary "internal" "external" .Values.azure.internal }}
{{- else -}}
istio: {{ .Values.gateway.selectorLabel }}
{{- end -}}
{{- end -}}

{{- define "ig.gatewayNamespace" -}}
{{- if .Values.istioGateway.namespace -}}{{ .Values.istioGateway.namespace }}
{{- else if eq .Values.mode "aks-addon" -}}aks-istio-ingress
{{- else -}}{{ .Release.Namespace }}{{- end -}}
{{- end -}}

{{- define "ig.deploy" -}}{{ if eq .Values.mode "selfmanaged" }}true{{ end }}{{- end -}}
{{- define "ig.istioGateway" -}}{{ if and .Values.istioGateway.enabled (ne .Values.mode "aks-gateway-api") }}true{{ end }}{{- end -}}
{{- define "ig.gatewayAPI" -}}{{ if eq .Values.mode "aks-gateway-api" }}true{{ end }}{{- end -}}

{{/* Azure LB annotations, shared by the Service (selfmanaged) and Gateway.spec.infrastructure (aks-gateway-api) */}}
{{- define "ig.azureAnnotations" -}}
{{- if .Values.azure.internal }}
service.beta.kubernetes.io/azure-load-balancer-internal: "true"
{{- with .Values.azure.internalSubnet }}
service.beta.kubernetes.io/azure-load-balancer-internal-subnet: {{ . | quote }}
{{- end }}
{{- end }}
{{- with .Values.azure.publicIPName }}
service.beta.kubernetes.io/azure-pip-name: {{ . | quote }}
{{- end }}
{{- with .Values.azure.publicIPResourceGroup }}
service.beta.kubernetes.io/azure-load-balancer-resource-group: {{ . | quote }}
{{- end }}
{{- with .Values.azure.dnsLabel }}
service.beta.kubernetes.io/azure-dns-label-name: {{ . | quote }}
{{- end }}
{{- if .Values.azure.healthProbe.enabled }}
service.beta.kubernetes.io/azure-load-balancer-health-probe-protocol: "http"
service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path: {{ .Values.azure.healthProbe.path | quote }}
service.beta.kubernetes.io/port_{{ .Values.service.ports.http }}_health-probe_port: {{ .Values.service.ports.status | quote }}
service.beta.kubernetes.io/port_{{ .Values.service.ports.https }}_health-probe_port: {{ .Values.service.ports.status | quote }}
{{- end }}
{{- if .Values.azure.idleTimeoutMinutes }}
service.beta.kubernetes.io/azure-load-balancer-tcp-idle-timeout: {{ .Values.azure.idleTimeoutMinutes | quote }}
{{- end }}
{{- with .Values.service.extraAnnotations }}
{{ toYaml . }}
{{- end }}
{{- end -}}
