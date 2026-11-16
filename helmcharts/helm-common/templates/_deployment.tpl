{{/*
apps/v1 Deployment.
*/}}
{{- define "common.deployment" -}}
{{- include "common.render" (list . "common.tpl.deployment") -}}
{{- end -}}

{{/*
Pod volumes as a YAML list. Empty when there are none.
*/}}
{{- define "common.deployment.volumes" -}}
{{- $fullname := include "common.names.fullname" . -}}
{{- $volumes := list -}}
{{- $tmp := .Values.tmpVolume -}}
{{- if $tmp.enabled -}}
{{- $emptyDir := dict -}}
{{- if include "common.util.isSet" (index $tmp "sizeLimit") -}}
{{- $_ := set $emptyDir "sizeLimit" (index $tmp "sizeLimit") -}}
{{- end -}}
{{- if include "common.util.isSet" (index $tmp "medium") -}}
{{- $_ := set $emptyDir "medium" (index $tmp "medium") -}}
{{- end -}}
{{- $volumes = append $volumes (dict "name" "tmp" "emptyDir" $emptyDir) -}}
{{- end -}}
{{- range $key, $cm := .Values.configMaps -}}
{{- if include "common.util.isSet" (index $cm "mountPath") -}}
{{- $volumes = append $volumes (dict "name" (printf "config-%s" $key) "configMap" (dict "name" (printf "%s-%s" $fullname $key))) -}}
{{- end -}}
{{- end -}}
{{- range $key, $sm := .Values.secretMounts -}}
{{- $secret := dict "secretName" (required (printf "secretMounts.%s.secretName is required" $key) (index $sm "secretName")) -}}
{{- with index $sm "items" -}}
{{- $_ := set $secret "items" . -}}
{{- end -}}
{{- if not (kindIs "invalid" (index $sm "optional")) -}}
{{- $_ := set $secret "optional" (index $sm "optional") -}}
{{- end -}}
{{- $volumes = append $volumes (dict "name" (printf "secret-%s" $key) "secret" $secret) -}}
{{- end -}}
{{- if .Values.persistence.enabled -}}
{{- $claim := $fullname -}}
{{- if include "common.util.isSet" (index .Values.persistence "existingClaim") -}}
{{- $claim = toString .Values.persistence.existingClaim -}}
{{- end -}}
{{- $volumes = append $volumes (dict "name" "data" "persistentVolumeClaim" (dict "claimName" $claim)) -}}
{{- end -}}
{{- range .Values.extraVolumes -}}
{{- $volumes = append $volumes . -}}
{{- end -}}
{{- if $volumes -}}
{{- toYaml $volumes -}}
{{- end -}}
{{- end -}}

{{/*
Container volume mounts as a YAML list. Empty when there are none.
*/}}
{{- define "common.deployment.volumeMounts" -}}
{{- $mounts := list -}}
{{- if .Values.tmpVolume.enabled -}}
{{- $mounts = append $mounts (dict "name" "tmp" "mountPath" (required "tmpVolume.mountPath is required when tmpVolume.enabled is true" .Values.tmpVolume.mountPath)) -}}
{{- end -}}
{{- range $key, $cm := .Values.configMaps -}}
{{- if include "common.util.isSet" (index $cm "mountPath") -}}
{{- $mounts = append $mounts (dict "name" (printf "config-%s" $key) "mountPath" (index $cm "mountPath") "readOnly" true) -}}
{{- end -}}
{{- end -}}
{{- range $key, $sm := .Values.secretMounts -}}
{{- $mounts = append $mounts (dict "name" (printf "secret-%s" $key) "mountPath" (required (printf "secretMounts.%s.mountPath is required" $key) (index $sm "mountPath")) "readOnly" true) -}}
{{- end -}}
{{- if .Values.persistence.enabled -}}
{{- $mounts = append $mounts (dict "name" "data" "mountPath" (required "persistence.mountPath is required when persistence.enabled is true" .Values.persistence.mountPath)) -}}
{{- end -}}
{{- range .Values.extraVolumeMounts -}}
{{- $mounts = append $mounts . -}}
{{- end -}}
{{- if $mounts -}}
{{- toYaml $mounts -}}
{{- end -}}
{{- end -}}

{{/*
Container env: env as given, then the OTEL_* variables of common.otel.env
when otel.enabled is true (names already in env are skipped there).
*/}}
{{- define "common.deployment.env" -}}
{{- $env := list -}}
{{- range .Values.env -}}
{{- $env = append $env . -}}
{{- end -}}
{{- with include "common.otel.env" . -}}
{{- range fromYamlArray . -}}
{{- $env = append $env . -}}
{{- end -}}
{{- end -}}
{{- if $env -}}
{{- toYaml $env -}}
{{- end -}}
{{- end -}}

{{/*
Container envFrom: envFrom as given, then a configMapRef for every configMaps
entry with asEnv true.
*/}}
{{- define "common.deployment.envFrom" -}}
{{- $fullname := include "common.names.fullname" . -}}
{{- $envFrom := list -}}
{{- range .Values.envFrom -}}
{{- $envFrom = append $envFrom . -}}
{{- end -}}
{{- range $key, $cm := .Values.configMaps -}}
{{- if eq (toString (index $cm "asEnv")) "true" -}}
{{- $envFrom = append $envFrom (dict "configMapRef" (dict "name" (printf "%s-%s" $fullname $key))) -}}
{{- end -}}
{{- end -}}
{{- if $envFrom -}}
{{- toYaml $envFrom -}}
{{- end -}}
{{- end -}}

{{/*
Pod template annotations: podAnnotations plus checksum/config when the chart
renders ConfigMaps, so a data change rolls the pods.
*/}}
{{- define "common.deployment.podAnnotations" -}}
{{- $annotations := include "common.util.stringMap" .Values.podAnnotations | fromYaml -}}
{{- if .Values.configMaps -}}
{{- $data := dict -}}
{{- range $key, $cm := .Values.configMaps -}}
{{- $_ := set $data $key (include "common.util.stringMap" (index $cm "data") | fromYaml) -}}
{{- end -}}
{{- $_ := set $annotations "checksum/config" (toJson $data | sha256sum) -}}
{{- end -}}
{{- if $annotations -}}
{{- toYaml $annotations -}}
{{- end -}}
{{- end -}}

{{/*
Image pull secrets: accepts names or {name: ...} maps.
*/}}
{{- define "common.deployment.imagePullSecrets" -}}
{{- $secrets := list -}}
{{- range .Values.imagePullSecrets -}}
{{- if kindIs "map" . -}}
{{- $secrets = append $secrets . -}}
{{- else -}}
{{- $secrets = append $secrets (dict "name" (toString .)) -}}
{{- end -}}
{{- end -}}
{{- if $secrets -}}
{{- toYaml $secrets -}}
{{- end -}}
{{- end -}}

{{- define "common.tpl.deployment" -}}
{{- include "common.validate.autoscaling" . -}}
{{- include "common.validate.persistence" . -}}
{{- $env := include "common.deployment.env" . -}}
{{- $volumes := include "common.deployment.volumes" . -}}
{{- $mounts := include "common.deployment.volumeMounts" . -}}
{{- $envFrom := include "common.deployment.envFrom" . -}}
{{- $podAnnotations := include "common.deployment.podAnnotations" . -}}
{{- $pullSecrets := include "common.deployment.imagePullSecrets" . -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "common.names.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "common.labels.standard" . | nindent 4 }}
spec:
  {{- if not (include "common.autoscaling.enabled" .) }}
  {{- if .Values.rollout.enabled }}
  replicas: 0
  {{- else }}
  replicas: {{ int .Values.replicaCount }}
  {{- end }}
  {{- end }}
  {{- if not (kindIs "invalid" (index .Values "revisionHistoryLimit")) }}
  revisionHistoryLimit: {{ int .Values.revisionHistoryLimit }}
  {{- end }}
  {{- with .Values.strategy }}
  strategy:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "common.labels.selector" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "common.labels.pod" . | nindent 8 }}
      {{- with $podAnnotations }}
      annotations:
        {{- . | nindent 8 }}
      {{- end }}
    spec:
      serviceAccountName: {{ include "common.serviceAccountName" . }}
      automountServiceAccountToken: {{ eq (toString (index .Values.serviceAccount "automount")) "true" }}
      {{- with .Values.podSecurityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $pullSecrets }}
      imagePullSecrets:
        {{- . | nindent 8 }}
      {{- end }}
      {{- if not (kindIs "invalid" (index .Values "terminationGracePeriodSeconds")) }}
      terminationGracePeriodSeconds: {{ int .Values.terminationGracePeriodSeconds }}
      {{- end }}
      {{- with .Values.priorityClassName }}
      priorityClassName: {{ . }}
      {{- end }}
      {{- with .Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- if .Values.topologySpread.enabled }}
      topologySpreadConstraints:
        - maxSkew: {{ int .Values.topologySpread.maxSkew }}
          topologyKey: {{ .Values.topologySpread.topologyKey }}
          whenUnsatisfiable: {{ .Values.topologySpread.whenUnsatisfiable }}
          labelSelector:
            matchLabels:
              {{- include "common.labels.selector" . | nindent 14 }}
      {{- end }}
      containers:
        - name: {{ include "common.names.name" . }}
          image: {{ include "common.image" . | quote }}
          {{- with .Values.image.pullPolicy }}
          imagePullPolicy: {{ . }}
          {{- end }}
          {{- with .Values.command }}
          command:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with .Values.args }}
          args:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with .Values.containerPorts }}
          ports:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with $env }}
          env:
            {{- . | nindent 12 }}
          {{- end }}
          {{- with $envFrom }}
          envFrom:
            {{- . | nindent 12 }}
          {{- end }}
          {{- range $probe := list "livenessProbe" "readinessProbe" "startupProbe" }}
          {{- with index $.Values $probe }}
          {{ $probe }}:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- end }}
          {{- with .Values.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with .Values.lifecycle }}
          lifecycle:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with .Values.securityContext }}
          securityContext:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with $mounts }}
          volumeMounts:
            {{- . | nindent 12 }}
          {{- end }}
      {{- with $volumes }}
      volumes:
        {{- . | nindent 8 }}
      {{- end }}
{{- end -}}
