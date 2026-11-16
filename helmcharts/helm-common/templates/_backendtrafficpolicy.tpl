{{/*
gateway.envoyproxy.io/v1alpha1 BackendTrafficPolicy (Envoy Gateway). Attached
to the HTTPRoute of this chart through targetRefs, so it applies to every
backend of that route, including the canary Service when the Rollout routes
traffic through the Gateway API. Requires route.enabled.
- timeout, retry and circuitBreaker are rendered as given and omitted when
  null or empty. Field names follow the Envoy Gateway v1.10 CRD.
- rateLimit.enabled adds one local rate limit rule without client selectors:
  each Envoy replica counts the requests to the route on its own and answers
  429 above the limit. rateLimit.type is deprecated in v1.10 and not rendered.
- circuitBreaker thresholds also apply per Envoy replica.
- route.timeouts sets a request timeout on the same route; set it there or in
  trafficPolicy.timeout.http.requestTimeout, not both.
*/}}
{{- define "common.backendtrafficpolicy" -}}
{{- include "common.render" (list . "common.tpl.backendtrafficpolicy") -}}
{{- end -}}

{{- define "common.tpl.backendtrafficpolicy" -}}
{{- $tp := .Values.trafficPolicy -}}
{{- if $tp.enabled -}}
{{- if not .Values.route.enabled -}}
{{- fail "trafficPolicy.enabled requires route.enabled: the BackendTrafficPolicy attaches to the HTTPRoute rendered by this chart" -}}
{{- end -}}
{{- $rateLimit := index $tp "rateLimit" | default dict -}}
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: {{ include "common.names.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "common.labels.standard" . | nindent 4 }}
  {{- with include "common.util.stringMap" (index $tp "annotations") }}
  annotations:
    {{- . | nindent 4 }}
  {{- end }}
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: {{ include "common.names.fullname" . }}
  {{- with index $tp "timeout" }}
  timeout:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with index $tp "retry" }}
  retry:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with index $tp "circuitBreaker" }}
  circuitBreaker:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- if index $rateLimit "enabled" }}
  rateLimit:
    local:
      rules:
        - limit:
            requests: {{ int (required "trafficPolicy.rateLimit.requests is required when trafficPolicy.rateLimit.enabled is true" (index $rateLimit "requests")) }}
            unit: {{ required "trafficPolicy.rateLimit.unit is required when trafficPolicy.rateLimit.enabled is true" (index $rateLimit "unit") }}
  {{- end }}
{{- end -}}
{{- end -}}
