// Promotion pipeline of the Jenkins CI adapter (see ci/jenkins/README.md).
//
// Job: services/<name>/promote, created by ci/jenkins/jobs/services.groovy
// from ci/jenkins/services.yaml, started by hand with the parameter
// TARGET_ENV. The Job DSL defines TARGET_ENV from the environments list in
// services.yaml (every environment after the first). It is not declared
// again here: a parameters directive would replace those choices with a
// fixed list on the first run.
//
// Promotion is GitOps only. The pipeline copies .image.tag and .image.digest
// from the values file of the environment before TARGET_ENV into the values
// file of TARGET_ENV and opens a pull request. It never runs kubectl, helm
// or an Argo CD sync. Because the digest always comes from the previous
// environment in Git, prod cannot skip stage.
//
// Stages: resolve the service and the source environment, read the source
// tag and digest, verify the cosign signature and SBOM attestation of that
// digest, optionally check in Argo CD that the source environment runs it
// healthy and synced, then open the pull request.
//
// Conventions (keep them when editing this file):
// - Declarative syntax only: no methods at file level, no shared library.
// - Every value from services.yaml, from the values files and from the
//   global environment is validated before it reaches a shell step, then
//   exported as an environment variable. Shell steps are single-quoted
//   Groovy strings that read those variables, so Groovy never interpolates a
//   value into a command line.
// - Secrets come only from withCredentials, around the step that uses them.
//   Every shell step starts with "set +x" so that commands are not traced.
// - The steps of "Open change" are identical to the steps of "Open dev
//   change" in build.Jenkinsfile. Change both files together.

pipeline {
    agent {
        kubernetes {
            yamlFile 'ci/jenkins/pod-templates/promote.yaml'
            defaultContainer 'jnlp'
        }
    }

    options {
        timeout(time: 20, unit: 'MINUTES')
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '30'))
        timestamps()
        skipDefaultCheckout()
        skipStagesAfterUnstable()
    }

    stages {
        stage('Resolve') {
            steps {
                script {
                    checkout scm

                    // Fails the build unless value is a string matching pattern.
                    def requireMatch = { what, value, pattern ->
                        if (!(value instanceof String) || !value.matches(pattern)) {
                            error("Missing or invalid ${what}: expected a value matching ${pattern}")
                        }
                        return value
                    }
                    def requireNoParentRef = { what, value ->
                        if (value.contains('..')) {
                            error("Invalid ${what}: must not contain '..'")
                        }
                        return value
                    }
                    def namePattern = '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'

                    // The service comes from the job name, never from a parameter.
                    def jobName = requireMatch('job name (services/<name>/promote)', env.JOB_NAME,
                        '^services/[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?/promote$')
                    def serviceName = jobName.split('/')[1]

                    // Global environment, set by configuration as code.
                    def imageRegistry = requireMatch('IMAGE_REGISTRY', env.IMAGE_REGISTRY,
                        '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?(/[a-z0-9]+([._-][a-z0-9]+)*)*$')
                    requireNoParentRef('GITOPS_REPO_URL', requireMatch('GITOPS_REPO_URL', env.GITOPS_REPO_URL,
                        '^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._~-]+)+$'))
                    requireNoParentRef('GITOPS_BASE_BRANCH', requireMatch('GITOPS_BASE_BRANCH', env.GITOPS_BASE_BRANCH,
                        '^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$'))
                    requireMatch('GITHUB_API_URL', env.GITHUB_API_URL,
                        '^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._~-]+)*$')
                    requireMatch('GITHUB_REPOSITORY', env.GITHUB_REPOSITORY,
                        '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$')
                    requireMatch('GIT_COMMIT_NAME', env.GIT_COMMIT_NAME, '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$')
                    requireMatch('GIT_COMMIT_EMAIL', env.GIT_COMMIT_EMAIL,
                        '^[A-Za-z0-9._%+-]+@[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$')
                    requireMatch('COSIGN_TLOG_UPLOAD', env.COSIGN_TLOG_UPLOAD, '^(true|false)$')
                    // Optional keyless identity (GitHub OIDC) for images built and
                    // signed by the GitHub Actions reference workflow. Both empty
                    // means only signatures made with the Jenkins key are accepted.
                    def keylessIssuer = env.COSIGN_KEYLESS_ISSUER ?: ''
                    def keylessIdentity = env.COSIGN_KEYLESS_IDENTITY_REGEXP ?: ''
                    if ((keylessIssuer == '') != (keylessIdentity == '')) {
                        error('Set both COSIGN_KEYLESS_ISSUER and COSIGN_KEYLESS_IDENTITY_REGEXP, or neither')
                    }
                    if (keylessIssuer != '') {
                        requireMatch('COSIGN_KEYLESS_ISSUER', keylessIssuer,
                            '^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._~-]+)*$')
                        requireMatch('COSIGN_KEYLESS_IDENTITY_REGEXP', keylessIdentity, '^\\^[^\\n\\r]{1,510}\\$$')
                    }
                    def argocdServer = env.ARGOCD_SERVER ?: ''
                    if (argocdServer != '') {
                        requireMatch('ARGOCD_SERVER (host or host:port)', argocdServer,
                            '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$')
                    }

                    // Service entry, read from the checked-out commit of main.
                    def config = readYaml(file: 'ci/jenkins/services.yaml')
                    if (!(config instanceof Map)) {
                        error('ci/jenkins/services.yaml: the top level must be a mapping')
                    }
                    def environments = config.get('environments')
                    if (!(environments instanceof List) || environments.size() < 2) {
                        error('ci/jenkins/services.yaml: environments must list at least two environments')
                    }
                    for (int i = 0; i < environments.size(); i++) {
                        requireMatch('environments entry ' + i, environments.get(i), namePattern)
                        if (environments.indexOf(environments.get(i)) != i) {
                            error('ci/jenkins/services.yaml: environment ' + environments.get(i) + ' is listed twice')
                        }
                    }
                    def services = config.get('services')
                    if (!(services instanceof List)) {
                        error('ci/jenkins/services.yaml: services must be a list')
                    }
                    def service = null
                    for (int i = 0; i < services.size(); i++) {
                        def entry = services.get(i)
                        if (entry instanceof Map && entry.get('name') == serviceName) {
                            if (service != null) {
                                error("ci/jenkins/services.yaml: service ${serviceName} is listed twice")
                            }
                            service = entry
                        }
                    }
                    if (service == null) {
                        error("Service ${serviceName} is not listed in ci/jenkins/services.yaml")
                    }
                    def image = requireMatch('image', service.get('image'),
                        '^[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*$')

                    // Target from the parameter, source is the environment before it.
                    def targetEnv = requireMatch('TARGET_ENV', params.TARGET_ENV, namePattern)
                    def targetIndex = environments.indexOf(targetEnv)
                    if (targetIndex < 0) {
                        error("TARGET_ENV ${targetEnv} is not listed in environments of ci/jenkins/services.yaml")
                    }
                    if (targetIndex == 0) {
                        error("TARGET_ENV ${targetEnv} is the first environment: the build job opens its changes, " +
                            'promotion starts at the second environment')
                    }
                    def sourceEnv = environments.get(targetIndex - 1)

                    def valuesTemplate = requireMatch('valuesFile', config.get('valuesFile'), '^[A-Za-z0-9._/{}-]+[.]ya?ml$')
                    if (!valuesTemplate.contains('{env}') || !valuesTemplate.contains('{service}')) {
                        error('ci/jenkins/services.yaml: valuesFile must contain {env} and {service}')
                    }
                    def valuesPattern = '^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*[.]ya?ml$'
                    def sourceValuesFile = requireNoParentRef('source values file', requireMatch('source values file',
                        valuesTemplate.replace('{env}', sourceEnv).replace('{service}', serviceName), valuesPattern))
                    def targetValuesFile = requireNoParentRef('target values file', requireMatch('target values file',
                        valuesTemplate.replace('{env}', targetEnv).replace('{service}', serviceName), valuesPattern))

                    // The health gate checks the application of the source environment.
                    def appTemplate = requireMatch('argocdApplication', config.get('argocdApplication'), '^[a-z0-9.{}-]+$')
                    def argocdApp = requireMatch('Argo CD application name',
                        appTemplate.replace('{env}', sourceEnv).replace('{service}', serviceName),
                        '^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$')

                    env.SERVICE_NAME = serviceName
                    env.IMAGE = imageRegistry + '/' + image
                    env.REGISTRY_HOST = imageRegistry.split('/')[0]
                    env.SOURCE_ENV = sourceEnv
                    env.SOURCE_VALUES_FILE = sourceValuesFile
                    env.PROMOTE_ENV = targetEnv
                    env.PROMOTE_VALUES_FILE = targetValuesFile
                    env.PROMOTE_SOURCE = 'environment ' + sourceEnv + ' (' + sourceValuesFile + ')'
                    env.ARGOCD_SERVER = argocdServer
                    env.ARGOCD_APP = argocdApp

                    echo("Promote ${serviceName} from ${sourceEnv} (${sourceValuesFile}) " +
                        "to ${targetEnv} (${targetValuesFile}), image ${env.IMAGE}")
                }
            }
        }

        stage('Read source') {
            steps {
                script {
                    def sourceTag = ''
                    def sourceDigest = ''
                    container('yq') {
                        sourceTag = sh(returnStdout: true, script: '''
                            set +x
                            set -eu
                            if [ ! -f "$SOURCE_VALUES_FILE" ]; then
                                echo "$SOURCE_VALUES_FILE does not exist" >&2
                                exit 1
                            fi
                            yq '.image.tag // ""' "$SOURCE_VALUES_FILE"
                        ''').trim()
                        sourceDigest = sh(returnStdout: true, script: '''
                            set +x
                            set -eu
                            yq '.image.digest // ""' "$SOURCE_VALUES_FILE"
                        ''').trim()
                    }
                    if (sourceDigest == '') {
                        error("Nothing to promote: ${env.SOURCE_VALUES_FILE} has no .image.digest, " +
                            "so ${env.SOURCE_ENV} has no promotable image yet")
                    }
                    if (!sourceDigest.matches('^sha256:[0-9a-f]{64}$')) {
                        error("${env.SOURCE_VALUES_FILE}: .image.digest is not a sha256 digest")
                    }
                    // OCI tag grammar: images may come from this adapter
                    // (sha-<12 hex>) or from the GitHub Actions reference build.
                    if (!sourceTag.matches('^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$')) {
                        error("${env.SOURCE_VALUES_FILE}: .image.tag is missing or not a valid OCI tag")
                    }
                    env.PROMOTE_TAG = sourceTag
                    env.PROMOTE_DIGEST = sourceDigest
                    echo("Source ${env.SOURCE_ENV}: ${env.IMAGE}:${sourceTag}@${sourceDigest}")
                }
            }
        }

        stage('Verify signature') {
            steps {
                container(name: 'cosign', shell: '/busybox/sh') {
                    withCredentials([
                        usernamePassword(credentialsId: 'registry-push',
                            usernameVariable: 'REGISTRY_USERNAME', passwordVariable: 'REGISTRY_PASSWORD'),
                        file(credentialsId: 'cosign-key', variable: 'COSIGN_KEY'),
                        string(credentialsId: 'cosign-password', variable: 'COSIGN_PASSWORD')
                    ]) {
                        // First the Jenkins key: the public key is derived from the
                        // signing key held in Jenkins, and both the signature and the
                        // SBOM attestation must verify. Without the transparency log
                        // there is no Rekor entry to check, hence
                        // --insecure-ignore-tlog. If that fails and a keyless
                        // identity is configured, the signature of the
                        // GitHub Actions reference workflow is accepted instead,
                        // checked against the public Sigstore instance. Anything else
                        // fails here.
                        sh '''
                            set +x
                            set -eu
                            printf '%s' "$REGISTRY_PASSWORD" | cosign login "$REGISTRY_HOST" --username "$REGISTRY_USERNAME" --password-stdin
                            cosign public-key --key "$COSIGN_KEY" --outfile cosign.pub
                            set --
                            if [ "$COSIGN_TLOG_UPLOAD" != "true" ]; then
                                set -- --insecure-ignore-tlog=true
                            fi
                            if cosign verify --key cosign.pub "$@" "$IMAGE@$PROMOTE_DIGEST" > cosign-verify.json 2> cosign-verify-key.err; then
                                cosign verify-attestation --key cosign.pub --type cyclonedx "$@" "$IMAGE@$PROMOTE_DIGEST" > cosign-verify-attestation.json
                                echo "Signature and SBOM attestation of $IMAGE@$PROMOTE_DIGEST verified with the Jenkins key"
                            elif [ -n "${COSIGN_KEYLESS_ISSUER:-}" ] && [ -n "${COSIGN_KEYLESS_IDENTITY_REGEXP:-}" ]; then
                                cosign verify \
                                    --certificate-oidc-issuer "$COSIGN_KEYLESS_ISSUER" \
                                    --certificate-identity-regexp "$COSIGN_KEYLESS_IDENTITY_REGEXP" \
                                    "$IMAGE@$PROMOTE_DIGEST" > cosign-verify.json
                                echo "Keyless signature of $IMAGE@$PROMOTE_DIGEST verified for issuer $COSIGN_KEYLESS_ISSUER"
                            else
                                cat cosign-verify-key.err >&2
                                echo "$IMAGE@$PROMOTE_DIGEST has no valid signature from the Jenkins key and no keyless identity is configured" >&2
                                exit 1
                            fi
                        '''
                    }
                }
            }
        }

        stage('Health gate') {
            when {
                expression { return env.ARGOCD_SERVER != null && env.ARGOCD_SERVER != '' }
            }
            steps {
                // Read-only Argo CD token, sent from a header file so that it
                // never appears on a command line. TLS verification stays on.
                // One read-only token per source environment: the Argo CD project
                // role ci of apps-<env> can read only that project's Applications.
                withCredentials([string(credentialsId: 'argocd-token-' + env.SOURCE_ENV, variable: 'ARGOCD_TOKEN')]) {
                    sh '''
                        set +x
                        set -eu
                        umask 077
                        header_file=$(mktemp)
                        trap 'rm -f "$header_file"' EXIT
                        printf 'Authorization: Bearer %s\\n' "$ARGOCD_TOKEN" > "$header_file"
                        status=0
                        curl --silent --show-error --fail-with-body --proto '=https' --tlsv1.2 \
                            --connect-timeout 10 --max-time 60 \
                            --header @"$header_file" --header 'Accept: application/json' \
                            --output argocd-app.json \
                            "https://$ARGOCD_SERVER/api/v1/applications/$ARGOCD_APP" || status=$?
                        if [ "$status" -ne 0 ]; then
                            echo "Reading Argo CD application $ARGOCD_APP failed (curl exit code $status)" >&2
                            if [ -f argocd-app.json ]; then
                                cat argocd-app.json >&2
                            fi
                            exit 1
                        fi
                    '''
                }
                container('yq') {
                    sh '''
                        set +x
                        set -eu
                        health=$(yq -p json -o yaml '.status.health.status // ""' argocd-app.json)
                        sync=$(yq -p json -o yaml '.status.sync.status // ""' argocd-app.json)
                        echo "Argo CD application $ARGOCD_APP: health ${health:-unknown}, sync ${sync:-unknown}"
                        if [ "$health" != Healthy ] || [ "$sync" != Synced ]; then
                            echo "$ARGOCD_APP must be Healthy and Synced before $SOURCE_ENV is promoted" >&2
                            exit 1
                        fi
                        if ! yq -p json -o yaml '(.status.summary.images // [])[]' argocd-app.json | grep -F -q -e "@$PROMOTE_DIGEST"; then
                            echo "$ARGOCD_APP does not run $PROMOTE_DIGEST; promote only what $SOURCE_ENV runs" >&2
                            exit 1
                        fi
                        echo "$ARGOCD_APP is healthy, synced and runs $PROMOTE_DIGEST"
                    '''
                }
            }
        }

        stage('Open change') {
            steps {
                script {
                    env.PROMOTE_BRANCH = 'promote/' + env.SERVICE_NAME + '/' + env.PROMOTE_ENV + '/' +
                        env.PROMOTE_DIGEST.substring(7, 19)
                }
                // Open change, step 1 of 3 (jnlp): branch from the base branch.
                // Git reads the token through the credential helper from the
                // GITHUB_TOKEN variable, so the token never appears in a URL,
                // in the Git configuration or on a command line.
                withCredentials([string(credentialsId: 'github-token', variable: 'GITHUB_TOKEN')]) {
                    sh '''
                        set +x
                        set -eu
                        export GIT_TERMINAL_PROMPT=0
                        # shellcheck disable=SC2016 # expanded by the helper, not here
                        helper='!f() { if [ "$1" = get ]; then echo username=x-access-token; echo "password=$GITHUB_TOKEN"; fi; }; f'
                        git -c init.defaultBranch=promote init -q gitops
                        git -C gitops -c credential.helper= -c "credential.helper=$helper" \
                            fetch -q --depth 1 --no-tags "$GITOPS_REPO_URL" "refs/heads/$GITOPS_BASE_BRANCH"
                        git -C gitops checkout -q -b "$PROMOTE_BRANCH" FETCH_HEAD
                        echo "Branch $PROMOTE_BRANCH created from $GITOPS_BASE_BRANCH"
                    '''
                }
                // Open change, step 2 of 3 (yq): set the tag and digest, write
                // the pull request body.
                container('yq') {
                    sh '''
                        set +x
                        set -eu
                        values="gitops/$PROMOTE_VALUES_FILE"
                        if [ ! -f "$values" ]; then
                            echo "$PROMOTE_VALUES_FILE does not exist on $GITOPS_BASE_BRANCH. Add it before promoting $SERVICE_NAME to $PROMOTE_ENV." >&2
                            exit 1
                        fi
                        current_tag=$(yq '.image.tag // ""' "$values")
                        current_digest=$(yq '.image.digest // ""' "$values")
                        if [ "$current_tag" = "$PROMOTE_TAG" ] && [ "$current_digest" = "$PROMOTE_DIGEST" ]; then
                            echo "$PROMOTE_VALUES_FILE already sets $PROMOTE_TAG and $PROMOTE_DIGEST"
                        else
                            yq -i '.image.tag = strenv(PROMOTE_TAG) | .image.digest = strenv(PROMOTE_DIGEST)' "$values"
                            echo "$PROMOTE_VALUES_FILE: tag ${current_tag:-unset} -> $PROMOTE_TAG, digest ${current_digest:-unset} -> $PROMOTE_DIGEST"
                        fi
                        PR_TITLE="Promote $SERVICE_NAME to $PROMOTE_ENV: $PROMOTE_TAG"
                        PR_BODY=$(printf 'Sets .image.tag and .image.digest in %s.\\n\\n- Service: %s\\n- Environment: %s\\n- Tag: %s\\n- Digest: %s\\n- Source: %s\\n- Jenkins build: %s\\n' \
                            "$PROMOTE_VALUES_FILE" "$SERVICE_NAME" "$PROMOTE_ENV" "$PROMOTE_TAG" "$PROMOTE_DIGEST" "$PROMOTE_SOURCE" "${BUILD_URL:-unknown}")
                        export PR_TITLE PR_BODY
                        yq -n -o=json '.title = strenv(PR_TITLE) | .head = strenv(PROMOTE_BRANCH) | .base = strenv(GITOPS_BASE_BRANCH) | .body = strenv(PR_BODY)' > promote-pr.json
                    '''
                }
                // Open change, step 3 of 3 (jnlp): commit, push, open the pull
                // request. No change means success without a pull request.
                withCredentials([string(credentialsId: 'github-token', variable: 'GITHUB_TOKEN')]) {
                    sh '''
                        set +x
                        set -eu
                        if git -C gitops diff --quiet -- "$PROMOTE_VALUES_FILE"; then
                            echo "Nothing to change for $SERVICE_NAME in $PROMOTE_ENV: no commit, no pull request."
                            exit 0
                        fi
                        export GIT_TERMINAL_PROMPT=0
                        # shellcheck disable=SC2016 # expanded by the helper, not here
                        helper='!f() { if [ "$1" = get ]; then echo username=x-access-token; echo "password=$GITHUB_TOKEN"; fi; }; f'
                        git -C gitops add -- "$PROMOTE_VALUES_FILE"
                        git -C gitops -c "user.name=$GIT_COMMIT_NAME" -c "user.email=$GIT_COMMIT_EMAIL" commit -q \
                            -m "promote($SERVICE_NAME): $PROMOTE_ENV to $PROMOTE_TAG" \
                            -m "Digest: $PROMOTE_DIGEST" -m "Source: $PROMOTE_SOURCE"
                        if git -C gitops -c credential.helper= -c "credential.helper=$helper" \
                            ls-remote --exit-code --heads "$GITOPS_REPO_URL" "refs/heads/$PROMOTE_BRANCH" > /dev/null; then
                            echo "Branch $PROMOTE_BRANCH already exists on the remote and is reused as it is"
                        else
                            git -C gitops -c credential.helper= -c "credential.helper=$helper" \
                                push -q "$GITOPS_REPO_URL" "HEAD:refs/heads/$PROMOTE_BRANCH"
                            echo "Pushed $PROMOTE_BRANCH"
                        fi
                        umask 077
                        header_file=$(mktemp)
                        trap 'rm -f "$header_file"' EXIT
                        printf 'Authorization: Bearer %s\\n' "$GITHUB_TOKEN" > "$header_file"
                        set +e
                        http_status=$(curl --silent --show-error --fail-with-body --proto '=https' --tlsv1.2 \
                            --connect-timeout 10 --max-time 60 --request POST \
                            --header @"$header_file" \
                            --header 'Accept: application/vnd.github+json' \
                            --header 'X-GitHub-Api-Version: 2022-11-28' \
                            --header 'Content-Type: application/json' \
                            --data-binary @promote-pr.json \
                            --output promote-pr-response.json --write-out '%{http_code}' \
                            "$GITHUB_API_URL/repos/$GITHUB_REPOSITORY/pulls")
                        curl_status=$?
                        set -e
                        if [ "$curl_status" -eq 0 ]; then
                            echo "Opened a pull request for $PROMOTE_BRANCH:"
                            grep -o '"html_url": *"[^"]*/pull/[0-9]*"' promote-pr-response.json | head -n 1 || true
                        elif [ "$http_status" = 422 ] && grep -q 'already exists' promote-pr-response.json; then
                            echo "A pull request for $PROMOTE_BRANCH is already open"
                        else
                            echo "Opening the pull request failed (HTTP $http_status, curl exit code $curl_status):" >&2
                            if [ -f promote-pr-response.json ]; then
                                cat promote-pr-response.json >&2
                            fi
                            exit 1
                        fi
                    '''
                }
            }
        }
    }

    post {
        cleanup {
            cleanWs()
        }
    }
}
