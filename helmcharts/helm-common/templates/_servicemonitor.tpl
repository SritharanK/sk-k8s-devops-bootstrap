{{/*
monitoring.coreos.com/v1 ServiceMonitor. Selects the primary
Service only: the canary Service carries app.kubernetes.io/component=canary
and is excluded, so the pods are not scraped twice during a canary.
metrics.serviceMonitor.labels must match the serviceMonitorSelector of the
Prometheus instance.
*/}}
{{- define "common.servicemonitor" -}}
{{- include "common.render" (list . "common.tpl.servicemonitor") -}}
{{- end -}}

{{- define "common.tpl.servicemonitor" -}}
{{- $sm := .Values.metrics.serviceMonitor -}}
{{- if $sm.enabled -}}
{{- if not .Values.service.enabled -}}
{{- fail "metrics.serviceMonitor.enabled requires service.enabled: the ServiceMonitor scrapes the Service endpoints" -}}
{{- end -}}
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ include "common.names.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "common.labels.withExtra" (list . (index $sm "labels" | default dict)) | nindent 4 }}
spec:
  selector:
    matchLabels:
      {{- include "common.labels.selector" . | nindent 6 }}
    matchExpressions:
      - key: app.kubernetes.io/component
        operator: NotIn
        values:
          - canary
  namespaceSelector:
    matchNames:
      - {{ .Release.Namespace }}
  endpoints:
    - port: {{ required "metrics.serviceMonitor.port is required" (index $sm "port") }}
      {{- with index $sm "path" }}
      path: {{ . }}
      {{- end }}
      {{- with index $sm "interval" }}
      interval: {{ . }}
      {{- end }}
      {{- with index $sm "scrapeTimeout" }}
      scrapeTimeout: {{ . }}
      {{- end }}
{{- end -}}
{{- end -}}
