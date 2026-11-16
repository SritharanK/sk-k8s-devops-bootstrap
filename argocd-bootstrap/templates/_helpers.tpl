{{/*
Helpers for the root chart. Toolchain templates may use them as well.
*/}}

{{/*
True (non-empty) when the cluster is a remote destination of a hub Argo CD.
*/}}
{{- define "argocd-bootstrap.isRemote" -}}
{{- $d := .Values.cluster.destination | default dict -}}
{{- if and $d.name (ne $d.name "in-cluster") -}}true{{- end -}}
{{- end -}}

{{/*
Application destination without the namespace, for example:
  destination:
    {{- include "argocd-bootstrap.destination" . | nindent 4 }}
    namespace: <namespace>
In-cluster renders the server URL; hub mode renders the registered cluster name.
*/}}
{{- define "argocd-bootstrap.destination" -}}
{{- if include "argocd-bootstrap.isRemote" . -}}
name: {{ .Values.cluster.destination.name }}
{{- else -}}
server: https://kubernetes.default.svc
{{- end -}}
{{- end -}}

{{/*
Argo CD object name, prefixed with the cluster name in hub mode so that one
Argo CD can hold the Applications of several clusters.
Usage: {{ include "argocd-bootstrap.name" (list . "cert-manager") }}
*/}}
{{- define "argocd-bootstrap.name" -}}
{{- $root := index . 0 -}}
{{- $name := index . 1 -}}
{{- if include "argocd-bootstrap.isRemote" $root -}}
{{- printf "%s-%s" $root.Values.cluster.name $name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Environments hosted by this cluster, as a JSON list.
*/}}
{{- define "argocd-bootstrap.environments" -}}
{{- .Values.cluster.environments | default (list "dev" "stage" "prod") | toJson -}}
{{- end -}}

{{/*
Name of the AppProject for application environment <env>.
Usage: {{ include "argocd-bootstrap.appsProject" (list . "dev") }}
*/}}
{{- define "argocd-bootstrap.appsProject" -}}
{{- include "argocd-bootstrap.name" (list (index . 0) (printf "apps-%s" (index . 1))) -}}
{{- end -}}

{{/*
Name of the platform AppProject.
*/}}
{{- define "argocd-bootstrap.platformProject" -}}
{{- include "argocd-bootstrap.name" (list . "platform") -}}
{{- end -}}

{{/*
Source repositories allowed in every project of this repository.
*/}}
{{- define "argocd-bootstrap.sourceRepos" -}}
{{- $repos := list .Values.git.repoURL -}}
{{- range .Values.projects.extraSourceRepos }}{{ $repos = append $repos . }}{{ end -}}
{{- $repos | uniq | toJson -}}
{{- end -}}

{{/*
Common labels for objects rendered by this chart.
*/}}
{{- define "argocd-bootstrap.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: argocd-bootstrap
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/*
Application instances as a YAML list: one entry per app and environment
hosted by this cluster. Shared by the static Applications and the
ApplicationSet so both modes render the same inventory.
Fields: name, app, env, chart, namespace, project, generatePaths.
*/}}
{{- define "argocd-bootstrap.appInstances" -}}
{{- $root := . -}}
{{- $hosted := include "argocd-bootstrap.environments" . | fromJsonArray -}}
{{- $out := list -}}
{{- range $app := .Values.apps -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $app.name) -}}
{{- fail (printf "apps: invalid name %q" $app.name) -}}
{{- end -}}
{{- $chart := required (printf "apps.%s.chart is required" $app.name) $app.chart | trimPrefix "./" | trimSuffix "/" -}}
{{- range $env := $app.environments -}}
{{- if not (has $env (list "dev" "stage" "prod")) -}}
{{- fail (printf "apps.%s: unknown environment %q" $app.name $env) -}}
{{- end -}}
{{- if has $env $hosted -}}
{{- $paths := list (printf "/%s" $chart) "/helmcharts/helm-common" (printf "/envs/%s/%s" $env $app.name) -}}
{{- $out = append $out (dict
      "name" (include "argocd-bootstrap.name" (list $root (printf "%s-%s" $app.name $env)))
      "app" $app.name
      "env" $env
      "chart" $chart
      "namespace" (required (printf "namespaces.%s is required" $env) (index $root.Values.namespaces $env))
      "project" (include "argocd-bootstrap.appsProject" (list $root $env))
      "generatePaths" (join ";" $paths)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $out | toYaml -}}
{{- end -}}

{{/*
Body of an application Application: metadata and spec. Takes a dict with the
root context under "root" and the fields of appInstances. String fields may
also hold ApplicationSet Go template expressions; every field is quoted.
*/}}
{{- define "argocd-bootstrap.appBody" -}}
{{- $root := .root -}}
metadata:
  name: {{ .name | quote }}
  namespace: {{ $root.Values.namespaces.argocd }}
  labels:
    app.kubernetes.io/name: {{ .app | quote }}
    app.kubernetes.io/part-of: apps
    environment: {{ .env | quote }}
  annotations:
    argocd.argoproj.io/sync-wave: "10"
    argocd.argoproj.io/manifest-generate-paths: {{ .generatePaths | quote }}
    {{- if include "argocd-bootstrap.kargoPipelines" $root }}
    # The Kargo Stage <env> of Project kargo-<app> may sync this Application
    # (argocd-update step). Rendered only when Kargo pipelines are enabled.
    kargo.akuity.io/authorized-stage: {{ printf "%s:%s" (include "argocd-bootstrap.kargoProject" (list $root .app)) .env | quote }}
    {{- end }}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: {{ .project | quote }}
  sources:
    - repoURL: {{ $root.Values.git.repoURL }}
      targetRevision: {{ $root.Values.git.targetRevision | quote }}
      path: {{ .chart | quote }}
      helm:
        releaseName: {{ .app | quote }}
        valueFiles:
          - values.yaml
          - {{ printf "$values/envs/%s/%s/values.yaml" .env .app | quote }}
        valuesObject:
          global:
            environment: {{ .env | quote }}
            domain: {{ $root.Values.cluster.domain | quote }}
            cluster: {{ $root.Values.cluster.name | quote }}
            profile: {{ $root.Values.cluster.profile | quote }}
            imageRegistry: {{ $root.Values.platform.imageRegistry | quote }}
          {{- if dig "monitoring" "enabled" false $root.Values.toolchains }}
          # Prometheus runs on this cluster: scrape every app (observability
          # contract). The canary analysis and Kargo verification read these
          # metrics. Set here, so the ServiceMonitor kind is never rendered
          # on a cluster without the monitoring toolchain.
          metrics:
            serviceMonitor:
              enabled: true
          {{- end }}
    - repoURL: {{ $root.Values.git.repoURL }}
      targetRevision: {{ $root.Values.git.targetRevision | quote }}
      ref: values
  destination:
    {{- include "argocd-bootstrap.destination" $root | nindent 4 }}
    namespace: {{ .namespace | quote }}
  # During a canary the Argo Rollouts Gateway API plugin sets the backend
  # weights of the HTTPRoute; selfHeal must not revert them.
  ignoreDifferences:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      jqPathExpressions:
        - .spec.rules[].backendRefs[]?.weight
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
      - PruneLast=true
      - ServerSideApply=true
      - RespectIgnoreDifferences=true
    retry:
      limit: 5
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 3m
  revisionHistoryLimit: 10
{{- end -}}

{{/*
True (non-empty) when Kargo promotion pipelines render for this cluster: the
kargo toolchain is enabled and toolchains.kargo.pipelines.enabled is not
false.
*/}}
{{- define "argocd-bootstrap.kargoPipelines" -}}
{{- if and (dig "kargo" "enabled" false .Values.toolchains) (ne (toString (dig "kargo" "pipelines" "enabled" true .Values.toolchains)) "false") -}}true{{- end -}}
{{- end -}}

{{/*
Kargo Project name of an app: <projectPrefix><app>, with the prefix of the
kargo-pipelines chart (default kargo-).
Usage: {{ include "argocd-bootstrap.kargoProject" (list . "hello-api") }}
*/}}
{{- define "argocd-bootstrap.kargoProject" -}}
{{- $root := index . 0 -}}
{{- $prefix := dig "kargo" "pipelines" "values" "projectPrefix" "kargo-" $root.Values.toolchains -}}
{{- printf "%s%s" $prefix (index . 1) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Kargo Project namespaces of this cluster as a JSON list, empty when the
pipelines do not render. Destinations of the platform project.
*/}}
{{- define "argocd-bootstrap.kargoProjects" -}}
{{- $out := list -}}
{{- if include "argocd-bootstrap.kargoPipelines" . -}}
{{- range $i := include "argocd-bootstrap.appInstances" . | fromYamlArray -}}
{{- $out = append $out (include "argocd-bootstrap.kargoProject" (list $ $i.app)) -}}
{{- end -}}
{{- end -}}
{{- $out | uniq | toJson -}}
{{- end -}}
