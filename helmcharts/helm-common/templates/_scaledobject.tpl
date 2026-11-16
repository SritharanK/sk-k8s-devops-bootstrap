{{/*
keda.sh/v1alpha1 ScaledObject (KEDA), an alternative to the HPA of this
chart. KEDA creates and owns its own HorizontalPodAutoscaler for the target,
so keda.enabled and autoscaling.enabled together fail the render, and the
Deployment and the Rollout omit replicas. The target is the Rollout when
rollout.enabled is true (the Rollout owns the replica count), else the
Deployment.

Triggers: keda.triggers when set, else one Prometheus trigger built from
keda.prometheus. Its query is rendered through tpl, so it may reference the
release namespace and the full name; its threshold is the target value per
replica (metricType AverageValue). Trigger metadata values are rendered as
strings, as the CRD requires.
*/}}
{{- define "common.scaledobject" -}}
{{- include "common.render" (list . "common.tpl.scaledobject") -}}
{{- end -}}

{{/*
Trigger metadata with every value converted to a string. Null values are
dropped. Call with the metadata map, returns JSON.
*/}}
{{- define "common.scaledobject.metadata" -}}
{{- $out := dict -}}
{{- range $k, $v := . -}}
{{- if not (kindIs "invalid" $v) -}}
{{- $_ := set $out $k (toString $v) -}}
{{- end -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}

{{/*
ScaledObject triggers as a YAML list.
*/}}
{{- define "common.scaledobject.triggers" -}}
{{- $k := .Values.keda -}}
{{- $triggers := list -}}
{{- if index $k "triggers" -}}
{{- range $i, $t := $k.triggers -}}
{{- if not (include "common.util.isSet" (index $t "type")) -}}
{{- fail (printf "keda.triggers[%d].type is required" $i) -}}
{{- end -}}
{{- $trigger := omit $t "metadata" -}}
{{- $_ := set $trigger "metadata" (include "common.scaledobject.metadata" (index $t "metadata" | default dict) | fromJson) -}}
{{- $triggers = append $triggers $trigger -}}
{{- end -}}
{{- else -}}
{{- $p := index $k "prometheus" | default dict -}}
{{- if not (include "common.util.isSet" (index $p "query")) -}}
{{- fail "keda.enabled requires a trigger: set keda.prometheus.query (a PromQL query for the default Prometheus trigger) or keda.triggers" -}}
{{- end -}}
{{- $metadata := dict -}}
{{- $_ := set $metadata "serverAddress" (toString (required "keda.prometheus.serverAddress is required for the Prometheus trigger" (index $p "serverAddress"))) -}}
{{- $_ := set $metadata "query" (tpl (toString $p.query) .) -}}
{{- $_ := set $metadata "threshold" (toString (required "keda.prometheus.threshold is required for the Prometheus trigger" (index $p "threshold"))) -}}
{{- if include "common.util.isSet" (index $p "activationThreshold") -}}
{{- $_ := set $metadata "activationThreshold" (toString $p.activationThreshold) -}}
{{- end -}}
{{- $trigger := dict "type" "prometheus" "metricType" "AverageValue" "metadata" $metadata -}}
{{- with index $p "authenticationRef" -}}
{{- $_ := set $trigger "authenticationRef" . -}}
{{- end -}}
{{- $triggers = append $triggers $trigger -}}
{{- end -}}
{{- toYaml $triggers -}}
{{- end -}}

{{- define "common.tpl.scaledobject" -}}
{{- include "common.validate.autoscaling" . -}}
{{- $k := .Values.keda -}}
{{- if $k.enabled -}}
{{- $min := int $k.minReplicaCount -}}
{{- $max := int $k.maxReplicaCount -}}
{{- if gt $min $max -}}
{{- fail (printf "keda.minReplicaCount (%d) must not be greater than keda.maxReplicaCount (%d)" $min $max) -}}
{{- end -}}
{{- $idle := index $k "idleReplicaCount" -}}
{{- $hasIdle := include "common.util.isSet" $idle -}}
{{- if and $hasIdle (ge (int $idle) $min) -}}
{{- fail (printf "keda.idleReplicaCount (%d) must be lower than keda.minReplicaCount (%d): set minReplicaCount to at least 1 for scale to zero with idleReplicaCount 0" (int $idle) $min) -}}
{{- end -}}
{{- $triggers := include "common.scaledobject.triggers" . -}}
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
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
  {{- range $field := list "pollingInterval" "cooldownPeriod" "initialCooldownPeriod" }}
  {{- if include "common.util.isSet" (index $k $field) }}
  {{ $field }}: {{ int (index $k $field) }}
  {{- end }}
  {{- end }}
  minReplicaCount: {{ $min }}
  maxReplicaCount: {{ $max }}
  {{- if $hasIdle }}
  idleReplicaCount: {{ int $idle }}
  {{- end }}
  {{- with index $k "fallback" }}
  fallback:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with index $k "behavior" }}
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        {{- toYaml . | nindent 8 }}
  {{- end }}
  triggers:
    {{- $triggers | nindent 4 }}
{{- end -}}
{{- end -}}
