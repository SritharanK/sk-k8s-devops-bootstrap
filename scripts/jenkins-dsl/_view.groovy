listView("CICD") {
    description("CICD pipeline")
    jobs {
        name("CI")
        name('CD')
    }
    columns {
        status()
        weather()
        name()
        lastSuccess()
        lastFailure()
        lastDuration()
        buildButton()
    }    
}

folder('CI') {
    displayName('CI')
}

folder('CD') {
    displayName('CD')
}
