{{/*
Helpers for the tenant chart.
*/}}

{{/*
Tenant name, checked again here so that a render without the schema (for
example helm template --skip-schema-validation) still cannot leave tenant-*.
*/}}
{{- define "tenant.name" -}}
{{- $name := required "name is required" .Values.name -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $name) -}}
{{- fail (printf "name %q is not a DNS label" $name) -}}
{{- end -}}
{{- if gt (len $name) 20 -}}
{{- fail (printf "name %q is longer than 20 characters" $name) -}}
{{- end -}}
{{- $name -}}
{{- end -}}

{{/*
Environments as a JSON list, checked against the allowed set.
*/}}
{{- define "tenant.environments" -}}
{{- $envs := .Values.environments | default list -}}
{{- if not $envs -}}
{{- fail "environments must not be empty" -}}
{{- end -}}
{{- range $envs -}}
{{- if not (has . (list "dev" "stage" "prod")) -}}
{{- fail (printf "unknown environment %q" .) -}}
{{- end -}}
{{- end -}}
{{- $envs | uniq | toJson -}}
{{- end -}}

{{/*
Namespace of one environment.
Usage: {{ include "tenant.namespace" (list . "dev") }}
*/}}
{{- define "tenant.namespace" -}}
{{- printf "tenant-%s-%s" (include "tenant.name" (index . 0)) (index . 1) -}}
{{- end -}}

{{/*
True (non-empty) when the destination is a cluster registered in a hub.
*/}}
{{- define "tenant.isRemote" -}}
{{- $d := .Values.cluster.destination | default dict -}}
{{- if and $d.name (ne $d.name "in-cluster") -}}true{{- end -}}
{{- end -}}

{{/*
Argo CD destination without the namespace, same rule as the root chart.
*/}}
{{- define "tenant.destination" -}}
{{- if include "tenant.isRemote" . -}}
name: {{ .Values.cluster.destination.name }}
{{- else -}}
server: https://kubernetes.default.svc
{{- end -}}
{{- end -}}

{{/*
Name of the tenant AppProject, prefixed with the cluster name in hub mode
like every Argo CD object of the root chart.
*/}}
{{- define "tenant.projectName" -}}
{{- $name := printf "tenant-%s" (include "tenant.name" .) -}}
{{- if include "tenant.isRemote" . -}}
{{- $name = printf "%s-%s" (required "cluster.name is required in hub mode" .Values.cluster.name) $name -}}
{{- end -}}
{{- $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Recommended labels for every object.
*/}}
{{- define "tenant.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: tenants
tenant: {{ include "tenant.name" . }}
{{- end -}}

{{/*
Labels for an object in one environment namespace.
Usage: {{ include "tenant.envLabels" (list . "dev") }}
*/}}
{{- define "tenant.envLabels" -}}
{{ include "tenant.labels" (index . 0) }}
environment: {{ index . 1 }}
{{- end -}}

{{/*
A quantity or count as a quoted string. Helm reads YAML numbers from values
files as float64, which would print 1e+06; whole numbers are printed as
integers instead.
*/}}
{{- define "tenant.quantity" -}}
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
