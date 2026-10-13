{{/*
Expand the name of the chart.
*/}}
{{- define "projeqtor.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "projeqtor.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "projeqtor.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels.
*/}}
{{- define "projeqtor.labels" -}}
helm.sh/chart: {{ include "projeqtor.chart" . }}
{{ include "projeqtor.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Selector labels.
*/}}
{{- define "projeqtor.selectorLabels" -}}
app.kubernetes.io/name: {{ include "projeqtor.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Name of the service account to use.
*/}}
{{- define "projeqtor.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "projeqtor.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Name of the ConfigMap holding the PQ_DB_* environment variables.
*/}}
{{- define "projeqtor.configMapName" -}}
{{- printf "%s-config" (include "projeqtor.fullname" .) -}}
{{- end -}}

{{/*
Name of the Secret holding PQ_DB_PASSWORD (empty when none is configured).
*/}}
{{- define "projeqtor.secretName" -}}
{{- if .Values.database.existingSecret -}}
{{- if eq .Values.database.existingSecretKey "PQ_DB_PASSWORD" -}}
{{- .Values.database.existingSecret -}}
{{- end -}}
{{- else if .Values.database.password -}}
{{- printf "%s-db" (include "projeqtor.fullname" .) -}}
{{- end -}}
{{- end -}}
