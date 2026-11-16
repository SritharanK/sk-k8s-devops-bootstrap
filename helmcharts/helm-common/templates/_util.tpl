{{/*
Values handling for every public template.

A consumer declares helm-common as a dependency without an alias, so Helm
coalesces the library defaults under .Values "helm-common". The consumer sets
the same keys at the top level of its own values. common.render merges the
consumer values over a copy of the defaults and renders the requested
template with a context whose .Values is the merged result. Templates never
read the consumer .Values directly and never use the Sprig default function
for booleans or numbers, so false and 0 survive.
*/}}

{{/*
Recursive merge. Call with (list $dst $src). Mutates $dst.
- maps merge key by key, recursively
- lists and scalars from $src replace the value in $dst
- false and 0 from $src are kept
- a nil value in $src removes the key from $dst
*/}}
{{- define "common.util.mergeInto" -}}
{{- $dst := index . 0 -}}
{{- $src := index . 1 -}}
{{- range $k, $v := $src -}}
{{- if kindIs "invalid" $v -}}
{{- $_ := unset $dst $k -}}
{{- else if kindIs "map" $v -}}
{{- if not (kindIs "map" (index $dst $k)) -}}
{{- $_ := set $dst $k (dict) -}}
{{- end -}}
{{- include "common.util.mergeInto" (list (index $dst $k) $v) -}}
{{- else -}}
{{- $_ := set $dst $k $v -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Probe handler rule. When the consumer probe sets a handler (httpGet,
tcpSocket, grpc or exec), the default handlers of the other types are dropped
before the merge, so a tcpSocket probe does not end up next to the default
httpGet. A handler of the same type still merges key by key, so setting only
livenessProbe.httpGet.path keeps the default port.
Call with (list $defaults $user). Mutates $defaults.
*/}}
{{- define "common.util.probeHandlers" -}}
{{- $defaults := index . 0 -}}
{{- $user := index . 1 -}}
{{- $handlers := list "httpGet" "tcpSocket" "grpc" "exec" -}}
{{- range $probe := list "livenessProbe" "readinessProbe" "startupProbe" -}}
{{- $up := index $user $probe -}}
{{- $dp := index $defaults $probe -}}
{{- if and (kindIs "map" $up) (kindIs "map" $dp) -}}
{{- $userHandler := false -}}
{{- range $h := $handlers -}}
{{- if not (kindIs "invalid" (index $up $h)) -}}
{{- $userHandler = true -}}
{{- end -}}
{{- end -}}
{{- if $userHandler -}}
{{- range $h := $handlers -}}
{{- if kindIs "invalid" (index $up $h) -}}
{{- $_ := unset $dp $h -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Global value lookup. Call with (list $values "key"). Returns the value of
global.<key> as a string, or an empty string when it is not set.
*/}}
{{- define "common.util.global" -}}
{{- $global := index (index . 0) "global" -}}
{{- if kindIs "map" $global -}}
{{- $value := index $global (index . 1) -}}
{{- if include "common.util.isSet" $value -}}
{{- toString $value -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Dispatcher. Call with (list $ "common.tpl.<kind>"). Builds the merged
values and renders the named template with them.

Precedence, lowest first:
1. library defaults (.Values "helm-common")
2. consumer values (chart values.yaml, value files, --set)
3. environments.<global.environment>, when that entry exists
The environments key is removed from the merged values, so it never reaches
a rendered object.
*/}}
{{- define "common.render" -}}
{{- $top := index . 0 -}}
{{- $tpl := index . 1 -}}
{{- if not (kindIs "map" (index $top.Values "helm-common")) -}}
{{- fail "helm-common defaults not found under .Values \"helm-common\": declare the helm-common dependency without an alias and run helm dependency build" -}}
{{- end -}}
{{- $merged := deepCopy (index $top.Values "helm-common") -}}
{{- $user := deepCopy (omit $top.Values "helm-common") -}}
{{- include "common.util.probeHandlers" (list $merged $user) -}}
{{- include "common.util.mergeInto" (list $merged $user) -}}
{{- $environment := include "common.util.global" (list $merged "environment") -}}
{{- /* Read the override from the consumer values, not from $merged, so null entries in it are still present and can unset a key. */ -}}
{{- $environments := index $user "environments" -}}
{{- if and $environment (kindIs "map" $environments) -}}
{{- $override := index $environments $environment -}}
{{- if kindIs "map" $override -}}
{{- include "common.util.probeHandlers" (list $merged $override) -}}
{{- include "common.util.mergeInto" (list $merged $override) -}}
{{- end -}}
{{- end -}}
{{- $_ := unset $merged "environments" -}}
{{- $ctx := dict "Values" $merged "Release" $top.Release "Chart" $top.Chart "Capabilities" $top.Capabilities "Template" $top.Template "Files" $top.Files -}}
{{- include $tpl $ctx | trim -}}
{{- end -}}

{{/*
Returns "true" when the value is set (not nil and not an empty string).
Numbers and booleans count as set, including 0 and false.
*/}}
{{- define "common.util.isSet" -}}
{{- if kindIs "invalid" . -}}
{{- else if and (kindIs "string" .) (eq . "") -}}
{{- else -}}true{{- end -}}
{{- end -}}

{{/*
Converts every value of a map to a string. Call with the map, returns YAML.
Used for labels and annotations, which must be strings.
*/}}
{{- define "common.util.stringMap" -}}
{{- $out := dict -}}
{{- range $k, $v := . -}}
{{- if not (kindIs "invalid" $v) -}}
{{- $_ := set $out $k (toString $v) -}}
{{- end -}}
{{- end -}}
{{- if $out -}}
{{- toYaml $out -}}
{{- end -}}
{{- end -}}
