{{/*
policy/v1 PodDisruptionBudget. Rendered only when podDisruptionBudget.enabled
is true and the minimum replica count is above 1: with a single replica a PDB
either blocks node drains (minAvailable 1) or protects nothing.
The minimum replica count is autoscaling.minReplicas when autoscaling is
enabled; keda.idleReplicaCount (when set, usually 0) or else
keda.minReplicaCount when keda is enabled; else replicaCount.
*/}}
{{- define "common.pdb" -}}
{{- include "common.render" (list . "common.tpl.pdb") -}}
{{- end -}}

{{- define "common.tpl.pdb" -}}
{{- $pdb := .Values.podDisruptionBudget -}}
{{- if $pdb.enabled -}}
{{- $maxUnavailable := index $pdb "maxUnavailable" -}}
{{- $minAvailable := index $pdb "minAvailable" -}}
{{- $hasMax := include "common.util.isSet" $maxUnavailable -}}
{{- $hasMin := include "common.util.isSet" $minAvailable -}}
{{- if and $hasMax $hasMin -}}
{{- fail "podDisruptionBudget: set either maxUnavailable or minAvailable, not both (set the other one to null)" -}}
{{- end -}}
{{- if not (or $hasMax $hasMin) -}}
{{- fail "podDisruptionBudget.enabled requires maxUnavailable or minAvailable" -}}
{{- end -}}
{{- $minReplicas := int .Values.replicaCount -}}
{{- if .Values.autoscaling.enabled -}}
{{- $minReplicas = int .Values.autoscaling.minReplicas -}}
{{- else if .Values.keda.enabled -}}
{{- $minReplicas = int .Values.keda.minReplicaCount -}}
{{- if include "common.util.isSet" (index .Values.keda "idleReplicaCount") -}}
{{- $minReplicas = int .Values.keda.idleReplicaCount -}}
{{- end -}}
{{- end -}}
{{- if gt $minReplicas 1 -}}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "common.names.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "common.labels.standard" . | nindent 4 }}
spec:
  {{- if $hasMax }}
  maxUnavailable: {{ toJson $maxUnavailable }}
  {{- else }}
  minAvailable: {{ toJson $minAvailable }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "common.labels.selector" . | nindent 6 }}
{{- end -}}
{{- end -}}
{{- end -}}
