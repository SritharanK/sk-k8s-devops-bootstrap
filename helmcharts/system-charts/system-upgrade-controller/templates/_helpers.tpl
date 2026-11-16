{{/*
Common labels. Object names, the ServiceAccount and the pod selector keep the upstream values,
because upgrade Plans reference the ServiceAccount by name and the controller reads its own
name from the upgrade.cattle.io/controller pod label.
*/}}
{{- define "suc.labels" -}}
app.kubernetes.io/name: system-upgrade-controller
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* ServiceAccount used by the controller and by the upgrade Jobs (upstream name). */}}
{{- define "suc.serviceAccountName" -}}
system-upgrade
{{- end }}
