{{/*
Labels for objects rendered by this wrapper. They match the upstream chart
labels, including app.kubernetes.io/part-of: argocd, which Argo CD requires on
the ConfigMaps and Secrets it reads.
*/}}
{{- define "argocd-wrapper.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: argocd
{{- end -}}

{{/*
Name prefix of the upstream resources (argocd-server, argocd-repo-server, ...).
*/}}
{{- define "argocd-wrapper.fullname" -}}
{{- index .Values "argo-cd" "fullnameOverride" | default "argocd" -}}
{{- end -}}

{{/*
Fail when an RBAC subject would break the policy.csv format.
*/}}
{{- define "argocd-wrapper.subject" -}}
{{- $s := toString . -}}
{{- if not (regexMatch "^[^,\\s][^,\\n]*$" $s) -}}
{{- fail (printf "platform.groups: %q is not a valid RBAC subject (no commas, no leading space)" $s) -}}
{{- end -}}
{{- $s -}}
{{- end -}}
