attributes = [job_name: "python-django", dockerfile: "Dockerfile", jenkinsfile_template: "python_django.Jenkinsfile", disabled: 'false']

pipelineJob("CD/${attributes['job_name']}") {
    disabled("${attributes['disabled']}".toBoolean())
    
    description("CD pipeline for ${attributes['job_name']} service")
    keepDependencies(false)
    logRotator {
        artifactNumToKeep(2)
        numToKeep(10)
    }
    
    properties {
        disableConcurrentBuilds {
            abortPrevious(false)
        }
    }
    
    
    definition {
        cps {
            script(readFileFromWorkspace("scripts/jenkinsfiles/cd/${attributes['jenkinsfile_template']}"))
            sandbox()
        }
    }
}

