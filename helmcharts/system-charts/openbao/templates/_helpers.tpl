{{- /*
Fullname of the upstream subchart, computed with its own helper and values, so
names here always match the StatefulSet, Services and Raft addresses.
*/ -}}
{{- define "openbao-wrapper.fullname" -}}
{{- include "openbao.fullname" (dict "Values" .Values.openbao "Chart" (dict "Name" "openbao") "Release" .Release) -}}
{{- end -}}

{{- define "openbao-wrapper.labels" -}}
app.kubernetes.io/name: openbao
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: platform
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}
