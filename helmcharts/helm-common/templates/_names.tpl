{{/*
Name helpers. All of them expect the merged context built by common.render.
*/}}

{{/*
Chart name or nameOverride, truncated to 63 characters.
*/}}
{{- define "common.names.name" -}}
{{- $name := .Chart.Name -}}
{{- if .Values.nameOverride -}}
{{- $name = toString .Values.nameOverride -}}
{{- end -}}
{{- $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Full name: fullnameOverride, else the release name when it already contains
the name, else <release>-<name>. Truncated to 63 characters.
*/}}
{{- define "common.names.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- toString .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "common.names.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Name of the canary Service rendered for Gateway API traffic routing. The base
is shortened so the result stays a valid 63-character Service name.
*/}}
{{- define "common.names.canary" -}}
{{- printf "%s-canary" (include "common.names.fullname" . | trunc 56 | trimSuffix "-") -}}
{{- end -}}

{{/*
ServiceAccount name: serviceAccount.name, else the full name when the chart
creates the account, else "default".
*/}}
{{- define "common.serviceAccountName" -}}
{{- if .Values.serviceAccount.name -}}
{{- toString .Values.serviceAccount.name -}}
{{- else if .Values.serviceAccount.create -}}
{{- include "common.names.fullname" . -}}
{{- else -}}
default
{{- end -}}
{{- end -}}
