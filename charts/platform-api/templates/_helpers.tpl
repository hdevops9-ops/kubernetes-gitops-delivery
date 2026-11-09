{{- define "platform.name" -}}
{{ .Release.Name }}
{{- end -}}
{{- define "platform.labels" -}}
app.kubernetes.io/name: platform-api
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
