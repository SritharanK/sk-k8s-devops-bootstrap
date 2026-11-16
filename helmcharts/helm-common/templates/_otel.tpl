{{/*
OpenTelemetry SDK settings for the application container, added to the
container env after .Values.env when otel.enabled is true. Traces only:
OTEL_METRICS_EXPORTER and OTEL_LOGS_EXPORTER are "none" because Tempo accepts
traces, and metrics come from Prometheus scraping.

Order of the generated variables:
1. OTEL_K8S_POD_NAME, OTEL_K8S_NAMESPACE_NAME, OTEL_K8S_NODE_NAME from the
   downward API
2. OTEL_SERVICE_NAME (otel.serviceName, else the full name), the exporter,
   sampler and propagator settings
3. OTEL_RESOURCE_ATTRIBUTES: k8s.namespace.name, k8s.pod.name and
   k8s.node.name as $(VAR) references to the downward API variables (Kubernetes
   expands a reference only to a variable defined earlier in the list),
   k8s.deployment.name, service.version (image tag, else appVersion),
   deployment.environment.name when global.environment is set, then
   otel.resourceAttributes sorted by key. A key in otel.resourceAttributes
   replaces the generated attribute with the same key.

A generated variable whose name is already defined in env is skipped, so the
consumer value always wins. The env list is a list map keyed by name: Argo CD
syncs with server-side apply, and two entries with the same name are a hard
apply error.
*/}}

{{/*
OTEL_RESOURCE_ATTRIBUTES value. Keys and values must not contain "," or "=",
the separators of the list; the values are not percent-encoded.
*/}}
{{- define "common.otel.resourceAttributes" -}}
{{- $o := .Values.otel -}}
{{- $extra := index $o "resourceAttributes" | default dict -}}
{{- $generated := list -}}
{{- $generated = append $generated (list "k8s.namespace.name" "$(OTEL_K8S_NAMESPACE_NAME)") -}}
{{- $generated = append $generated (list "k8s.pod.name" "$(OTEL_K8S_POD_NAME)") -}}
{{- $generated = append $generated (list "k8s.node.name" "$(OTEL_K8S_NODE_NAME)") -}}
{{- $generated = append $generated (list "k8s.deployment.name" (include "common.names.fullname" .)) -}}
{{- $version := "" -}}
{{- if include "common.util.isSet" (index .Values.image "tag") -}}
{{- $version = toString .Values.image.tag -}}
{{- else if .Chart.AppVersion -}}
{{- $version = toString .Chart.AppVersion -}}
{{- end -}}
{{- if $version -}}
{{- $generated = append $generated (list "service.version" $version) -}}
{{- end -}}
{{- $environment := include "common.util.global" (list .Values "environment") -}}
{{- if $environment -}}
{{- $generated = append $generated (list "deployment.environment.name" $environment) -}}
{{- end -}}
{{- $pairs := list -}}
{{- range $generated -}}
{{- if not (hasKey $extra (index . 0)) -}}
{{- $pairs = append $pairs (printf "%s=%s" (index . 0) (index . 1)) -}}
{{- end -}}
{{- end -}}
{{- range $key := keys $extra | sortAlpha -}}
{{- $value := index $extra $key -}}
{{- if not (kindIs "invalid" $value) -}}
{{- $value = toString $value -}}
{{- if or (contains "," $key) (contains "=" $key) (contains "," $value) (contains "=" $value) -}}
{{- fail (printf "otel.resourceAttributes.%s: keys and values must not contain \",\" or \"=\", the separators of OTEL_RESOURCE_ATTRIBUTES" $key) -}}
{{- end -}}
{{- $pairs = append $pairs (printf "%s=%s" $key $value) -}}
{{- end -}}
{{- end -}}
{{- join "," $pairs -}}
{{- end -}}

{{/*
Generated OTEL_* variables as a YAML list, without the names already defined
in env. Empty when otel.enabled is false.
*/}}
{{- define "common.otel.env" -}}
{{- $o := .Values.otel -}}
{{- if and (kindIs "map" $o) $o.enabled -}}
{{- $endpoint := index $o "endpoint" -}}
{{- if not (include "common.util.isSet" $endpoint) -}}
{{- fail "otel.enabled requires otel.endpoint, the OTLP endpoint of the collector, for example http://tempo.tracing.svc:4318" -}}
{{- end -}}
{{- $serviceName := include "common.names.fullname" . -}}
{{- if include "common.util.isSet" (index $o "serviceName") -}}
{{- $serviceName = toString $o.serviceName -}}
{{- end -}}
{{- $vars := list -}}
{{- range list (list "OTEL_K8S_POD_NAME" "metadata.name") (list "OTEL_K8S_NAMESPACE_NAME" "metadata.namespace") (list "OTEL_K8S_NODE_NAME" "spec.nodeName") -}}
{{- $vars = append $vars (dict "name" (index . 0) "valueFrom" (dict "fieldRef" (dict "apiVersion" "v1" "fieldPath" (index . 1)))) -}}
{{- end -}}
{{- $settings := list
  (list "OTEL_SERVICE_NAME" $serviceName)
  (list "OTEL_EXPORTER_OTLP_ENDPOINT" (toString $endpoint))
  (list "OTEL_EXPORTER_OTLP_PROTOCOL" (index $o "protocol"))
  (list "OTEL_TRACES_EXPORTER" "otlp")
  (list "OTEL_METRICS_EXPORTER" "none")
  (list "OTEL_LOGS_EXPORTER" "none")
  (list "OTEL_TRACES_SAMPLER" (index $o "sampler"))
  (list "OTEL_TRACES_SAMPLER_ARG" (index $o "samplerArg"))
  (list "OTEL_PROPAGATORS" (index $o "propagators"))
  (list "OTEL_RESOURCE_ATTRIBUTES" (include "common.otel.resourceAttributes" .))
-}}
{{- range $settings -}}
{{- if include "common.util.isSet" (index . 1) -}}
{{- $vars = append $vars (dict "name" (index . 0) "value" (toString (index . 1))) -}}
{{- end -}}
{{- end -}}
{{- $defined := dict -}}
{{- range .Values.env -}}
{{- if kindIs "map" . -}}
{{- $_ := set $defined (toString (index . "name")) true -}}
{{- end -}}
{{- end -}}
{{- $out := list -}}
{{- range $vars -}}
{{- if not (hasKey $defined .name) -}}
{{- $out = append $out . -}}
{{- end -}}
{{- end -}}
{{- if $out -}}
{{- toYaml $out -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
NetworkPolicy egress rule to the collector namespace, as JSON. Empty unless
otel.enabled is true and otel.networkPolicy.namespace is set.
*/}}
{{- define "common.otel.egress" -}}
{{- $o := .Values.otel -}}
{{- if and (kindIs "map" $o) $o.enabled -}}
{{- $np := index $o "networkPolicy" -}}
{{- if and (kindIs "map" $np) (include "common.util.isSet" (index $np "namespace")) -}}
{{- $port := required "otel.networkPolicy.port is required when otel.networkPolicy.namespace is set" (index $np "port") -}}
{{- $peer := dict "namespaceSelector" (dict "matchLabels" (dict "kubernetes.io/metadata.name" (toString $np.namespace))) -}}
{{- toJson (dict "to" (list $peer) "ports" (list (dict "port" (int $port) "protocol" "TCP"))) -}}
{{- end -}}
{{- end -}}
{{- end -}}
