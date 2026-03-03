# Component versions

Validated at publish time on the versions listed below. No ongoing maintenance SLA; **updates welcome via PR.**

## Runtimes & platforms

| Component | Where defined | Example / note |
|-----------|----------------|-----------------|
| **RKE** | `ansible/roles/common/defaults/main.yml` → `rke_version` | v1.8.10 (RKE1 EOL July 2025; consider RKE2/K3s for new clusters) |
| **Kubernetes** | `ansible/roles/k8s_bootstrap/defaults/main.yml` → `kubernetes_version`, `kubernetes_supported_versions` | 1.28 default; 1.30, 1.31 also supported with RKE 1.8 |
| **kubectl** | `ansible/roles/common/defaults/main.yml` → `kubectl_version` | v1.31.2 |
| **Docker** | Installed by Ansible common role (Docker CE) | — |
| **Java** (host) | `ansible/roles/common/defaults/main.yml` → `java_version` | 21 |
| **Argo CD** | `helmcharts/system-charts/argo-cd/Chart.yaml` | Chart 7.8.0, app v2.14.3 |
| **ingress-nginx** | `helmcharts/system-charts/ingress-nginx/Chart.yaml` | Chart 4.12.0, controller 1.11.3 |
| **cert-manager** | `helmcharts/system-charts/cert-manager/Chart.yaml` | v1.16.2 |
| **Sealed Secrets** | `helmcharts/system-charts/sealed-secrets/Chart.yaml` | Chart 2.16.2, app 0.27.2 |

## Sample applications

| Sample | Runtime | Key libraries |
|--------|---------|----------------|
| **python-django** | python:3.12.12 | Django 4.2 LTS, gunicorn, etc. |
| **java-springboot** | eclipse-temurin:21.0.5_17-jre, maven:3.9.9-eclipse-temurin-21 | Spring Boot 3.4.2 |
| **laravel-docker-example** | php:8.3.14-apache, composer:2.8.4 | Laravel 11, PHP 8.3 |
| **surge-wp-plugin** | wordpress:6.4-php8.3-apache | WordPress + Surge plugin |

To upgrade: edit the relevant Dockerfile, requirements.txt, pom.xml, or composer.json; test; then update this table.
