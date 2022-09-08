FROM epamedp/edp-jenkins-maven-java11-agent:2.0.0
ENV JAVA_HOME=/usr/lib/jvm/java-11-openjdk
ENV PYTHONUNBUFFERED=1
ENV VELERO_VERSION=1.6.0
ENV OPENSHIFT_BUILD_NAME=edp-jenkins-maven-java11-agent-dockerfile-release-2-0-2 OPENSHIFT_BUILD_NAMESPACE=oc-green-edp-cicd
USER root
RUN mkdir /home/jenkins/backup && mkdir /home/jenkins/restore
COPY ./scripts/restore_rclone.sh /home/jenkins/restore
COPY ./scripts/backup_rclone.sh /home/jenkins/backup
COPY pip3_test_requirements.txt /root/
RUN curl -L -o /etc/yum.repos.d/devel:kubic:libcontainers:stable.repo https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/CentOS_7/devel:kubic:libcontainers:stable.repo
RUN yum remove git -y && yum remove perl-Git -y
RUN yum install -y https://repo.ius.io/ius-release-el7.rpm \
                   https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
RUN yum install -y wget python3 skopeo jq openssl git
RUN yum clean all  \
    && rm -rf /var/cache/yum
RUN ln -s --force /usr/local/bin/helm /sbin/
RUN curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 \
    && chmod 700 get_helm.sh \
    && ./get_helm.sh \
    && curl --silent "https://api.github.com/repos/roboll/helmfile/releases/latest" | jq -r '.tag_name' \
    | xargs -I% curl -L -o /usr/local/bin/helmfile https://github.com/roboll/helmfile/releases/download/%/helmfile_linux_386 \
    && chmod +x /usr/local/bin/helmfile

# required for tests, but need to check if it is really needed
RUN pip3 install -r /root/pip3_test_requirements.txt

RUN curl https://rclone.org/install.sh | bash
RUN wget https://github.com/vmware-tanzu/velero/releases/download/v${VELERO_VERSION}/velero-v${VELERO_VERSION}-linux-amd64.tar.gz
RUN tar -xvf velero-v${VELERO_VERSION}-linux-amd64.tar.gz \
    && rm velero-v${VELERO_VERSION}-linux-amd64.tar.gz \
    && mv velero-v${VELERO_VERSION}-linux-amd64/velero /usr/local/bin/

