{{/*
Render-time checks shared by several templates. They produce no output and
call fail when the values describe a workload that cannot run as intended.
*/}}

{{/*
A ReadWriteOnce or ReadWriteOncePod volume can be attached to one node (or one
pod) only. Fail when persistence uses such a mode and more than one pod can
run at the same time: replicaCount above 1, an HPA or a KEDA ScaledObject that
can scale above 1, or a Rollout (the canary and stable pods run side by side).
*/}}
{{- define "common.validate.persistence" -}}
{{- $p := .Values.persistence -}}
{{- if and $p.enabled (has (toString $p.accessMode) (list "ReadWriteOnce" "ReadWriteOncePod")) -}}
{{- $multi := false -}}
{{- $reason := "" -}}
{{- if .Values.rollout.enabled -}}
{{- $multi = true -}}
{{- $reason = "rollout.enabled is true (canary and stable pods run at the same time)" -}}
{{- else if .Values.autoscaling.enabled -}}
{{- if gt (int .Values.autoscaling.maxReplicas) 1 -}}
{{- $multi = true -}}
{{- $reason = printf "autoscaling.maxReplicas is %d" (int .Values.autoscaling.maxReplicas) -}}
{{- end -}}
{{- else if .Values.keda.enabled -}}
{{- if gt (int .Values.keda.maxReplicaCount) 1 -}}
{{- $multi = true -}}
{{- $reason = printf "keda.maxReplicaCount is %d" (int .Values.keda.maxReplicaCount) -}}
{{- end -}}
{{- else if gt (int .Values.replicaCount) 1 -}}
{{- $multi = true -}}
{{- $reason = printf "replicaCount is %d" (int .Values.replicaCount) -}}
{{- end -}}
{{- if $multi -}}
{{- fail (printf "persistence.accessMode %s allows a single node or pod, but %s. Use ReadWriteMany storage, run a single replica, or move state out of the pod." $p.accessMode $reason) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
KEDA creates and owns a HorizontalPodAutoscaler for the ScaledObject target.
The HPA of this chart would be a second autoscaler for the same workload, and
the two would overwrite each other's replica count, so autoscaling.enabled and
keda.enabled cannot both be true.
*/}}
{{- define "common.validate.autoscaling" -}}
{{- if and .Values.autoscaling.enabled .Values.keda.enabled -}}
{{- fail "autoscaling.enabled and keda.enabled are mutually exclusive: KEDA creates and owns the HorizontalPodAutoscaler of the workload. Disable one of them; when an environment enables autoscaling under environments.<env>, set environments.<env>.autoscaling.enabled: false there as well" -}}
{{- end -}}
{{- end -}}
