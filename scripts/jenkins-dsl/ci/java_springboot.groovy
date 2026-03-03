attributes = [job_name: "java-springboot", dockerfile: "Dockerfile", jenkinsfile_template: "java_springboot.Jenkinsfile", disabled: 'false']

pipelineJob("CI/${attributes['job_name']}") {
    disabled("${attributes['disabled']}".toBoolean())
    
    description("CI pipeline for ${attributes['job_name']} service")
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
            script(readFileFromWorkspace("scripts/jenkinsfiles/ci/${attributes['jenkinsfile_template']}"))
            sandbox()
        }
    }
}

