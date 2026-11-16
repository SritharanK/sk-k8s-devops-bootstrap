{{/*
v1 ConfigMap, one per configMaps entry, named <fullname>-<key>. Values in
data are rendered as strings.
*/}}
{{- define "common.configmap" -}}
{{- include "common.render" (list . "common.tpl.configmap") -}}
{{- end -}}

{{- define "common.tpl.configmap" -}}
{{- $ctx := . -}}
{{- $fullname := include "common.names.fullname" . -}}
{{- range $i, $key := keys .Values.configMaps | sortAlpha }}
{{- $data := required (printf "configMaps.%s.data is required" $key) (index (index $ctx.Values.configMaps $key) "data") }}
{{- if $i }}
---
{{- end }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ printf "%s-%s" $fullname $key }}
  namespace: {{ $ctx.Release.Namespace }}
  labels:
    {{- include "common.labels.standard" $ctx | nindent 4 }}
{{- with include "common.util.stringMap" $data }}
data:
  {{- . | nindent 2 }}
{{- else }}
data: {}
{{- end }}
{{- end }}
{{- end -}}
