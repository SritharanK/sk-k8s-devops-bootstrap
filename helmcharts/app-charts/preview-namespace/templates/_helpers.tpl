{{/*
Helpers for the preview-namespace chart.
*/}}

{{/*
Labels for every object. pull-request only when pullRequest is set.
*/}}
{{- define "preview-namespace.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: previews
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- with .Values.pullRequest }}
pull-request: {{ include "preview-namespace.quantity" . }}
{{- end }}
{{- end -}}

{{/*
A quantity, count or number as a quoted string. Helm reads YAML numbers from
values files as float64, which would print 1e+06; whole numbers are printed
as integers instead.
*/}}
{{- define "preview-namespace.quantity" -}}
{{- if or (kindIs "float64" .) (kindIs "int" .) (kindIs "int64" .) -}}
{{- if eq (float64 .) (floor .) -}}
{{- int64 . | toString | quote -}}
{{- else -}}
{{- . | toString | quote -}}
{{- end -}}
{{- else -}}
{{- . | toString | quote -}}
{{- end -}}
{{- end -}}
