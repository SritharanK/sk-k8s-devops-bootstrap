# -----------------------------------------------------------------------------
# Project: GitOps Kubernetes Platform Bootstrap
# Author : Sritharan K (https://www.skengineer.be)
# License: MIT
# -----------------------------------------------------------------------------
def dockerRegistry = env.DOCKER_REGISTRY ?: "YOUR_DOCKER_REGISTRY"
def serviceName = "python-django"
def dockerRepo = "${dockerRegistry}/${serviceName}"
def serviceGitRepoUrl = env.SERVICE_GIT_REPO ?: "git@github.com:YOUR_ORG/python-django.git"
def opsGitRepoUrl = env.OPS_GIT_REPO ?: "git@github.com:YOUR_ORG/your-ops-repo.git"
def helmChartPath = "helmcharts/app-charts/${serviceName}"
def argocdServer = env.ARGOCD_SERVER ?: "YOUR_ARGOCD_SERVER"
def gitCredsId = "git-ssh-key"


pipeline {
    agent {
        label 'default'
    }
    options {
        ansiColor('xterm')
    }
    parameters {
        string(name: 'DEPLOY_ARTIFACT', defaultValue: '', description: 'Git SHA that has been built docker image for the application.')
        choice(name: 'ENVIRONMENT', choices: ['dev', 'test', 'prod'], description: 'Environment to build and deploy.')

    }

    stages {
        stage('Check required parameters') {
            steps {
                script {
                    sh """
                        echo "Checking parameter DEPLOY_ARTIFACT"
                        if [[ -z "${params.DEPLOY_ARTIFACT}" ]]; then
                            echo "Parameter DEPLOY_ARTIFACT must not be empty!!!"
                            exit 1
                        fi
                    """
                }
            }
        }

        stage('Checkout') {
            steps {
                sshagent (credentials: ['git-ssh-key']) {
                    git url: "${serviceGitRepoUrl}", branch: 'main', credentialsId: "${gitCredsId}"
                }
                script {
                    artifactImageTag = "git-${params.DEPLOY_ARTIFACT}"
                    dockerImageTag = "${params.ENVIRONMENT}-${params.DEPLOY_ARTIFACT}"
                }
            }
        }

        stage('Check docker image exists') {
            steps {
                script {
                    withCredentials([usernamePassword(credentialsId: 'dockerhub', passwordVariable: 'DOCKER_PASS', usernameVariable: 'DOCKER_USER')]) {
                        sh """
                            docker login -u ${DOCKER_USER} -p ${DOCKER_PASS}
                            if docker pull ${dockerRepo}:${artifactImageTag} > /dev/null 2>&1; then
                                echo "Docker image ${dockerRepo}:${artifactImageTag} exists in the remote registry."
                            else
                                echo "Docker image ${dockerRepo}:${artifactImageTag} does not exist in the remote registry."
                                exit 1
                            fi

                            docker tag ${dockerRepo}:${artifactImageTag} ${dockerRepo}:${dockerImageTag}
                            docker push ${dockerRepo}:${dockerImageTag}
                        """
                    }
                }
            }
        }


        stage('Update image version') {
            steps {
                script {
                    sshagent (credentials: ['git-ssh-key']) {
                        withCredentials([usernamePassword(credentialsId: 'jenkins_git_user', passwordVariable: 'GIT_PASS', usernameVariable: 'GIT_USER')]) {
                            git url: "${opsGitRepoUrl}", branch: 'main', credentialsId: "${gitCredsId}"

                            sh """
                                yq eval '.helm-common.image.name=\"${dockerRepo}:${dockerImageTag}\"' -i ${helmChartPath}/values-${params.ENVIRONMENT}.yaml
                                sed -i 's/HELM_USERNAME/${GIT_USER}/g; s/HELM_PASSWORD/${GIT_PASS}/g' ${helmChartPath}/Chart.yaml

                                git config user.name 'jenkins'
                                git config user.email 'jenkins@example.com'
                                git add -A
                                git commit -m "update image version of ${serviceName} to ${dockerImageTag}" || true
                                git push --set-upstream origin main || true
                            """
                        }
                    }
                }
            }
        }

        stage('Sync ArgoCD to deploy application') {
            steps {
                script {
                    argocdFastExecutor(argocdServer, serviceName)
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

def argocdFastExecutor (argocdServer, svc_name) {
    withCredentials([usernamePassword(credentialsId: 'argocd-creds', usernameVariable: 'argoUser', passwordVariable: 'argoPasswd')]) {
        sh """
            argocd login $argocdServer --insecure --username $argoUser --password $argoPasswd --grpc-web
            argocd app diff $svc_name --refresh || true
            argocd app sync $svc_name --prune --retry-limit 6 --retry-backoff-duration 10s --retry-backoff-factor 1 --retry-backoff-max-duration 5m || true
            argocd app wait $svc_name --sync --health --timeout 300
        """
    }
}