{{/*
Common labels.
*/}}
{{- define "kyverno-policies.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: platform
app.kubernetes.io/instance: {{ .Release.Name }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end -}}

{{/*
Annotations shared by every policy object. The policy CRDs come from the
kyverno Application, which syncs in an earlier wave.
*/}}
{{- define "kyverno-policies.syncAnnotations" -}}
argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
{{- end -}}

{{/*
Namespaces grouped by failure action, as YAML: {Audit: [..], Enforce: [..]}.
Only enabled environments are included, and only actions with at least one
namespace appear. Argument: the root context.
*/}}
{{- define "kyverno-policies.actionGroups" -}}
{{- $groups := dict -}}
{{- range $env, $cfg := .Values.environments -}}
{{- if and $cfg (ne (toString (dig "enabled" true $cfg)) "false") -}}
{{- $ns := required (printf "environments.%s.namespace is required" $env) $cfg.namespace -}}
{{- $action := required (printf "environments.%s.action is required" $env) $cfg.action -}}
{{- if not (has $action (list "Audit" "Enforce")) -}}
{{- fail (printf "environments.%s.action must be Audit or Enforce, got %q" $env $action) -}}
{{- end -}}
{{- $_ := set $groups $action (append (get $groups $action | default list) $ns) -}}
{{- end -}}
{{- end -}}
{{- toYaml $groups -}}
{{- end -}}

{{/*
validationActions for a failure action.
*/}}
{{- define "kyverno-policies.validationActions" -}}
{{- if eq . "Enforce" -}}
[Deny]
{{- else -}}
[Audit, Warn]
{{- end -}}
{{- end -}}

{{/*
failurePolicy for a failure action: Enforce fails closed, Audit fails open.
*/}}
{{- define "kyverno-policies.failurePolicy" -}}
{{- if eq . "Enforce" -}}
Fail
{{- else -}}
Ignore
{{- end -}}
{{- end -}}

{{/*
Allowed registry prefixes, each ending in "/", as a JSON list (a CEL list
literal).
*/}}
{{- define "kyverno-policies.allowedRegistries" -}}
{{- $out := list -}}
{{- range $r := required "allowedRegistries must not be empty" .Values.allowedRegistries -}}
{{- $out = append $out (printf "%s/" (trimSuffix "/" $r)) -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}

{{/*
resourceRules for pods and pod controllers. Policies match the controllers
directly, so a non-compliant Deployment is rejected when Argo CD applies it,
not later when its ReplicaSet creates pods. ReplicaSets are left out because
Kyverno filters them by default (config.resourceFilters).
*/}}
{{- define "kyverno-policies.workloadRules" -}}
- apiGroups: [""]
  apiVersions: [v1]
  operations: [CREATE, UPDATE]
  resources: [pods]
- apiGroups: [""]
  apiVersions: [v1]
  operations: [UPDATE]
  resources: [pods/ephemeralcontainers]
- apiGroups: [apps]
  apiVersions: [v1]
  operations: [CREATE, UPDATE]
  resources: [deployments, statefulsets, daemonsets]
- apiGroups: [batch]
  apiVersions: [v1]
  operations: [CREATE, UPDATE]
  resources: [jobs, cronjobs]
{{- end -}}

{{- define "kyverno-policies.serviceRules" -}}
- apiGroups: [""]
  apiVersions: [v1]
  operations: [CREATE, UPDATE]
  resources: [services]
{{- end -}}

{{/*
CEL variables that extract the pod spec from a Pod or a pod controller.
`containers` covers regular, init and ephemeral containers.
*/}}
{{- define "kyverno-policies.podVariables" -}}
- name: podSpec
  expression: >-
    object.kind == 'Pod' ? object.spec :
    (object.kind == 'CronJob' ? object.spec.jobTemplate.spec.template.spec : object.spec.template.spec)
- name: containers
  expression: >-
    variables.podSpec.containers +
    variables.podSpec.?initContainers.orValue([]) +
    variables.podSpec.?ephemeralContainers.orValue([])
{{- end -}}

{{/*
Names of every ValidatingPolicy this release renders, as a YAML list.
*/}}
{{- define "kyverno-policies.renderedPolicyNames" -}}
{{- $names := list -}}
{{- $catalogue := include "kyverno-policies.catalogue" . | fromYaml -}}
{{- $groups := include "kyverno-policies.actionGroups" . | fromYaml -}}
{{- range $policy := $catalogue.policies -}}
{{- if not (has $policy.name $.Values.disabledPolicies) -}}
{{- range $action, $_ := $groups -}}
{{- $names = append $names (printf "%s-%s" $policy.name (lower $action)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- toYaml $names -}}
{{- end -}}
