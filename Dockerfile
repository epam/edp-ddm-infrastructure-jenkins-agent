FROM epamedp/edp-jenkins-maven-java11-agent:2.0.0
ENV AWSCLI_VERSION=2.15.2 \
    GIT_VERSION=2.39.2-1.ep7.1 \
    JAVA_HOME=/usr/lib/jvm/java-11-openjdk \
    JQ_VERSION=1.6-2.el7 \
    OC_BINARY_VERSION=4.12.0-0.okd-2023-04-16-041331 \
    OPENSHIFT_BUILD_NAME=edp-jenkins-maven-java11-agent-dockerfile-release-2-0-2 \
    OPENSHIFT_BUILD_NAMESPACE=oc-green-edp-cicd \
    OPENSSL_VERSION=1.0.2k-25.el7_9 \
    PIGZ_VERSION=2.3.4-1.el7 \
    PYTHON3_VERSION=3.6.8-18.el7 \
    PYTHONUNBUFFERED=1 \
    SKOPEO_VERSION=1.4.1-1.el7.3.1 \
    TZ=Europe/Kiev \
    VELERO_VERSION=1.9.2

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
#hadolint ignore=DL3002
USER root

RUN rm -rf /etc/yum.repos.d/CentOS-Base.repo
COPY ./yum.repos.d/* /etc/yum.repos.d/
#hadolint ignore=SC2035
RUN yum-config-manager --disable * \
    && sed -i 's/enabled.*1/enabled=0/g' /etc/yum.repos.d/*.repo \
    && yum clean all
COPY pip3_test_requirements.txt /root/

RUN curl -L -o /etc/yum.repos.d/devel:kubic:libcontainers:stable.repo https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/CentOS_7/devel:kubic:libcontainers:stable.repo
RUN yum remove git -y && yum remove perl-Git -y
#hadolint ignore=DL3032
RUN yum install -y https://repo.ius.io/ius-release-el7.rpm \
                   https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm \
                   https://packages.endpointdev.com/rhel/7/os/x86_64/endpoint-repo.x86_64.rpm
#hadolint ignore=DL3032,DL3059,DL3033
RUN yum install -y python3 \
                   skopeo\
                   openssl \
                   git \
                   pigz
#hadolint ignore=DL3047,DL4001
RUN wget -O /usr/local/bin/jq https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 \
    && chmod +x /usr/local/bin/jq

RUN yum clean all  \
    && rm -rf /var/cache/yum

# install helm and helmfile
RUN ln -s --force /usr/local/bin/helm /sbin/
ADD https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 get_helm.sh
#hadolint ignore=DL4001
RUN chmod 700 get_helm.sh \
    && ./get_helm.sh \
    && curl --silent "https://api.github.com/repos/roboll/helmfile/releases/latest" | jq -r '.tag_name' \
    | xargs -I% curl -L -o /usr/local/bin/helmfile https://github.com/roboll/helmfile/releases/download/%/helmfile_linux_386 \
    && chmod +x /usr/local/bin/helmfile

# required for tests, but need to check if it is really needed
RUN pip3 install --no-cache-dir -r /root/pip3_test_requirements.txt

# install rclone
ADD https://rclone.org/install.sh install.sh
RUN bash install.sh

# install velero for backup and restore
ADD https://github.com/vmware-tanzu/velero/releases/download/v${VELERO_VERSION}/velero-v${VELERO_VERSION}-linux-amd64.tar.gz velero-v${VELERO_VERSION}-linux-amd64.tar.gz
RUN tar -xvf velero-v${VELERO_VERSION}-linux-amd64.tar.gz \
    && rm velero-v${VELERO_VERSION}-linux-amd64.tar.gz \
    && mv velero-v${VELERO_VERSION}-linux-amd64/velero /usr/local/bin/

# install oc and kubectl tools for OpenShift
ADD https://github.com/okd-project/okd/releases/download/${OC_BINARY_VERSION}/openshift-client-linux-${OC_BINARY_VERSION}.tar.gz openshift-client-linux-${OC_BINARY_VERSION}.tar.gz
RUN tar -xf openshift-client-linux-${OC_BINARY_VERSION}.tar.gz \
    && rm openshift-client-linux-${OC_BINARY_VERSION}.tar.gz \
    && mv oc /usr/bin/oc \
    && mv kubectl /usr/bin/kubectl

# install awscli
ADD https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWSCLI_VERSION}.zip awscliv2.zip
RUN unzip awscliv2.zip \
    && ./aws/install \
    && rm -rf aws*

# install certbot with route53 plugin
#hadolint ignore=DL3032,DL3033
RUN yum install -y epel-release \
    && yum install -y yum-utils \
    && yum-config-manager --enable epel \
    && yum install -y certbot python2-certbot-dns-route53 \
    && yum makecache -y \
    && yum install python2-futures -y \
    && yum downgrade python-s3transfer.noarch -y

EXPOSE 80
EXPOSE 443

# install kn-cli to work with KNative
ADD https://github.com/knative/client/releases/download/knative-v1.13.0/kn-linux-amd64 kn
RUN chmod +x kn && \
    mv kn /usr/bin/kn

# install func-cli to work with KNative functions
ADD https://github.com/knative/func/releases/download/knative-v1.12.1/func_linux_amd64 func
RUN chmod +x func && \
    cp func /usr/bin/func && \
    mv func /usr/bin/kn-func
