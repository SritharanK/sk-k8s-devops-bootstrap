{{/*
argoproj.io/v1alpha1 Rollout that references the Deployment
through workloadRef. The Deployment keeps the pod template and is rendered
with 0 replicas; the Rollout owns the replica count (or the HPA does, through
the Rollout, when autoscaling or keda is enabled).
*/}}
{{- define "common.rollout" -}}
{{- include "common.render" (list . "common.tpl.rollout") -}}
{{- end -}}

{{- define "common.tpl.rollout" -}}
{{- $r := .Values.rollout -}}
{{- if $r.enabled -}}
{{- $fullname := include "common.names.fullname" . -}}
{{- $gatewayAPI := include "common.rollout.gatewayAPI" . -}}
{{- $httpRoute := "" -}}
{{- if $gatewayAPI -}}
{{- if not .Values.service.enabled -}}
{{- fail "rollout.trafficRouting.gatewayAPI.enabled requires service.enabled: the stable and canary Services are rendered by this chart" -}}
{{- end -}}
{{- $httpRoute = toString (index $r.trafficRouting.gatewayAPI "httpRoute" | default "") -}}
{{- if not $httpRoute -}}
{{- if not .Values.route.enabled -}}
{{- fail "rollout.trafficRouting.gatewayAPI.enabled requires an HTTPRoute: set route.enabled or rollout.trafficRouting.gatewayAPI.httpRoute" -}}
{{- end -}}
{{- $httpRoute = $fullname -}}
{{- end -}}
{{- end -}}
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: {{ $fullname }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "common.labels.standard" . | nindent 4 }}
spec:
  {{- if not (include "common.autoscaling.enabled" .) }}
  replicas: {{ int .Values.replicaCount }}
  {{- end }}
  {{- if not (kindIs "invalid" (index .Values "revisionHistoryLimit")) }}
  revisionHistoryLimit: {{ int .Values.revisionHistoryLimit }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "common.labels.selector" . | nindent 6 }}
  workloadRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ $fullname }}
    scaleDown: {{ $r.workloadRef.scaleDown }}
  strategy:
    canary:
      {{- if $gatewayAPI }}
      canaryService: {{ include "common.names.canary" . }}
      stableService: {{ $fullname }}
      {{- end }}
      {{- with $r.steps }}
      steps:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- if $r.analysis.enabled }}
      analysis:
        templates:
          - templateName: {{ required "rollout.analysis.templateName is required when rollout.analysis.enabled is true" $r.analysis.templateName }}
            clusterScope: true
        {{- if not (kindIs "invalid" (index $r.analysis "startingStep")) }}
        startingStep: {{ int $r.analysis.startingStep }}
        {{- end }}
        {{- with index $r.analysis "args" }}
        args:
          {{- toYaml . | nindent 10 }}
        {{- end }}
      {{- end }}
      {{- if $gatewayAPI }}
      trafficRouting:
        plugins:
          argoproj-labs/gatewayAPI:
            httpRoute: {{ $httpRoute }}
            namespace: {{ .Release.Namespace }}
      {{- end }}
{{- end -}}
{{- end -}}
