{{/*
Common labels for every object. Call with the root context: include "misc.labels" $
*/}}
{{- define "misc.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: platform
app.kubernetes.io/instance: {{ .Release.Name }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Error message for a per-environment setting that is missing.
Call with: list "<values path>" <environment key>
*/}}
{{- define "misc.missingEnv" -}}
{{- printf "%s.%s is not set: every key in environments needs an entry in %s" (index . 0) (index . 1) (index . 0) -}}
{{- end }}
