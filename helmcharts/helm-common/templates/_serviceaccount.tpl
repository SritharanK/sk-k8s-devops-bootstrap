{{/*
v1 ServiceAccount. automountServiceAccountToken is always rendered, so the
token is not mounted unless serviceAccount.automount is true.
*/}}
{{- define "common.serviceaccount" -}}
{{- include "common.render" (list . "common.tpl.serviceaccount") -}}
{{- end -}}

{{- define "common.tpl.serviceaccount" -}}
{{- if .Values.serviceAccount.create -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "common.serviceAccountName" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "common.labels.standard" . | nindent 4 }}
  {{- with include "common.util.stringMap" .Values.serviceAccount.annotations }}
  annotations:
    {{- . | nindent 4 }}
  {{- end }}
automountServiceAccountToken: {{ eq (toString (index .Values.serviceAccount "automount")) "true" }}
{{- end -}}
{{- end -}}
