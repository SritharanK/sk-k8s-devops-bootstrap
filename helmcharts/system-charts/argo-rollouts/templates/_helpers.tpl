{{/*
Labels for resources defined in this wrapper chart. The prefix differs from the
upstream chart's "argo-rollouts." templates, which share the same template namespace.
*/}}
{{- define "rollouts-platform.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: argo-rollouts
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}
