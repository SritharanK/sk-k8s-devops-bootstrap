# -----------------------------------------------------------------------------
# Project: GitOps Kubernetes Platform Bootstrap
# Author : Sritharan K (https://www.skengineer.be)
# License: MIT
# -----------------------------------------------------------------------------
def dockerRegistry = env.DOCKER_REGISTRY ?: "YOUR_DOCKER_REGISTRY/foggypay"
def dockerFile = "Dockerfile"
def serviceName = "foggypay"
def serviceGitRepoUrl = env.SERVICE_GIT_REPO ?: "git@github.com:YOUR_ORG/java-springboot.git"
def gitCredsId = "git-ssh-key"


pipeline {
    agent {
        label 'default'
    }
    options {
        ansiColor('xterm')
    }
    
    stages {
        stage('Checkout') {
            steps {
                sshagent (credentials: ['git-ssh-key']) {
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
                    withCredentials([usernamePassword(credentialsId: 'dockerhub', passwordVariable: 'DOCKER_PASS', usernameVariable: 'DOCKER_USER')]) {
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
                    withCredentials([usernamePassword(credentialsId: 'dockerhub', passwordVariable: 'DOCKER_PASS', usernameVariable: 'DOCKER_USER')]) {
                        sh """
                            docker login -u \${DOCKER_USER} -p \${DOCKER_PASS}
                            docker push ${dockerRegistry}:${dockerImageTag}
                        """
                    }
                }
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
