# Maintainer: Sritharan K <https://www.skengineer.be>
# Project: GitOps Kubernetes Platform Bootstrap
# License: MIT
# Maven build container

FROM maven:3.9.9-eclipse-temurin-21 AS maven_build

COPY pom.xml /tmp/

COPY src /tmp/src/

WORKDIR /tmp/

RUN mvn package

#pull base image

FROM eclipse-temurin:21.0.5_17-jre

EXPOSE 8080

#default command
CMD java -jar /data/hello-world-0.1.0.jar

#copy hello world to docker image from builder image

COPY --from=maven_build /tmp/target/hello-world-0.1.0.jar /data/hello-world-0.1.0.jar
