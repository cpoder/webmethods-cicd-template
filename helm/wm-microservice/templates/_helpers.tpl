{{/*
Helpers for wm-microservice.

These follow the canonical helm conventions (selectorLabels are stable
across upgrades and never include version/chart -- otherwise the
Deployment selector immutability rule fires on chart bumps).
*/}}

{{/*
Expand the name of the chart.
*/}}
{{- define "wm-microservice.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some k8s name fields are limited.
*/}}
{{- define "wm-microservice.fullname" -}}
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
{{- define "wm-microservice.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels (applied to every object).
*/}}
{{- define "wm-microservice.labels" -}}
helm.sh/chart: {{ include "wm-microservice.chart" . }}
{{ include "wm-microservice.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: msr
app.kubernetes.io/part-of: wm-microservice
{{- end -}}

{{/*
Selector labels (must NEVER include chart version -- selectors on
Deployment/Service are immutable, so a chart bump would orphan pods).
*/}}
{{- define "wm-microservice.selectorLabels" -}}
app.kubernetes.io/name: {{ include "wm-microservice.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Service-account name. If serviceAccount.create=true the SA is created
by templates/serviceaccount.yaml using this name; otherwise an existing
SA name is referenced.
*/}}
{{- define "wm-microservice.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "wm-microservice.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
The Secret resource name. Both ExternalSecret and plain Secret render
to this name so the Deployment's envFrom block doesn't care which
backend produced it.
*/}}
{{- define "wm-microservice.secretName" -}}
{{ include "wm-microservice.fullname" . }}
{{- end -}}

{{/*
True iff a Secret/ExternalSecret will be rendered. Used to gate the
Deployment's secret envFrom + secret checksum annotation.
*/}}
{{- define "wm-microservice.secretEnabled" -}}
{{- if or .Values.externalSecrets.enabled .Values.secret.enabled -}}
true
{{- end -}}
{{- end -}}
