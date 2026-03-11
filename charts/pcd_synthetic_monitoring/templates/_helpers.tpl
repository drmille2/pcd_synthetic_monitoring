{{/*
Expand the name of the chart.
*/}}
{{- define "pcd-synthetic.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "pcd-synthetic.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create config map and secret names
*/}}
{{- define "pcd-synthetic.monitorConfigName" -}}
{{- default (include "pcd-synthetic.fullname" .) .Values.monitorConfigNameOverride }}
{{- end }}

{{- define "pcd-synthetic.outputConfigName" -}}
{{- default "pcd-synthetic-db-conf" .Values.outputConfigNameOverride }}
{{- end }}

{{- define "pcd-synthetic.pcdEnvSecretName" -}}
{{- default (include "pcd-synthetic.fullname" .) .Values.pcdEnvSecretNameOverride }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "pcd-synthetic.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "pcd-synthetic.labels" -}}
helm.sh/chart: {{ include "pcd-synthetic.chart" . }}
{{ include "pcd-synthetic.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "pcd-synthetic.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pcd-synthetic.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "pcd-synthetic.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "pcd-synthetic.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
