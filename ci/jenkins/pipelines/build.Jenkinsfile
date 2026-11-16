// Build pipeline of the Jenkins CI adapter (see ci/jenkins/README.md).
//
// Job: services/<name>/build, created by ci/jenkins/jobs/services.groovy
// from ci/jenkins/services.yaml. It builds the main branch only and runs as
// the build identity configured in the install_jenkins role.
//
// Stages: resolve the service from the job name and services.yaml, run the
// Dockerfile test stage, build an OCI image layout with rootless BuildKit,
// scan it with Trivy, push it with skopeo, sign it and attach the SBOM with
// cosign, then open a pull request that sets the new tag and digest in the
// values file of the first environment. Nothing is deployed from here.
//
// Conventions (keep them when editing this file):
// - Declarative syntax only: no methods at file level, no shared library.
// - Every value from services.yaml and from the global environment is
//   validated in Resolve before it reaches a shell step, then exported as an
//   environment variable. Shell steps are single-quoted Groovy strings that
//   read those variables, so Groovy never interpolates a value into a
//   command line.
// - Secrets come only from withCredentials, around the step that uses them.
//   Every shell step starts with "set +x" so that commands are not traced.
// - The steps of "Open dev change" are identical to the steps of "Open
//   change" in promote.Jenkinsfile. Change both files together.

pipeline {
    agent {
        kubernetes {
            yamlFile 'ci/jenkins/pod-templates/build.yaml'
            defaultContainer 'jnlp'
        }
    }

    options {
        timeout(time: 60, unit: 'MINUTES')
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
                    def scmVars = checkout scm

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
                    def jobName = requireMatch('job name (services/<name>/build)', env.JOB_NAME,
                        '^services/[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?/build$')
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

                    def commit = requireMatch('commit of the checkout', scmVars.GIT_COMMIT,
                        '^[0-9a-f]{40}([0-9a-f]{24})?$')

                    // Service entry, read from the commit being built.
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

                    def servicePath = requireNoParentRef('path', requireMatch('path', service.get('path'),
                        '^sample-services/[a-z0-9][a-z0-9._-]{0,62}$'))
                    def dockerfile = requireNoParentRef('dockerfile', requireMatch('dockerfile', service.get('dockerfile'),
                        '^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$'))
                    def image = requireMatch('image', service.get('image'),
                        '^[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*$')
                    def testTarget = requireMatch('testTarget', service.get('testTarget'), '^[a-z][a-z0-9._-]{0,62}$')
                    def platform = requireMatch('platform', service.get('platform'),
                        '^linux/(amd64|arm64|arm/v7|arm/v6|386|ppc64le|s390x|riscv64)$')

                    def valuesTemplate = requireMatch('valuesFile', config.get('valuesFile'), '^[A-Za-z0-9._/{}-]+[.]ya?ml$')
                    if (!valuesTemplate.contains('{env}') || !valuesTemplate.contains('{service}')) {
                        error('ci/jenkins/services.yaml: valuesFile must contain {env} and {service}')
                    }
                    def firstEnv = environments.get(0)
                    def valuesFile = requireNoParentRef('values file', requireMatch('values file',
                        valuesTemplate.replace('{env}', firstEnv).replace('{service}', serviceName),
                        '^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*[.]ya?ml$'))

                    env.SERVICE_NAME = serviceName
                    env.SERVICE_PATH = servicePath
                    env.SERVICE_DOCKERFILE = dockerfile
                    env.TEST_TARGET = testTarget
                    env.BUILD_PLATFORM = platform
                    env.GIT_COMMIT = commit
                    env.TAG = 'sha-' + commit.substring(0, 12)
                    env.IMAGE = imageRegistry + '/' + image
                    env.REGISTRY_HOST = imageRegistry.split('/')[0]
                    env.PROMOTE_ENV = firstEnv
                    env.PROMOTE_VALUES_FILE = valuesFile
                    env.PROMOTE_SOURCE = 'build of commit ' + commit

                    // Commit time, for reproducible timestamps in the image.
                    def commitTime = sh(returnStdout: true, script: '''
                        set +x
                        git log -1 --format=%ct "$GIT_COMMIT"
                    ''').trim()
                    env.SOURCE_DATE_EPOCH = requireMatch('commit time', commitTime, '^[0-9]{1,12}$')

                    echo("Service ${serviceName}: ${servicePath}/${dockerfile} for ${platform}, " +
                        "image ${env.IMAGE}:${env.TAG}, first environment ${firstEnv} (${valuesFile})")
                }
            }
        }

        stage('Test') {
            steps {
                container('buildkit') {
                    // Builds the Dockerfile test stage. Without --output the
                    // result stays in the BuildKit cache, which the Build stage
                    // reuses; buildctl has no "cacheonly" exporter (that is a
                    // buildx option). The build arguments match the Build stage
                    // so that shared layers hit the cache.
                    sh '''
                        set +x
                        set -eu
                        echo "Running Dockerfile target $TEST_TARGET of $SERVICE_PATH for $BUILD_PLATFORM"
                        buildctl-daemonless.sh build \
                            --frontend dockerfile.v0 \
                            --local "context=$SERVICE_PATH" \
                            --local "dockerfile=$SERVICE_PATH" \
                            --opt "filename=$SERVICE_DOCKERFILE" \
                            --opt "target=$TEST_TARGET" \
                            --opt "platform=$BUILD_PLATFORM" \
                            --opt "build-arg:SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH" \
                            --opt "build-arg:VERSION=$TAG" \
                            --opt "build-arg:REVISION=$GIT_COMMIT"
                    '''
                }
            }
        }

        stage('Build') {
            steps {
                container('buildkit') {
                    // Writes the image as an OCI layout directory (image/),
                    // which Trivy scans and skopeo pushes unchanged. Trivy
                    // cannot read an OCI tar archive. The Dockerfile sets the
                    // OCI labels from the VERSION and REVISION build arguments.
                    sh '''
                        set +x
                        set -eu
                        echo "Building $IMAGE:$TAG"
                        buildctl-daemonless.sh build \
                            --frontend dockerfile.v0 \
                            --local "context=$SERVICE_PATH" \
                            --local "dockerfile=$SERVICE_PATH" \
                            --opt "filename=$SERVICE_DOCKERFILE" \
                            --opt "platform=$BUILD_PLATFORM" \
                            --opt "build-arg:SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH" \
                            --opt "build-arg:VERSION=$TAG" \
                            --opt "build-arg:REVISION=$GIT_COMMIT" \
                            --output "type=oci,dest=image,tar=false,name=$IMAGE:$TAG"
                    '''
                }
            }
        }

        stage('Scan') {
            steps {
                container('trivy') {
                    // Gate first: fixable CRITICAL or HIGH vulnerabilities and
                    // secrets fail the build before anything is pushed. The
                    // SBOM is generated afterwards from the same directory and
                    // reuses the vulnerability database the gate downloaded.
                    sh '''
                        set +x
                        set -eu
                        status=0
                        trivy image --input image --no-progress --timeout 15m \
                            --exit-code 1 --severity CRITICAL,HIGH --ignore-unfixed --scanners vuln,secret \
                            --format table --output trivy-report.txt || status=$?
                        if [ -f trivy-report.txt ]; then
                            cat trivy-report.txt
                        fi
                        if [ "$status" -ne 0 ]; then
                            echo "Trivy found fixable CRITICAL or HIGH vulnerabilities or secrets, or could not scan. Nothing was pushed." >&2
                            exit "$status"
                        fi
                        trivy image --input image --no-progress --skip-db-update --format cyclonedx --output sbom.cdx.json
                    '''
                }
            }
        }

        stage('Push') {
            steps {
                container('skopeo') {
                    withCredentials([usernamePassword(credentialsId: 'registry-push',
                        usernameVariable: 'REGISTRY_USERNAME', passwordVariable: 'REGISTRY_PASSWORD')]) {
                        // REGISTRY_AUTH_FILE points to the memory-backed
                        // registry-auth volume, shared with cosign only.
                        sh '''
                            set +x
                            set -eu
                            printf '%s' "$REGISTRY_PASSWORD" | skopeo login --username "$REGISTRY_USERNAME" --password-stdin "$REGISTRY_HOST"
                            skopeo copy --retry-times 3 --preserve-digests --digestfile digest.txt \
                                oci:image "docker://$IMAGE:$TAG"
                        '''
                    }
                }
                script {
                    def digest = readFile(file: 'digest.txt').trim()
                    if (!digest.matches('^sha256:[0-9a-f]{64}$')) {
                        error('skopeo did not write a valid sha256 digest to digest.txt')
                    }
                    env.IMAGE_DIGEST = digest
                    echo "Pushed ${env.IMAGE}:${env.TAG} as ${env.IMAGE}@${digest}"
                }
            }
        }

        stage('Sign') {
            steps {
                container(name: 'cosign', shell: '/busybox/sh') {
                    withCredentials([
                        usernamePassword(credentialsId: 'registry-push',
                            usernameVariable: 'REGISTRY_USERNAME', passwordVariable: 'REGISTRY_PASSWORD'),
                        file(credentialsId: 'cosign-key', variable: 'COSIGN_KEY'),
                        string(credentialsId: 'cosign-password', variable: 'COSIGN_PASSWORD')
                    ]) {
                        // Signs the pushed digest and attaches the CycloneDX SBOM
                        // as an attestation, both stored next to the image as OCI
                        // referrers (Sigstore bundle format). Without the public
                        // transparency log, cosign v3 needs both flags below:
                        // --tlog-upload=false alone is rejected while the default
                        // signing configuration is in use.
                        sh '''
                            set +x
                            set -eu
                            printf '%s' "$REGISTRY_PASSWORD" | cosign login "$REGISTRY_HOST" --username "$REGISTRY_USERNAME" --password-stdin
                            set --
                            if [ "$COSIGN_TLOG_UPLOAD" != "true" ]; then
                                set -- --use-signing-config=false --tlog-upload=false
                            fi
                            cosign sign --yes --key "$COSIGN_KEY" "$@" "$IMAGE@$IMAGE_DIGEST"
                            cosign attest --yes --key "$COSIGN_KEY" --type cyclonedx --predicate sbom.cdx.json "$@" "$IMAGE@$IMAGE_DIGEST"
                            echo "Signed $IMAGE@$IMAGE_DIGEST and attached its SBOM (transparency log upload: $COSIGN_TLOG_UPLOAD)"
                        '''
                    }
                }
            }
        }

        stage('Open dev change') {
            steps {
                script {
                    env.PROMOTE_TAG = env.TAG
                    env.PROMOTE_DIGEST = env.IMAGE_DIGEST
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
        always {
            archiveArtifacts(artifacts: 'sbom.cdx.json,digest.txt,trivy-report.txt',
                allowEmptyArchive: true, fingerprint: true)
        }
        cleanup {
            cleanWs()
        }
    }
}
