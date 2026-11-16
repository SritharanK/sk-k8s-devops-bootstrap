{{/*
networking.k8s.io/v1 NetworkPolicy with the allow rules of the workload. The
rules add to the platform default-deny and DNS policies:
- route.enabled: ingress from the Gateway namespace to the targetPort of the
  first service port
- metrics.serviceMonitor.enabled: ingress from the monitoring namespace to the
  targetPort of the service port named metrics.serviceMonitor.port
- networkPolicy.extraIngress, appended as given
- otel.enabled with otel.networkPolicy.namespace: egress to that namespace on
  TCP otel.networkPolicy.port (the OTLP collector)
- networkPolicy.egress, appended as given after the generated egress rule
Egress is added to policyTypes only when there is an egress rule. Nothing is
rendered when there is no ingress rule and no egress rule.
*/}}
{{- define "common.networkpolicy" -}}
{{- include "common.render" (list . "common.tpl.networkpolicy") -}}
{{- end -}}

{{/*
NetworkPolicyPort for a service port entry: its targetPort (named or numeric,
the port itself when targetPort is not set) and its protocol (default TCP).
Returns JSON, so numbers and names keep their type.
*/}}
{{- define "common.networkpolicy.port" -}}
{{- $target := index . "targetPort" -}}
{{- if not (include "common.util.isSet" $target) -}}
{{- $target = index . "port" -}}
{{- end -}}
{{- toJson (dict "port" $target "protocol" (index . "protocol" | default "TCP")) -}}
{{- end -}}

{{/*
Ingress rule from one namespace to one port. Call with (list $namespace $port).
*/}}
{{- define "common.networkpolicy.fromNamespace" -}}
{{- $namespace := index . 0 -}}
{{- $peer := dict "namespaceSelector" (dict "matchLabels" (dict "kubernetes.io/metadata.name" $namespace)) -}}
{{- toJson (dict "from" (list $peer) "ports" (list (index . 1))) -}}
{{- end -}}

{{- define "common.tpl.networkpolicy" -}}
{{- $np := .Values.networkPolicy -}}
{{- if $np.enabled -}}
{{- $ports := index .Values.service "ports" | default list -}}
{{- $ingress := list -}}
{{- if .Values.route.enabled -}}
{{- if not $ports -}}
{{- fail "networkPolicy: route.enabled needs at least one entry in service.ports to allow traffic from the Gateway" -}}
{{- end -}}
{{- $port := include "common.networkpolicy.port" (first $ports) | fromJson -}}
{{- $namespace := required "networkPolicy.gatewayNamespace is required when route.enabled is true" (index $np "gatewayNamespace") -}}
{{- $ingress = append $ingress (include "common.networkpolicy.fromNamespace" (list $namespace $port) | fromJson) -}}
{{- end -}}
{{- if .Values.metrics.serviceMonitor.enabled -}}
{{- $name := toString (index .Values.metrics.serviceMonitor "port" | default "") -}}
{{- $match := dict -}}
{{- range $ports -}}
{{- if and (not $match) (eq (toString (index . "name" | default "")) $name) -}}
{{- $match = . -}}
{{- end -}}
{{- end -}}
{{- if not $match -}}
{{- fail (printf "networkPolicy: no entry in service.ports is named %q (metrics.serviceMonitor.port), so the scrape port is unknown" $name) -}}
{{- end -}}
{{- $port := include "common.networkpolicy.port" $match | fromJson -}}
{{- $namespace := required "networkPolicy.monitoringNamespace is required when metrics.serviceMonitor.enabled is true" (index $np "monitoringNamespace") -}}
{{- $ingress = append $ingress (include "common.networkpolicy.fromNamespace" (list $namespace $port) | fromJson) -}}
{{- end -}}
{{- range (index $np "extraIngress" | default list) -}}
{{- $ingress = append $ingress . -}}
{{- end -}}
{{- $egress := list -}}
{{- with include "common.otel.egress" . -}}
{{- $egress = append $egress (fromJson .) -}}
{{- end -}}
{{- range (index $np "egress" | default list) -}}
{{- $egress = append $egress . -}}
{{- end -}}
{{- if or $ingress $egress -}}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ include "common.names.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "common.labels.standard" . | nindent 4 }}
spec:
  podSelector:
    matchLabels:
      {{- include "common.labels.selector" . | nindent 6 }}
  policyTypes:
    - Ingress
    {{- if $egress }}
    - Egress
    {{- end }}
  {{- if $ingress }}
  ingress:
    {{- toYaml $ingress | nindent 4 }}
  {{- else }}
  ingress: []
  {{- end }}
  {{- with $egress }}
  egress:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end -}}
{{- end -}}
{{- end -}}
