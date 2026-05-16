{{- define "llm-guard.fullname" -}}
llm-guard
{{- end -}}

{{- define "llm-guard.labels" -}}
app.kubernetes.io/name: llm-guard
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
