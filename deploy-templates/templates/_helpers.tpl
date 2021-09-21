{{- define "jenkins.agent.image" -}}
{{ .Values.image.name }}:{{ .Values.image.version}}
{{- end }}