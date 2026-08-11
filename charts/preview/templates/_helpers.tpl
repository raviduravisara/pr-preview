{{- define "preview.name" -}}
app
{{- end -}}

{{- define "preview.host" -}}
{{ .Values.ingress.prefix }}{{ required "prNumber is required" .Values.prNumber }}.{{ .Values.ingress.domain }}
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
