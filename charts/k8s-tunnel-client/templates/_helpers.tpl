{{/* Naming and labels, mirroring charts/k8s-tunnel so both charts read the same way.
     `fullname` is the RELEASE name, not <release>-<chart>. */}}

{{- define "k8s-tunnel-client.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "k8s-tunnel-client.fullname" -}}
{{- if .Values.fullnameOverride }}{{ .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}{{ .Release.Name | trunc 63 | trimSuffix "-" }}{{ end }}
{{- end }}

{{- define "k8s-tunnel-client.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "k8s-tunnel-client.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "k8s-tunnel-client.selectorLabels" -}}
app.kubernetes.io/name: {{ include "k8s-tunnel-client.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* Quote a value as a POSIX shell single-quoted string.

     Every value in the ConfigMap is `.`-sourced by the supervisor, so a value containing `$`, a
     backtick or a quote must survive being read back by the shell. Unquoted, `$$` expands to the
     shell's pid and a password containing it is silently WRONG -- which surfaces as a 401 at
     handshake time with nothing in the payload to explain it. A single quote cannot appear inside
     a single-quoted string, so it is closed, escaped and reopened via the '\'' idiom.

     Use this instead of `quote`: Go's `quote` emits double quotes, which re-introduce expansion. */}}
{{- define "k8s-tunnel-client.shQuote" -}}
{{- printf "'%s'" (replace "'" "'\\''" (toString .)) -}}
{{- end }}

{{/* Refuse to render a configuration that cannot work, naming the offending entry.

     Each of these would otherwise fail LATER and less clearly: a name Kubernetes rejects, a
     password expanded to the wrong value, two tunnels racing for one socket, a NodePort outside
     the range, or a port collision that only shows up on the next reinstall. */}}
{{- define "k8s-tunnel-client.validate" -}}
{{- $backends := .Values.backends -}}
{{- if not $backends -}}
{{- fail "backends is empty: refusing to render a Service with no ports. An empty list means the pod would run zero tunnels while still reporting Ready." -}}
{{- end -}}

{{/* A tunnel's listen port inside the pod is derived, never configured: it is an implementation
     detail no consumer sees (they use the nodePort), and deriving it removes any chance of two
     tunnels racing for one socket or of the Service's targetPort drifting from the port the
     process actually binds. 6443 for the first entry, one higher for each after it. */}}
{{- if not .Values.dest -}}
{{- fail "dest is required: it is the destination each tunnel forwards to, and it must match every backend's restrictTo exactly" -}}
{{- end -}}

{{- $names := list -}}
{{- $nodePorts := list -}}

{{- range $i, $b := $backends -}}
{{- $at := printf "backends[%d]" $i -}}

{{- if not $b.name -}}
{{- fail (printf "%s.name is required: it is the ConfigMap key, the Service port name and the tunnel's identity" $at) -}}
{{- end -}}
{{- $name := $b.name | toString -}}
{{- if gt (len $name) 15 -}}
{{- fail (printf "%s.name %q is %d characters long; Kubernetes caps a Service port name at 15" $at $name (len $name)) -}}
{{- end -}}
{{- if not (regexMatch "^[a-z0-9-]+$" $name) -}}
{{- fail (printf "%s.name %q is not a valid Service port name: lowercase alphanumerics and '-' only" $at $name) -}}
{{- end -}}
{{- if not (regexMatch "[a-z]" $name) -}}
{{- fail (printf "%s.name %q is not a valid Service port name: it must contain at least one letter" $at $name) -}}
{{- end -}}
{{- if regexMatch "(^-)|(-$)|(--)" $name -}}
{{- fail (printf "%s.name %q is not a valid Service port name: no leading, trailing or doubled '-'" $at $name) -}}
{{- end -}}
{{- if has $name $names -}}
{{- fail (printf "%s.name %q is a duplicate; the name is both the ConfigMap key and the Service port name, so it must be unique" $at $name) -}}
{{- end -}}
{{- $names = append $names $name -}}

{{- if not $b.host -}}
{{- fail (printf "%s.host is required" $at) -}}
{{- end -}}
{{- if regexMatch "://" ($b.host | toString) -}}
{{- fail (printf "%s.host %q carries a scheme; the client builds wss:// itself, so give the bare hostname" $at $b.host) -}}
{{- end -}}

{{- if not $b.prefix -}}
{{- fail (printf "%s.prefix is required: the backend's wstunnel rejects an upgrade that carries no prefix" $at) -}}
{{- end -}}
{{- if hasPrefix "/" ($b.prefix | toString) -}}
{{- fail (printf "%s.prefix %q starts with a slash; the backend's ingress path already supplies it" $at $b.prefix) -}}
{{- end -}}

{{- if not $b.user -}}
{{- fail (printf "%s.user is required" $at) -}}
{{- end -}}
{{- if not $b.password -}}
{{- fail (printf "%s.password is required; the backend's nginx rejects the upgrade without it" $at) -}}
{{- end -}}
{{- if contains "\n" ($b.password | toString) -}}
{{- fail (printf "%s.password contains a newline, which cannot be written into a shell-sourced config unambiguously; rotate it" $at) -}}
{{- end -}}

{{- if not $b.nodePort -}}
{{- fail (printf "%s.nodePort is required, and is pinned on purpose: an auto-allocated port is not reproducible across a reinstall, and a changed port silently invalidates every kubeconfig already handed out" $at) -}}
{{- end -}}
{{- $np := $b.nodePort | int -}}
{{- if or (lt $np 30000) (gt $np 32767) -}}
{{- fail (printf "%s.nodePort %d is outside the default NodePort range 30000-32767" $at $np) -}}
{{- end -}}
{{- if has $np $nodePorts -}}
{{- fail (printf "%s.nodePort %d is a duplicate; Kubernetes rejects a Service that declares the same nodePort twice" $at $np) -}}
{{- end -}}
{{- $nodePorts = append $nodePorts $np -}}

{{- end -}}
{{- end }}
