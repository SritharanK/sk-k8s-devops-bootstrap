{{/*
autoscaling/v2 HorizontalPodAutoscaler. Targets the Deployment, or the
Rollout when rollout.enabled is true (the Rollout owns the replica count).
*/}}
{{- define "common.hpa" -}}
{{- include "common.render" (list . "common.tpl.hpa") -}}
{{- end -}}

{{/*
True when an autoscaler owns the replica count: the HPA of this chart
(autoscaling.enabled) or the HPA that KEDA creates for the ScaledObject
(keda.enabled). The Deployment and the Rollout then omit replicas.
*/}}
{{- define "common.autoscaling.enabled" -}}
{{- if or .Values.autoscaling.enabled .Values.keda.enabled -}}true{{- end -}}
{{- end -}}

{{/*
HPA metrics as a YAML list: autoscaling.metrics when set, else Resource
Utilization targets for CPU and memory when their percentages are not null.
*/}}
{{- define "common.hpa.metrics" -}}
{{- $a := .Values.autoscaling -}}
{{- if $a.metrics -}}
{{- toYaml $a.metrics -}}
{{- else -}}
{{- $metrics := list -}}
{{- $targets := dict "cpu" (index $a "targetCPUUtilizationPercentage") "memory" (index $a "targetMemoryUtilizationPercentage") -}}
{{- range $resource := list "cpu" "memory" -}}
{{- $target := index $targets $resource -}}
{{- if not (kindIs "invalid" $target) -}}
{{- $metrics = append $metrics (dict "type" "Resource" "resource" (dict "name" $resource "target" (dict "type" "Utilization" "averageUtilization" (int $target)))) -}}
{{- end -}}
{{- end -}}
{{- if $metrics -}}
{{- toYaml $metrics -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "common.tpl.hpa" -}}
{{- include "common.validate.autoscaling" . -}}
{{- if .Values.autoscaling.enabled -}}
{{- $metrics := include "common.hpa.metrics" . -}}
{{- if not $metrics -}}
{{- fail "autoscaling.enabled requires a metric: set autoscaling.targetCPUUtilizationPercentage, autoscaling.targetMemoryUtilizationPercentage or autoscaling.metrics" -}}
{{- end -}}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "common.names.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "common.labels.standard" . | nindent 4 }}
spec:
  scaleTargetRef:
    {{- if .Values.rollout.enabled }}
    apiVersion: argoproj.io/v1alpha1
    kind: Rollout
    {{- else }}
    apiVersion: apps/v1
    kind: Deployment
    {{- end }}
    name: {{ include "common.names.fullname" . }}
  minReplicas: {{ int .Values.autoscaling.minReplicas }}
  maxReplicas: {{ int .Values.autoscaling.maxReplicas }}
  metrics:
    {{- $metrics | nindent 4 }}
  {{- with .Values.autoscaling.behavior }}
  behavior:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end -}}
{{- end -}}
