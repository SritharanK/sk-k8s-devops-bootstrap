{{/*
Helpers for pull request preview environments (templates/previews/).
*/}}

{{/*
Preview settings as JSON (read with fromJson): .Values.previews with
toolchains.previews.values merged over it (the cluster file wins), validated
and completed with:
  github.owner, github.repo  derived from git.repoURL when empty
  prefix                     "<cluster>-" in hub mode, else ""
  apps[]                     {app, chart, generatePaths}, the list generator
                             elements of the previews-apps ApplicationSet
  namespace.chart            normalised path
*/}}
{{- define "argocd-bootstrap.previews.config" -}}
{{- $cfg := mustMergeOverwrite (deepCopy (.Values.previews | default dict)) (deepCopy (dig "previews" "values" dict .Values.toolchains)) -}}
{{- $gh := $cfg.github | default dict -}}
{{- if not (and $gh.owner $gh.repo) -}}
{{- $re := "^(?:https://github\\.com/|ssh://git@github\\.com/|git@github\\.com:)([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\\.git)?/?$" -}}
{{- $url := .Values.git.repoURL | default "" | toString -}}
{{- if not (regexMatch $re $url) -}}
{{- fail (printf "previews: cannot derive the GitHub owner and repository from git.repoURL %q (expected https://github.com/<owner>/<repo>[.git]); set previews.github.owner and previews.github.repo, or toolchains.previews.values.github in the cluster file" $url) -}}
{{- end -}}
{{- if not $gh.owner -}}
{{- $_ := set $gh "owner" (regexReplaceAll $re $url "${1}") -}}
{{- end -}}
{{- if not $gh.repo -}}
{{- $_ := set $gh "repo" (regexReplaceAll $re $url "${2}") -}}
{{- end -}}
{{- end -}}
{{- if not $gh.labels -}}
{{- fail "previews.github.labels must name at least one label: without one, every open pull request, including one from a fork, gets a preview" -}}
{{- end -}}
{{- if not $gh.appSecretName -}}
{{- $ref := $gh.tokenRef | default dict -}}
{{- if not (and $ref.secretName $ref.key) -}}
{{- fail "previews.github.tokenRef.secretName and previews.github.tokenRef.key are required unless previews.github.appSecretName is set" -}}
{{- end -}}
{{- end -}}
{{- $_ := set $cfg "github" $gh -}}
{{- $requeue := int64 ($cfg.requeueAfterSeconds | default 300) -}}
{{- if lt $requeue 1 -}}
{{- fail (printf "previews.requeueAfterSeconds must be a positive number of seconds, not %v" $cfg.requeueAfterSeconds) -}}
{{- end -}}
{{- $_ := set $cfg "requeueAfterSeconds" $requeue -}}
{{- $style := $cfg.hostnameStyle | default "nested" | toString -}}
{{- if not (has $style (list "nested" "flat")) -}}
{{- fail (printf "previews.hostnameStyle must be nested or flat, not %q" $style) -}}
{{- end -}}
{{- $_ := set $cfg "hostnameStyle" $style -}}
{{- $prefix := "" -}}
{{- if include "argocd-bootstrap.isRemote" . -}}
{{- $prefix = printf "%s-" .Values.cluster.name -}}
{{- end -}}
{{- $_ := set $cfg "prefix" $prefix -}}
{{- $apps := list -}}
{{- $seen := list -}}
{{- range $app := $cfg.apps | default list -}}
{{- $name := $app.name | default "" | toString -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $name) -}}
{{- fail (printf "previews.apps: invalid name %q (a DNS label is expected)" $name) -}}
{{- end -}}
{{- if has $name $seen -}}
{{- fail (printf "previews.apps: duplicate name %q" $name) -}}
{{- end -}}
{{- $seen = append $seen $name -}}
{{- if gt (len (printf "%spr-999999-%s" $prefix $name)) 63 -}}
{{- fail (printf "previews.apps: name %q is too long; the Application name %spr-<number>-%s must fit in 63 characters for six-digit pull request numbers" $name $prefix $name) -}}
{{- end -}}
{{- $chart := required (printf "previews.apps: chart is required for %q" $name) $app.chart | toString | trimPrefix "./" | trimSuffix "/" -}}
{{- $paths := list (printf "/%s" $chart) "/helmcharts/helm-common" (printf "/envs/dev/%s" $name) (printf "/envs/preview/%s" $name) -}}
{{- $apps = append $apps (dict "app" $name "chart" $chart "generatePaths" (join ";" $paths)) -}}
{{- end -}}
{{- if not $apps -}}
{{- fail "previews.apps must list at least one application" -}}
{{- end -}}
{{- $_ := set $cfg "apps" $apps -}}
{{- $ns := $cfg.namespace | default dict -}}
{{- $_ := set $ns "chart" (required "previews.namespace.chart is required" $ns.chart | toString | trimPrefix "./" | trimSuffix "/") -}}
{{- $_ := set $ns "values" ($ns.values | default dict) -}}
{{- $_ := set $cfg "namespace" $ns -}}
{{- $cfg | toJson -}}
{{- end -}}

{{/*
GitHub Pull Request generator. Takes the dict returned by
argocd-bootstrap.previews.config. appSecretName, when set, replaces tokenRef.
*/}}
{{- define "argocd-bootstrap.previews.generator" -}}
{{- $gh := .github -}}
pullRequest:
  github:
    owner: {{ $gh.owner | quote }}
    repo: {{ $gh.repo | quote }}
    {{- with $gh.api }}
    api: {{ . | quote }}
    {{- end }}
    {{- if $gh.appSecretName }}
    appSecretName: {{ $gh.appSecretName | quote }}
    {{- else }}
    tokenRef:
      secretName: {{ $gh.tokenRef.secretName | quote }}
      key: {{ $gh.tokenRef.key | quote }}
    {{- end }}
    labels:
      {{- toYaml $gh.labels | nindent 6 }}
  requeueAfterSeconds: {{ .requeueAfterSeconds | int64 }}
{{- end -}}
