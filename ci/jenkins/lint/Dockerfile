# Controller image used only by hack/jenkins-lint.sh: the pinned LTS with the
# exact plugin set of the install_jenkins role. Never deployed.
FROM jenkins/jenkins:2.580.2-lts-jdk21@sha256:74401de6a6f92e1afe1b02d1c8e3d0c33f263bfb5275dd8813f9150355f2367b

COPY --chown=jenkins:jenkins plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt --latest false

# SECRETS is the JCasC secrets directory path, not secret data.
# hadolint ignore=DL3064
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false -Dcom.cloudbees.plugins.credentials.UseItemPermission=true" \
    CASC_JENKINS_CONFIG=/etc/jenkins/casc \
    SECRETS=/etc/jenkins/casc-secrets
