attributes = [job_name: "bootstrap", jenkinsfile_template: "/var/lib/jenkins/custom_data/job_seeder.Jenkinsfile", disabled: 'false']

pipelineJob("${attributes['job_name']}") {
    disabled("${attributes['disabled']}".toBoolean())
    
    description("Bootstrap Jenkins job")
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
            script(readFileFromWorkspace("${attributes['jenkinsfile_template']}"))
            sandbox()
        }
    }
}

