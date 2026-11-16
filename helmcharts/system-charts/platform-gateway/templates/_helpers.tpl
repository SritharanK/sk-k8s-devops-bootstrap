{{- define "platform-gateway.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: platform
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{- /* CRDs come from other Applications (gateway-api, cert-manager). */ -}}
{{- define "platform-gateway.annotations" -}}
argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
{{- end }}

{{- define "platform-gateway.domain" -}}
{{- $d := required "platform.domain is required" .Values.platform.domain -}}
{{- if or (hasPrefix "*" $d) (hasPrefix "." $d) -}}
{{- fail "platform.domain must be a plain domain such as example.com, without a wildcard" -}}
{{- end -}}
{{- $d -}}
{{- end }}

{{- /*
Certificate dnsNames as a JSON list (see README, Certificate names).
- selfsigned, any non-ACME issuer, or ACME with the dns01 solver:
  <domain>, *.<domain> and *.<env>.<domain> for every environment.
- ACME with the http01 solver: platform.gateway.hostnames, no wildcard.
*/ -}}
{{- define "platform-gateway.dnsNames" -}}
{{- $domain := include "platform-gateway.domain" . -}}
{{- $acme := has .Values.platform.issuer .Values.acmeIssuers -}}
{{- $solver := dig "acme" "solver" "http01" .Values.platform -}}
{{- if not (has $solver (list "http01" "dns01")) -}}
{{- fail (printf "platform-gateway: platform.acme.solver must be http01 or dns01, not %q" $solver) -}}
{{- end -}}
{{- $names := list -}}
{{- if and $acme (eq $solver "http01") -}}
{{- $names = dig "gateway" "hostnames" list .Values.platform -}}
{{- if empty $names -}}
{{- fail (printf "platform-gateway: issuer %s with solver http01 needs platform.gateway.hostnames (HTTP-01 cannot validate wildcard names)" .Values.platform.issuer) -}}
{{- end -}}
{{- range $names -}}
{{- if hasPrefix "*" . -}}
{{- fail (printf "platform-gateway: %q is a wildcard; HTTP-01 cannot validate wildcards, use solver dns01" .) -}}
{{- end -}}
{{- if not (hasSuffix (printf ".%s" $domain) .) -}}
{{- fail (printf "platform-gateway: %q is not a subdomain of %s, so the https listener does not serve it" . $domain) -}}
{{- end -}}
{{- end -}}
{{- else -}}
{{- $names = list $domain (printf "*.%s" $domain) -}}
{{- range .Values.platform.environments -}}
{{- $names = append $names (printf "*.%s.%s" . $domain) -}}
{{- end -}}
{{- end -}}
{{- $names | uniq | toJson -}}
{{- end }}
