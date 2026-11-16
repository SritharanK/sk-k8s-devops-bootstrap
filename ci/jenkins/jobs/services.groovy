// Job DSL for the Jenkins CI adapter.
//
// Applied by configuration as code (jobs: section rendered by the
// install_jenkins role). It is never run by a seed job from the repository,
// so no repository Groovy executes on the controller at build time.
//
// Input: the variable `config`, a map set by the role from
// ci/jenkins/services.yaml and role variables:
//   services        list of maps: name, path, dockerfile, image, testTarget, platform
//   environments    promotion order, for example [dev, stage, prod]
//   repoUrl         repository with the code, the pipelines and envs/
//   branch          the only branch that is built (main)
//   credentialsId   credential for the checkout, empty for a public repository
//   pollSchedule    SCM polling schedule of the build jobs
//   runAs           user or system (Authorize Project)
//   buildUser       identity the jobs run as when runAs is user
//
// Output, per service: folder services/<name> with the Pipeline jobs build
// and promote, both from SCM and therefore always sandboxed.
//
// Configuration as code interpolates dollar-brace sequences in this text,
// so the script uses string concatenation only.

def namePattern = ~/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/
def pathPattern = ~/^sample-services\/[a-z0-9][a-z0-9._-]{0,62}$/

def requireMatch = { String what, Object value, java.util.regex.Pattern pattern ->
    if (!(value instanceof String) || !(value ==~ pattern)) {
        throw new IllegalArgumentException('services.yaml: invalid ' + what + ': ' + value)
    }
}

if (!(config.runAs in ['user', 'system'])) {
    throw new IllegalArgumentException('runAs must be user or system, got: ' + config.runAs)
}
if (!(config.environments instanceof List) || config.environments.size() < 2) {
    throw new IllegalArgumentException('services.yaml: environments needs at least two entries')
}
config.environments.each { env -> requireMatch('environment', env, namePattern) }

// Build identity. With runAs user, every generated job runs as the build
// user through Authorize Project instead of SYSTEM.
def buildIdentity = { context ->
    if (config.runAs == 'user') {
        context.authorizeProjectProperty {
            strategy {
                // Configuration as code applies this as SYSTEM, so no
                // password or API token of the build user is needed here.
                specificUsersAuthorizationStrategy {
                    userid(config.buildUser)
                    useApitoken(false)
                    apitoken('')
                    password('')
                }
            }
        }
    }
}

// Parameter names must differ from DSL method names (scriptPath, includedRegions),
// otherwise Groovy calls the local variable instead of the DSL method.
def scmDefinition = { context, String jenkinsfile, String regions ->
    context.cpsScm {
        scm {
            git {
                remote {
                    url(config.repoUrl)
                    if (config.credentialsId) {
                        credentials(config.credentialsId)
                    }
                }
                branch('refs/heads/' + config.branch)
                extensions {
                    if (regions) {
                        pathRestriction {
                            includedRegions(regions)
                            excludedRegions('')
                        }
                    }
                }
            }
        }
        scriptPath(jenkinsfile)
        lightweight(true)
    }
}

folder('services') {
    displayName('Services')
    description('Generated from ci/jenkins/services.yaml by configuration as code. Changes made in the UI are overwritten.')
}

def seen = [] as Set
config.services.each { service ->
    requireMatch('name', service.name, namePattern)
    requireMatch('path of ' + service.name, service.path, pathPattern)
    if (!seen.add(service.name)) {
        throw new IllegalArgumentException('services.yaml: duplicate service ' + service.name)
    }

    String base = 'services/' + service.name

    folder(base) {
        description('Build and promotion of ' + service.path + '.')
    }

    pipelineJob(base + '/build') {
        description('Builds, tests, scans, pushes and signs ' + service.name +
            ' from ' + config.branch + ', then opens the change for ' + config.environments[0] + '.')
        logRotator {
            numToKeep(30)
        }
        properties {
            disableConcurrentBuilds()
            pipelineTriggers {
                triggers {
                    pollSCM {
                        scmpoll_spec(config.pollSchedule)
                    }
                }
            }
            buildIdentity(delegate)
        }
        definition {
            scmDefinition(delegate, 'ci/jenkins/pipelines/build.Jenkinsfile',
                service.path + '/.*\nci/jenkins/.*')
        }
    }

    pipelineJob(base + '/promote') {
        description('Opens a pull request that promotes the digest of ' + service.name +
            ' from one environment to the next. It never deploys.')
        logRotator {
            numToKeep(30)
        }
        parameters {
            choiceParam('TARGET_ENV', config.environments.drop(1),
                'Environment to promote to. The digest comes from the environment before it.')
        }
        properties {
            disableConcurrentBuilds()
            buildIdentity(delegate)
        }
        definition {
            scmDefinition(delegate, 'ci/jenkins/pipelines/promote.Jenkinsfile', '')
        }
    }
}
