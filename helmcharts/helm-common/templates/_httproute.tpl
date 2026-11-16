{{/*
gateway.networking.k8s.io/v1 HTTPRoute. One rule that sends the
configured matches to the first port of the primary Service. With Gateway API
traffic routing for the Rollout, the rule carries two backendRefs (stable at
weight 100, canary at weight 0) and the Argo Rollouts plugin shifts the
weights during a canary.
*/}}
{{- define "common.httproute" -}}
{{- include "common.render" (list . "common.tpl.httproute") -}}
{{- end -}}

{{/*
Route hostnames: route.hostnames when set, else
<fullname>.<global.environment>.<global.domain>. Returns a YAML list.
*/}}
{{- define "common.httproute.hostnames" -}}
{{- if .Values.route.hostnames -}}
{{- toYaml .Values.route.hostnames -}}
{{- else -}}
{{- $environment := include "common.util.global" (list .Values "environment") -}}
{{- $domain := include "common.util.global" (list .Values "domain") -}}
{{- if not (and $environment $domain) -}}
{{- fail "route.enabled is true but no hostname is known: set route.hostnames, or provide global.environment and global.domain so the hostname <fullname>.<environment>.<domain> is used" -}}
{{- end -}}
{{- toYaml (list (printf "%s.%s.%s" (include "common.names.fullname" .) $environment $domain)) -}}
{{- end -}}
{{- end -}}

{{- define "common.tpl.httproute" -}}
{{- if .Values.route.enabled -}}
{{- if not .Values.service.enabled -}}
{{- fail "route.enabled requires service.enabled: the HTTPRoute sends traffic to the Service" -}}
{{- end -}}
{{- if not .Values.service.ports -}}
{{- fail "route.enabled requires at least one entry in service.ports" -}}
{{- end -}}
{{- $port := required "service.ports[0].port is required for the HTTPRoute backendRef" (index (first .Values.service.ports) "port") -}}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ include "common.names.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "common.labels.standard" . | nindent 4 }}
  {{- with include "common.util.stringMap" .Values.route.annotations }}
  annotations:
    {{- . | nindent 4 }}
  {{- end }}
spec:
  {{- with .Values.route.parentRefs }}
  parentRefs:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  hostnames:
    {{- include "common.httproute.hostnames" . | nindent 4 }}
  rules:
    - backendRefs:
        - name: {{ include "common.names.fullname" . }}
          port: {{ $port }}
          {{- if include "common.rollout.gatewayAPI" . }}
          weight: 100
        - name: {{ include "common.names.canary" . }}
          port: {{ $port }}
          weight: 0
          {{- end }}
      {{- with .Values.route.matches }}
      matches:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.route.timeouts }}
      timeouts:
        {{- toYaml . | nindent 8 }}
      {{- end }}
{{- end -}}
{{- end -}}
