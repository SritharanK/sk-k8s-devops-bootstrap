{{/*
Label helpers. All of them expect the merged context built by common.render
and return YAML maps without indentation.
*/}}

{{/*
helm.sh/chart value: <chart>-<version>, with "+" replaced by "_".
*/}}
{{- define "common.labels.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
app.kubernetes.io/version value: image.tag when set, else the chart
appVersion. Characters that are not valid in a label value are replaced with
"_", the result is truncated to 63 characters and trimmed so it starts and
ends with an alphanumeric character. Empty when nothing is left.
*/}}
{{- define "common.labels.version" -}}
{{- $tag := index .Values.image "tag" -}}
{{- $version := "" -}}
{{- if include "common.util.isSet" $tag -}}
{{- $version = toString $tag -}}
{{- else if .Chart.AppVersion -}}
{{- $version = toString .Chart.AppVersion -}}
{{- end -}}
{{- regexReplaceAll "[^A-Za-z0-9_.-]" $version "_" | trunc 63 | trimAll "-_." -}}
{{- end -}}

{{/*
Selector labels. Only immutable identity labels, never a version.
*/}}
{{- define "common.labels.selector" -}}
{{- $labels := dict "app.kubernetes.io/name" (include "common.names.name" .) "app.kubernetes.io/instance" (.Release.Name | trunc 63 | trimSuffix "-") -}}
{{- toYaml $labels -}}
{{- end -}}

{{/*
Standard labels on every object: commonLabels, then the recommended
app.kubernetes.io labels and helm.sh/chart. The standard labels win over
commonLabels with the same key.
*/}}
{{- define "common.labels.standard" -}}
{{- $labels := include "common.util.stringMap" .Values.commonLabels | fromYaml -}}
{{- $_ := set $labels "helm.sh/chart" (include "common.labels.chart" .) -}}
{{- $_ := set $labels "app.kubernetes.io/managed-by" (toString .Release.Service) -}}
{{- $version := include "common.labels.version" . -}}
{{- if $version -}}
{{- $_ := set $labels "app.kubernetes.io/version" $version -}}
{{- end -}}
{{- $_ := mergeOverwrite $labels (include "common.labels.selector" . | fromYaml) -}}
{{- toYaml $labels -}}
{{- end -}}

{{/*
Labels for an object that carries extra labels. Call with
(list $ctx $extra). $extra wins over the standard labels, the selector labels
win over $extra.
*/}}
{{- define "common.labels.withExtra" -}}
{{- $ctx := index . 0 -}}
{{- $labels := include "common.labels.standard" $ctx | fromYaml -}}
{{- $_ := mergeOverwrite $labels (include "common.util.stringMap" (index . 1) | fromYaml) -}}
{{- $_ := mergeOverwrite $labels (include "common.labels.selector" $ctx | fromYaml) -}}
{{- toYaml $labels -}}
{{- end -}}

{{/*
Pod template labels: standard labels plus podLabels. The selector labels win.
*/}}
{{- define "common.labels.pod" -}}
{{- $labels := include "common.labels.standard" . | fromYaml -}}
{{- $_ := mergeOverwrite $labels (include "common.util.stringMap" .Values.podLabels | fromYaml) -}}
{{- $_ := mergeOverwrite $labels (include "common.labels.selector" . | fromYaml) -}}
{{- toYaml $labels -}}
{{- end -}}
