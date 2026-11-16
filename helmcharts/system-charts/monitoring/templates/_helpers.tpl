{{/*
Common labels for resources rendered by this wrapper chart.
*/}}
{{- define "monitoring.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: monitoring
{{- end }}

{{/*
Labels for PrometheusRules. release: monitoring is the selector contract of the
Prometheus in this chart (prometheusSpec.ruleSelector).
*/}}
{{- define "monitoring.ruleLabels" -}}
{{ include "monitoring.labels" . }}
release: monitoring
{{- end }}
