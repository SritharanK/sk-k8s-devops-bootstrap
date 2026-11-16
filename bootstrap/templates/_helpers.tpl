{{/*
Fields shared by the root Application of the local cluster and the root
Applications generated for remote clusters in hub mode.
*/}}
{{- define "bootstrap.rootSource" -}}
repoURL: {{ .Values.git.repoURL }}
targetRevision: {{ .Values.git.targetRevision | quote }}
path: argocd-bootstrap
{{- end -}}

{{- define "bootstrap.rootSyncPolicy" -}}
automated:
  prune: true
  selfHeal: true
syncOptions:
  - CreateNamespace=false
  - PruneLast=true
retry:
  limit: 10
  backoff:
    duration: 10s
    factor: 2
    maxDuration: 5m
{{- end -}}
