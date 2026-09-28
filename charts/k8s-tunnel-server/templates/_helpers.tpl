{{- define "k8s-tunnel-server.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "k8s-tunnel-server.fullname" -}}
{{- if .Values.fullnameOverride }}{{ .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}{{ .Release.Name | trunc 63 | trimSuffix "-" }}{{ end }}
{{- end }}

{{- define "k8s-tunnel-server.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "k8s-tunnel-server.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "k8s-tunnel-server.selectorLabels" -}}
app.kubernetes.io/name: {{ include "k8s-tunnel-server.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "k8s-tunnel-server.prefixSecretName" -}}
{{- default (printf "%s-auth" (include "k8s-tunnel-server.fullname" .)) .Values.existingSecret }}
{{- end }}

{{- define "k8s-tunnel-server.basicAuthSecretName" -}}
{{- default (printf "%s-basic-auth" (include "k8s-tunnel-server.fullname" .)) .Values.basicAuth.existingSecret }}
{{- end }}

{{/*
=============================================================================================
 The two generated secrets. Read this before touching any of the four helpers below.
=============================================================================================

Helm re-executes a named template at EVERY `include`, and randAlphaNum is stateful, so a helper that
generates returns a DIFFERENT value to each caller. That is not a theoretical hazard: this chart used
to generate both secrets that way, and one render produced three disagreeing path prefixes -- the
Secret whose value the server enforces, the Ingress path nginx routes on, and the URL printed in
NOTES.txt. A fresh install could not work at all, and it looked fine only because the first
`helm upgrade` reconciled everything through `lookup`.

A value generated during a render CANNOT be observed by another template. So a secret may only be
generated if every object that must AGREE on it is emitted by the same template execution:

  pathPrefix          -> templates/published-path.yaml emits BOTH the Secret and the Ingress
  basicAuth.password  -> templates/basic-auth-secret.yaml holds both `auth` and `password`

DO NOT split those files apart, and do not call a *generating* helper from anywhere else. NOTES.txt
uses the *IfKnown variants below, which never generate -- precisely so it cannot print a value that
matches nothing.

Resolution order for both secrets:  explicit value  ->  the value already in the cluster  ->  generate.
*/}}

{{/*
The path prefix if it can be determined WITHOUT generating one.

Returns an EMPTY STRING when the value is unknown: a first install against a cluster with no Secret
yet, or any cluster-less render. Callers must handle empty. This never generates and never fails, so
NOTES.txt can call it safely.
*/}}
{{- define "k8s-tunnel-server.pathPrefixIfKnown" -}}
{{- if .Values.pathPrefix -}}
{{- .Values.pathPrefix -}}
{{- else -}}
{{- $s := lookup "v1" "Secret" .Release.Namespace (include "k8s-tunnel-server.prefixSecretName" .) -}}
{{- if and $s $s.data (hasKey $s.data "prefix") (not (empty (index $s.data "prefix"))) -}}
{{- index $s.data "prefix" | b64dec | trim -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
The path prefix, generating one if necessary.

Called from EXACTLY ONE template -- the one that emits both the Secret and the Ingress -- because
calling it twice generates twice.

It is a speed bump, not a secret: it appears in nginx access logs, in `kubectl get ingress`, and in
shell history. Design as if it is known.
*/}}
{{- define "k8s-tunnel-server.pathPrefix" -}}
{{- if and .Values.existingSecret .Values.pathPrefix -}}
{{- fail "set existingSecret OR pathPrefix, never both. The Ingress path comes from pathPrefix while the server enforces whatever the existing Secret holds, so if the two disagree EVERY client gets a 404 and nothing anywhere reports an error." -}}
{{- end -}}
{{- $known := include "k8s-tunnel-server.pathPrefixIfKnown" . -}}
{{- if $known -}}
{{- $known -}}
{{- else if .Values.existingSecret -}}
{{- fail (printf "the Secret %q does not exist, or has no non-empty `prefix` key. Either create it, or drop existingSecret and let the chart generate a prefix. Note a render without cluster access cannot resolve this at all." .Values.existingSecret) -}}
{{- else -}}
{{- randAlphaNum 48 | lower -}}
{{- end -}}
{{- end }}

{{/*
The basic-auth password if it can be determined WITHOUT generating one. Empty string when unknown.
Same contract as pathPrefixIfKnown: never generates, never fails, safe from NOTES.txt.

Reading the stored PLAINTEXT (not the hash) is deliberate and it is what heals a release installed
before this chart was fixed -- see basic-auth-secret.yaml.
*/}}
{{- define "k8s-tunnel-server.basicAuthPasswordIfKnown" -}}
{{- if .Values.basicAuth.password -}}
{{- .Values.basicAuth.password -}}
{{- else -}}
{{- $s := lookup "v1" "Secret" .Release.Namespace (include "k8s-tunnel-server.basicAuthSecretName" .) -}}
{{- if and $s $s.data (hasKey $s.data "password") (not (empty (index $s.data "password"))) -}}
{{- index $s.data "password" | b64dec | trim -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
The basic-auth password, generating one if necessary. Called from EXACTLY ONE template.
*/}}
{{- define "k8s-tunnel-server.basicAuthPassword" -}}
{{- $known := include "k8s-tunnel-server.basicAuthPasswordIfKnown" . -}}
{{- if $known -}}
{{- $known -}}
{{- else -}}
{{- randAlphaNum 40 | lower -}}
{{- end -}}
{{- end }}

{{/*
There is deliberately no `htpasswd` helper any more. It used to hash by calling
`basicAuthPassword` internally, which would have been a SECOND evaluation and therefore a second,
different password -- leaving `auth` and the plaintext stored beside it disagreeing, which is the
exact bug that made every retrieved password return 401. basic-auth-secret.yaml calls sprig's
`htpasswd` directly with the value it already resolved.
*/}}
