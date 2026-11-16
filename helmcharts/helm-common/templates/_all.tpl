{{/*
Every object of the library in one call, separated by "---". Disabled objects
emit nothing. A consumer chart can use this from a single template file:

  {{ include "common.all" . }}
*/}}
{{- define "common.all" -}}
{{- $top := . -}}
{{- $docs := list -}}
{{- range $tpl := list "common.serviceaccount" "common.configmap" "common.pvc" "common.service" "common.deployment" "common.rollout" "common.hpa" "common.scaledobject" "common.pdb" "common.httproute" "common.backendtrafficpolicy" "common.networkpolicy" "common.servicemonitor" -}}
{{- $out := include $tpl $top | trim -}}
{{- if $out -}}
{{- $docs = append $docs $out -}}
{{- end -}}
{{- end -}}
{{- join "\n---\n" $docs -}}
{{- end -}}
