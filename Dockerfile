FROM epamedp/edp-jenkins-maven-java11-agent:2.0.0
ENV TZ=Europe/Kiev \
    GIT_VERSION=1.8.3.1-23.el7_8 \
    JAVA_HOME=/usr/lib/jvm/java-11-openjdk \
    JQ_VERSION=1.6-2.el7 \
    OPENSHIFT_BUILD_NAME=edp-jenkins-maven-java11-agent-dockerfile-release-2-0-2 \
    OPENSHIFT_BUILD_NAMESPACE=oc-green-edp-cicd \
    OPENSSL_VERSION=1.0.2k-25.el7_9 \
    PYTHON3_VERSION=3.6.8-18.el7 \
    PYTHONUNBUFFERED=1 \
    SKOPEO_VERSION=1.4.1-1.el7.3.1 \
    VELERO_VERSION=1.9.2

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER root

# add velero scripts for backup and restore
RUN mkdir /home/jenkins/backup && mkdir /home/jenkins/restore
COPY ./scripts/restore_rclone.sh /home/jenkins/restore
COPY ./scripts/backup_rclone.sh /home/jenkins/backup

COPY pip3_test_requirements.txt /root/
RUN curl -L -o /etc/yum.repos.d/devel:kubic:libcontainers:stable.repo https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/CentOS_7/devel:kubic:libcontainers:stable.repo
RUN yum remove git -y && yum remove perl-Git -y
RUN yum install -y https://repo.ius.io/ius-release-el7.rpm \
                   https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm

RUN yum install -y python3-${PYTHON3_VERSION} \
                   skopeo-${SKOPEO_VERSION} \
                   jq-${JQ_VERSION} \
                   openssl-${OPENSSL_VERSION} \
                   git-${GIT_VERSION}

RUN yum clean all  \
    && rm -rf /var/cache/yum

# install helm and helmfile
RUN ln -s --force /usr/local/bin/helm /sbin/
ADD https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 get_helm.sh
RUN chmod 700 get_helm.sh \
    && ./get_helm.sh \
    && curl --silent "https://api.github.com/repos/roboll/helmfile/releases/latest" | jq -r '.tag_name' \
    | xargs -I% curl -L -o /usr/local/bin/helmfile https://github.com/roboll/helmfile/releases/download/%/helmfile_linux_386 \
    && chmod +x /usr/local/bin/helmfile

# required for tests, but need to check if it is really needed
RUN pip3 install -r /root/pip3_test_requirements.txt

# install rclone
ADD https://rclone.org/install.sh install.sh
RUN bash install.sh

# install velero for backup and restore
ADD https://github.com/vmware-tanzu/velero/releases/download/v${VELERO_VERSION}/velero-v${VELERO_VERSION}-linux-amd64.tar.gz velero-v${VELERO_VERSION}-linux-amd64.tar.gz
RUN tar -xvf velero-v${VELERO_VERSION}-linux-amd64.tar.gz \
    && rm velero-v${VELERO_VERSION}-linux-amd64.tar.gz \
    && mv velero-v${VELERO_VERSION}-linux-amd64/velero /usr/local/bin/
