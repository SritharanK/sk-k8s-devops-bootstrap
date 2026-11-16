{{/*
Labels for the resources this wrapper renders itself.
*/}}
{{- define "cnpg-wrapper.labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: cloudnative-pg
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{/*
Annotations for the example custom resources. Their CRDs are applied in the same sync,
so the dry run must not fail on a missing kind; wave 1 starts after the operator and
plugin Deployments (wave 0) are healthy and the admission webhooks answer.
*/}}
{{- define "cnpg-wrapper.exampleAnnotations" -}}
argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
argocd.argoproj.io/sync-wave: "1"
{{- end }}
