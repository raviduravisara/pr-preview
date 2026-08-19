{{- define "preview.name" -}}
app
{{- end -}}

{{/*
Host for a preview. With no domain set, falls back to sslip.io on the cluster IP,
which resolves without any DNS record or domain purchase.
*/}}
{{- define "preview.host" -}}
{{- $pr := required "prNumber is required" .Values.prNumber -}}
{{- $name := printf "%s%v%s" .Values.ingress.prefix $pr .Values.ingress.suffix -}}
{{- if .Values.ingress.domain -}}
{{ $name }}.{{ .Values.ingress.domain }}
{{- else -}}
{{- $ip := required "set ingress.domain, or ingress.hostIP for sslip.io URLs" .Values.ingress.hostIP -}}
{{ $name }}.{{ $ip | replace "." "-" }}.sslip.io
{{- end -}}
{{- end -}}

{{- define "preview.labels" -}}
app.kubernetes.io/name: preview
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
preview.pr: {{ .Values.prNumber | quote }}
{{- end -}}

{{- define "preview.selectorLabels" -}}
app.kubernetes.io/name: preview
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "preview.database.enabled" -}}
{{- if ne .Values.database.type "none" -}}true{{- end -}}
{{- end -}}

{{- define "preview.database.image" -}}
{{- if .Values.database.image -}}
{{ .Values.database.image }}
{{- else if eq .Values.database.type "postgres" -}}
postgres:17-alpine
{{- else if eq .Values.database.type "mysql" -}}
mysql:8.4
{{- else if eq .Values.database.type "mongodb" -}}
mongo:8.0
{{- end -}}
{{- end -}}

{{- define "preview.database.port" -}}
{{- if eq .Values.database.type "postgres" -}}5432
{{- else if eq .Values.database.type "mysql" -}}3306
{{- else if eq .Values.database.type "mongodb" -}}27017
{{- end -}}
{{- end -}}

{{- define "preview.database.url" -}}
{{- $u := .Values.database.user -}}
{{- $p := .password -}}
{{- $n := .Values.database.name -}}
{{- if eq .Values.database.type "postgres" -}}
postgres://{{ $u }}:{{ $p }}@database:5432/{{ $n }}?sslmode=disable
{{- else if eq .Values.database.type "mysql" -}}
mysql://{{ $u }}:{{ $p }}@database:3306/{{ $n }}
{{- else if eq .Values.database.type "mongodb" -}}
mongodb://{{ $u }}:{{ $p }}@database:27017/{{ $n }}?authSource=admin
{{- end -}}
{{- end -}}

{{- define "preview.database.readinessCommand" -}}
{{- if eq .Values.database.type "postgres" -}}
["pg_isready", "-U", "{{ .Values.database.user }}", "-d", "{{ .Values.database.name }}"]
{{- else if eq .Values.database.type "mysql" -}}
["mysqladmin", "ping", "-h", "127.0.0.1", "-u", "{{ .Values.database.user }}", "-p$(MYSQL_PASSWORD)"]
{{- else if eq .Values.database.type "mongodb" -}}
["mongosh", "--quiet", "--eval", "db.adminCommand('ping')"]
{{- end -}}
{{- end -}}
