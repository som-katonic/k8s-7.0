{{- /*
_helpers.tpl - Shared template helpers for the Katonic platform umbrella chart.
*/}}

{{- define "katonic.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "katonic.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s" .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "katonic.namespace" -}}
{{- default "katonic-system" .Values.global.namespace }}
{{- end }}

{{- define "katonic.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: katonic-platform
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 }}
{{- end }}

{{- define "katonic.imageTag" -}}
{{- default .Chart.AppVersion .Values.global.imageTag }}
{{- end }}

{{- define "katonic.imageRegistry" -}}
{{- default "registry.katonic.ai" .Values.global.imageRegistry }}
{{- end }}
