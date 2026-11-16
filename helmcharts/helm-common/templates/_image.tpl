{{/*
Container image reference.
- image.repository is required and must not carry a tag or digest itself.
- Registry prefix: global.imageRegistry, else image.registry. It is prepended
  only when image.repository does not already start with a registry host
  (a first path segment that contains "." or ":", or equals "localhost").
- The resulting path must be lowercase, as OCI repository names require.
- image.digest, when set, must be sha256:<64 hex>; renders path@digest
  and the tag is ignored.
- Otherwise the tag is image.tag, else the chart appVersion. Renders
  path:tag. A missing tag and the tag "latest" fail the render.
*/}}
{{- define "common.image" -}}
{{- $image := .Values.image -}}
{{- $repository := toString (required "image.repository is required: set it to the image name (with image.registry or global.imageRegistry) or to a full path such as registry.example.com/your-org/app" (index $image "repository")) -}}
{{- $lastSegment := last (splitList "/" $repository) -}}
{{- if or (contains "@" $repository) (contains ":" $lastSegment) -}}
{{- fail (printf "image.repository %q must not contain a tag or digest: set image.tag or image.digest instead" $repository) -}}
{{- end -}}
{{- $registry := include "common.util.global" (list .Values "imageRegistry") -}}
{{- if not $registry -}}
{{- $chartRegistry := index $image "registry" -}}
{{- if include "common.util.isSet" $chartRegistry -}}
{{- $registry = toString $chartRegistry -}}
{{- end -}}
{{- end -}}
{{- $registry = trimSuffix "/" $registry -}}
{{- $firstSegment := first (splitList "/" $repository) -}}
{{- $hasHost := and (gt (len (splitList "/" $repository)) 1) (or (contains "." $firstSegment) (contains ":" $firstSegment) (eq $firstSegment "localhost")) -}}
{{- $path := $repository -}}
{{- if and $registry (not $hasHost) -}}
{{- $path = printf "%s/%s" $registry $repository -}}
{{- end -}}
{{- if ne (lower $path) $path -}}
{{- fail (printf "image path %q contains uppercase characters: OCI repository names must be lowercase" $path) -}}
{{- end -}}
{{- $digest := index $image "digest" -}}
{{- if include "common.util.isSet" $digest -}}
{{- $digest = toString $digest -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" $digest) -}}
{{- fail (printf "image.digest %q is not valid: use the form sha256:<64 lowercase hex characters>" $digest) -}}
{{- end -}}
{{- printf "%s@%s" $path $digest -}}
{{- else -}}
{{- $tag := "" -}}
{{- $userTag := index $image "tag" -}}
{{- if include "common.util.isSet" $userTag -}}
{{- $tag = toString $userTag -}}
{{- else if .Chart.AppVersion -}}
{{- $tag = toString .Chart.AppVersion -}}
{{- end -}}
{{- if not $tag -}}
{{- fail "image tag is empty: set image.tag or image.digest, or set appVersion in Chart.yaml" -}}
{{- end -}}
{{- if eq (lower $tag) "latest" -}}
{{- fail "image tag \"latest\" is not allowed by the workload policies: pin an immutable version tag or set image.digest" -}}
{{- end -}}
{{- printf "%s:%s" $path $tag -}}
{{- end -}}
{{- end -}}
