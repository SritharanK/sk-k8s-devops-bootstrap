{{- define "chart.fullname" -}}
{{- printf "%s" .Values.name -}}
{{- end -}}

{{- define "serviceport" -}}
{{- .Values.service.port -}}
{{- end -}}

{{- define "envFile" -}}
{{ .Values.externalEnv.fileName | default ".env" }}
{{- end -}}

{{- define "envName" -}}
"{{ template "chart.fullname" $ }}-external-environments"
{{- end -}}
