{{/*
Common labels.
*/}}
{{- define "kargo-pipelines.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: kargo-pipelines
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Kargo Project (and namespace) of an app.
Usage: {{ include "kargo-pipelines.project" (list $ $app.name) }}
*/}}
{{- define "kargo-pipelines.project" -}}
{{- $root := index . 0 -}}
{{- printf "%s%s" $root.Values.projectPrefix (index . 1) | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/*
Annotations of objects inside a Project namespace: after the Project, and
with the Kargo CRDs from the kargo Application.
Usage: {{ include "kargo-pipelines.annotations" "1" }}
*/}}
{{- define "kargo-pipelines.annotations" -}}
argocd.argoproj.io/sync-wave: {{ . | quote }}
argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
{{- end }}

{{/*
Settings of a stage by name; unknown names are manual stages that push
directly.
*/}}
{{- define "kargo-pipelines.stage" -}}
{{- $root := index . 0 -}}
{{- $name := index . 1 -}}
{{- $defaults := dict "autoPromote" false "pullRequest" false -}}
{{- toYaml (mergeOverwrite $defaults (deepCopy (get $root.Values.stages $name | default dict))) -}}
{{- end }}
