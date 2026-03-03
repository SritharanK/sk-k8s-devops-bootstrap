# Maintainer: Sritharan K <https://www.skengineer.be>
# Project: GitOps Kubernetes Platform Bootstrap
# License: MIT
FROM python:3.12.12

WORKDIR /opt

COPY requirements.txt /tmp/requirements.txt

RUN pip3 install --upgrade pip && pip install -r /tmp/requirements.txt

COPY . /opt/

ENV DB_ENGINE="django.db.backends.mysql"
ENV DB_PORT="3306"

RUN chmod +x /opt/run.sh

EXPOSE 8080

CMD [ "/bin/bash", "-c", "/opt/run.sh" ]