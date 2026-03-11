{{- define "tenant.namespace" -}}
{{- if .Values.tenant.namespace -}}
{{- .Values.tenant.namespace -}}
{{- else -}}
tenant-{{ .Values.tenant.orgSlug }}-{{ .Values.tenant.environment }}
{{- end -}}
{{- end -}}

{{- define "tenant.org_namespace" -}}
katonic-{{ .Values.tenant.orgSlug }}
{{- end -}}

{{- define "tenant.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: katonic-platform
katonic.ai/org-slug: {{ .Values.tenant.orgSlug | quote }}
katonic.ai/org-id: {{ .Values.tenant.orgId | quote }}
katonic.ai/environment: {{ .Values.tenant.environment | quote }}
katonic.ai/tenant: "true"
{{- end -}}
