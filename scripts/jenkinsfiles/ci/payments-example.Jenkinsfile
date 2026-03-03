# -----------------------------------------------------------------------------
# Project: GitOps Kubernetes Platform Bootstrap
# Author : Sritharan K (https://www.skengineer.be)
# License: MIT
# -----------------------------------------------------------------------------
def dockerRegistry = env.DOCKER_REGISTRY ?: "YOUR_DOCKER_REGISTRY/payments-example"
def dockerFile = "Dockerfile"
def serviceName = "payments-example"
def serviceGitRepoUrl = env.SERVICE_GIT_REPO ?: "git@github.com:YOUR_ORG/payments-example.git"
def gitCredsId = env.GIT_CREDS_ID ?: error("GIT_CREDS_ID not set in Jenkins global env")
def dockerCredsId = env.DOCKER_CREDS_ID ?: error("DOCKER_CREDS_ID not set in Jenkins global env")


pipeline {
    agent {
        label (env.JENKINS_AGENT_LABEL ?: "default")
    }
    options {
        ansiColor('xterm')
    }
    
    stages {
        stage('Checkout') {
            steps {
                sshagent(credentials: [gitCredsId]) {
                    git url: "${serviceGitRepoUrl}", branch: 'main', credentialsId: "${gitCredsId}"
                }
                script {
                    gitSha = sh(script: 'git rev-parse HEAD', returnStdout: true).trim()
                    dockerImageTag = "git-${gitSha}"
                }
            }
        }

        stage('Check linting code') {
            steps {
                sh 'echo "Putting your code here"' // NO BREAKING
            }
        }

        stage('Run Unit Tests') {
            steps {
                sh 'echo "Putting your code here"' // NO BREAKING
            }
        }

        stage('Docker build & push') {
            steps {
                script {
                    withCredentials([usernamePassword(credentialsId: dockerCredsId, passwordVariable: 'DOCKER_PASS', usernameVariable: 'DOCKER_USER')]) {
                        sh """
                            docker build -t ${dockerRegistry}:${dockerImageTag} -f ${dockerFile} .
                        """
                    }
                }
            }
        }

        stage('Container vulnerability scan (Trivy)') {
            steps {
                sh """
                    trivy image \\
                      --exit-code 1 \\
                      --severity CRITICAL,HIGH \\
                      --ignore-unfixed \\
                      --scanners vuln,secret \\
                      --format table \\
                      --timeout 10m \\
                      ${dockerRegistry}:${dockerImageTag}
                """
            }
        }

        stage('Push image') {
            steps {
                script {
                    withCredentials([usernamePassword(credentialsId: dockerCredsId, passwordVariable: 'DOCKER_PASS', usernameVariable: 'DOCKER_USER')]) {
                        sh """
                            docker login -u \${DOCKER_USER} -p \${DOCKER_PASS}
                            docker push ${dockerRegistry}:${dockerImageTag}
                        """
                    }
                }
            }
        }

        stage('Generate SBOM (syft)') {
            steps {
                sh """
                    syft ${dockerRegistry}:${dockerImageTag} \\
                      --output cyclonedx-json \\
                      > sbom-${serviceName}-${dockerImageTag}.cdx.json
                """
                archiveArtifacts artifacts: "sbom-${serviceName}-${dockerImageTag}.cdx.json",
                                 fingerprint: true,
                                 onlyIfSuccessful: true
            }
        }
    }

    post {
        // Clean after build
        always {
            cleanWs(cleanWhenNotBuilt: false,
                    deleteDirs: true,
                    disableDeferredWipeout: true,
                    notFailBuild: true,
                    patterns: [[pattern: '.gitignore', type: 'INCLUDE'],
                               [pattern: '.propsfile', type: 'EXCLUDE']])
        }
    }

}
