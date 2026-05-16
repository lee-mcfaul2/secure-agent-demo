{{- define "agent-sandbox.fullname" -}}
{{- printf "agent-sandbox" -}}
{{- end -}}

{{- define "agent-sandbox.labels" -}}
app.kubernetes.io/name: agent-sandbox
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
