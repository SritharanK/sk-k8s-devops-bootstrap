{{/*
v1 PersistentVolumeClaim, rendered when persistence.enabled is true and no
existingClaim is given. storageClassName: empty omits the field (cluster
default class), "-" renders an empty string (no dynamic provisioning), any
other value is used as is.
*/}}
{{- define "common.pvc" -}}
{{- include "common.render" (list . "common.tpl.pvc") -}}
{{- end -}}

{{- define "common.tpl.pvc" -}}
{{- $p := .Values.persistence -}}
{{- if and $p.enabled (not (include "common.util.isSet" (index $p "existingClaim"))) -}}
{{- $class := index $p "storageClassName" -}}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "common.names.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "common.labels.standard" . | nindent 4 }}
  {{- with include "common.util.stringMap" (index $p "annotations") }}
  annotations:
    {{- . | nindent 4 }}
  {{- end }}
spec:
  accessModes:
    - {{ required "persistence.accessMode is required" $p.accessMode }}
  resources:
    requests:
      storage: {{ required "persistence.size is required" $p.size | quote }}
  {{- if include "common.util.isSet" $class }}
  {{- if eq (toString $class) "-" }}
  storageClassName: ""
  {{- else }}
  storageClassName: {{ toString $class | quote }}
  {{- end }}
  {{- end }}
{{- end -}}
{{- end -}}
