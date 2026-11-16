{{/* Common labels for every object in this chart. */}}
{{- define "network-policies.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: platform
app.kubernetes.io/instance: {{ .Release.Name }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end -}}

{{/*
NetworkPolicyPeer list with one entry: pods matching podSelector in one
namespace. Input: dict with "namespace" and "podSelector".
*/}}
{{- define "network-policies.namespacePeer" -}}
- namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: {{ required "a namespace peer needs a namespace" .namespace | quote }}
{{- with .podSelector }}
  podSelector:
    {{- toYaml . | nindent 4 }}
{{- else }}
  podSelector: {}
{{- end }}
{{- end -}}
