{{/*
v1 Service. When the Rollout routes traffic through the Gateway API, a second
Service <fullname>-canary is rendered with the same ports and selector. The
Argo Rollouts controller adds the pod template hash to the selectors of both
Services at runtime.
*/}}
{{- define "common.service" -}}
{{- include "common.render" (list . "common.tpl.service") -}}
{{- end -}}

{{/*
True when the Rollout uses the Gateway API plugin for traffic routing.
*/}}
{{- define "common.rollout.gatewayAPI" -}}
{{- if and .Values.rollout.enabled .Values.rollout.trafficRouting.gatewayAPI.enabled -}}true{{- end -}}
{{- end -}}

{{- define "common.tpl.service" -}}
{{- if .Values.service.enabled -}}
{{- if not .Values.service.ports -}}
{{- fail "service.ports must contain at least one port when service.enabled is true" -}}
{{- end -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "common.names.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "common.labels.standard" . | nindent 4 }}
  {{- with include "common.util.stringMap" .Values.service.annotations }}
  annotations:
    {{- . | nindent 4 }}
  {{- end }}
spec:
  type: {{ .Values.service.type }}
  ports:
    {{- toYaml .Values.service.ports | nindent 4 }}
  selector:
    {{- include "common.labels.selector" . | nindent 4 }}
{{- if include "common.rollout.gatewayAPI" . }}
{{- $ports := list -}}
{{- range .Values.service.ports -}}
{{- $ports = append $ports (omit . "nodePort") -}}
{{- end }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ include "common.names.canary" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "common.labels.withExtra" (list . (dict "app.kubernetes.io/component" "canary")) | nindent 4 }}
  {{- with include "common.util.stringMap" .Values.service.annotations }}
  annotations:
    {{- . | nindent 4 }}
  {{- end }}
spec:
  type: ClusterIP
  ports:
    {{- toYaml $ports | nindent 4 }}
  selector:
    {{- include "common.labels.selector" . | nindent 4 }}
{{- end }}
{{- end -}}
{{- end -}}
