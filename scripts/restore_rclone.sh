#!/usr/bin/env bash

registry_name="$1"
edp_ns="$2"
backup_name="$3"

echo "Getting AWS_KEY for secret"
access_key_aws=$(oc get secret/backup-credentials -n ${edp_ns} -o jsonpath='{.data.backup-s3-like-storage-access-key-id}' | base64 -d )
echo "Getting AWS_SECRET_KEY for secret"
access_secret_key_aws=$(oc get secret/backup-credentials -n ${edp_ns} -o jsonpath='{.data.backup-s3-like-storage-secret-access-key}' | base64 -d )
echo "Getting Minio Endpoint"
minio_endpoint=$(oc get secret/backup-credentials -n ${edp_ns} -o jsonpath='{.data.backup-s3-like-storage-url}' | base64 -d)
echo "Getting Minio bucket name"
minio_bucket_name=$(oc get secret/backup-credentials -n ${edp_ns} -o jsonpath='{.data.backup-s3-like-storage-location}'| base64 -d)
echo "Getting Rook endpoint"
rook_s3_endpoint=$(oc get cephobjectstore/mdtuddm -n openshift-storage -o=jsonpath='{.status.info.endpoint}')
echo "Getting Velero backup"
velero_backup=$(oc get regbackup/${backup_name}  -o jsonpath=\'{.spec.velero-backup-name}\'| cut -c2- |rev | cut -c2- | rev)

mkdir -p ~/.config/rclone
echo "Restore Openshift objects from bucket"
echo "
[minio]
type = s3
env_auth = false
access_key_id = ${access_key_aws}
secret_access_key = ${access_secret_key_aws}
endpoint = ${minio_endpoint}
region = eu-central-1
location_constraint = EU
acl = bucket-owner-full-control"> ~/.config/rclone/rclone.conf
rm -rf /tmp/openshift-resources && mkdir /tmp/openshift-resources
rclone copy minio:${minio_bucket_name}/openshift-backups/backups/${velero_backup}/openshift-resources /tmp/openshift-resources
for object in $(ls /tmp/openshift-resources | grep -wv -e "jenkinsauthorizationrolemapping");
do
  oc apply -f /tmp/openshift-resources/$object
done
echo "Delete annotation from services"
for service in $(oc get service -n ${registry_name} --no-headers -o custom-columns=":metadata.name")
do
  oc -n "${registry_name}" annotate service "${service}" kubectl.kubernetes.io/last-applied-configuration-
done
echo "Start restoring all resources expect pods section"
time velero restore create --from-backup "${velero_backup}" --exclude-resources pods,replicasets,deployments,deploymentconfigs,statefulsets,horizontalpodautoscalers,deamonsets,objectbucketclaims,redisfailovers,kafkas,kafkaconnects --wait
sleep 20
echo "Delete rejecting routes"
for route in $(oc get routes -n ${registry_name} --no-headers -o custom-columns="NAME:.metadata.name")
do
  getRouteStatus=$(oc get routes $route -n ${registry_name} -o json | jq '.status.ingress[0].conditions[0].status' | tr -d '"')
  if [[ $getRouteStatus == "False" ]]; then
    echo "Delete rejecting route ${route}"
    oc delete routes $route -n ${registry_name}
  fi
done

echo "Start restoring vault pod"
time velero create restore --selector app.kubernetes.io/name=vault --from-backup "${velero_backup}" --include-resources pods --wait
echo "Start restoring vault statefulsets"
time velero create restore --selector app.kubernetes.io/name=vault --from-backup "${velero_backup}" --wait
timeCount=0
while [[ $(oc get pods -l app.kubernetes.io/name=vault -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' -n ${registry_name}) != "True" ]]; do
   echo "Waiting for Vault pod" && sleep 10;
   timeCount=$(( $timeCount + 10 ))
   if [[ timeCount -eq 60  ]]
   then
      oc delete pod -l app.kubernetes.io/name=vault -n ${registry_name}
   fi
done
echo "Start restoring nexus"
time velero create restore --selector app=nexus --from-backup  "${velero_backup}" --wait
timeCount=0
while [[ $(oc get pods -l app='nexus' -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' -n ${registry_name}) != "True" ]]; do
   echo "Waiting for Nexus pod" && sleep 10;
   timeCount=$(( $timeCount + 10 ))
   if [[ timeCount -eq 100  ]]
   then
      oc delete pod -l app='nexus' -n ${registry_name}
   fi
done
echo "End restoring nexus"
echo "Start restoring gerrit"
time velero create restore --selector app=gerrit --from-backup  "${velero_backup}" --exclude-resources services --wait
timeCount=0
while [[ $(oc get pods -l app='gerrit' -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' -n ${registry_name}) != "True" ]]; do
   echo "Waiting for Gerrit pod" && sleep 10;
   timeCount=$(( $timeCount + 10 ))
   if [[ timeCount -eq 100  ]]
   then
      oc delete pod -l app='gerrit' -n ${registry_name}
   fi
done
echo "End restoring gerrit"
echo "Start restoring jenkins"
time velero create restore --selector app=jenkins --from-backup  "${velero_backup}" --wait
oc adm policy add-role-to-user view system:serviceaccount:jenkins -n ${registry_name}
oc adm policy add-scc-to-user anyuid system:serviceaccount:jenkins -n ${registry_name}
oc adm policy add-scc-to-user privileged system:serviceaccount:jenkins -n ${registry_name}
timeCount=0
while [[ $(oc get pods -l app='jenkins' -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' -n ${registry_name}) != "True" ]]; do
    echo "Waiting for Jenkins pod" && sleep 10;
    timeCount=$(( $timeCount + 10 ))
    if [[ timeCount -eq 100  ]]
    then
       oc delete pod -l app='jenkins' -n ${registry_name}
    fi
done
echo "End restoring jenkins"

echo "Start restoring redis-sentinel"
# Restore all except RedisFailover CR to restore data on PVC via restic
time velero restore create --selector app.kubernetes.io/name=redis-sentinel --from-backup "${velero_backup}" --wait
sleep 10
# Restore RedisFailover CR to recreate pods with restored data on PVC
timeCount=0
time velero restore create --from-backup "${velero_backup}" --include-resources redisfailovers --wait
while [[ $(oc get statefulset rfr-redis-sentinel -o 'jsonpath={..status.replicas}' -n ${registry_name}) \
          != $(oc get statefulset rfr-redis-sentinel -o 'jsonpath={..status.readyReplicas}' -n ${registry_name}) ]]; do
  echo "Waiting for Redis pods are ready" && sleep 10;
  timeCount=$(( $timeCount + 10 ))
  if [[ timeCount -eq 600 ]]
  then
    oc delete pod -l app.kubernetes.io/name=redis-sentinel -l app.kubernetes.io/component=redis -n ${registry_name}
    echo "Restarting Redis pods"
  fi
done
echo "End restoring redis-sentinel"

echo "Start restoring citus-master"
time velero restore create --selector app=citus-master --from-backup "${velero_backup}" --wait
timeCount=0
while [[ $(oc get pods -l app='citus-master' -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' -n ${registry_name}) != "True" ]]; do
  echo "Waiting for Citus-Master pod" && sleep 10;
  timeCount=$(( $timeCount + 10 ))
  if [[ timeCount -eq 100  ]]
  then
     oc delete pod -l app='citus-master' -n ${registry_name}
  fi
done
echo "End restoring citus-master"
echo "Start restoring citus-master-rep"
#
time velero restore create --selector app=citus-master-rep --from-backup ${velero_backup} --wait
#
timeCount=0
while [[ $(oc get pods -l app='citus-master-rep' -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' -n ${registry_name}) != "True" ]]; do
  echo "Waiting for Citus-Master Replicas pod" && sleep 10;
  timeCount=$(( $timeCount + 10 ))
  if [[ timeCount -eq 60 ]]
  then
     oc delete pod -l app='citus-master' -n ${registry_name}
     while [[ $(oc get pods -l app='citus-master' -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' -n ${registry_name}) != "True" ]]; do
          echo "Waiting for Citus Master is ready after restart"  && sleep 5;
     done
     oc delete pod -l app='citus-master-rep' -n ${registry_name}
  fi
done
echo "Deleting citus-master pod."
oc delete pod -l app='citus-master' -n ${registry_name}
sleep 10;
timeCount=0;
while [[ $(oc get pods -l app='citus-master' -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' -n ${registry_name}) != "True" ]]; do
  echo "Waiting for Citus-Master pod" && sleep 5;
  timeCount=$(( $timeCount + 5 ))
  if [[ timeCount -eq 100  ]]
  then
     oc delete pod -l app='citus-master' -n ${registry_name}
  fi
done
echo "Deleting citus-master-rep pod"
oc delete pod -l app='citus-master-rep' -n ${registry_name}
sleep 10;
timeCount=0;
while [[ $(oc get pods -l app='citus-master-rep' -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' -n ${registry_name}) != "True" ]]; do
  echo "Waiting for Citus-Master-Replica pod" && sleep 5;
  timeCount=$(( $timeCount + 5 ))
  if [[ timeCount -eq 100  ]]
  then
     oc delete pod -l app='citus-master-rep' -n ${registry_name}
  fi
done
echo "End restoring citus-master-rep"
echo "Start restoring citus-workers"
time velero restore create --selector app=citus-workers --from-backup "${velero_backup}" --wait
sleep 10
for i in $(oc get pod -l app=citus-workers --no-headers -o custom-columns=":metadata.name" -n "${registry_name}");do
 timeCount=0;
 while [[ $(oc get pods $i -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' -n ${registry_name}) != "True" ]]; do
   echo "Waiting for ${i} pod" && sleep 10;
   timeCount=$(( $timeCount + 10 ))
   if [[ timeCount -eq 60 ]]
   then
      oc delete pod -l app='citus-master' -n ${registry_name}
      while [[ $(oc get pods -l app='citus-master' -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' -n ${registry_name}) != "True" ]]; do
           echo "Waiting for Citus Master is ready after restart"  && sleep 5;
      done
      oc delete pod $i -n ${registry_name}
   fi
 done
done
echo "End restoring citus-workers"
echo "Start restoring citus-workers-rep"
time velero restore create --selector app=citus-workers-rep --from-backup "${velero_backup}" --wait
sleep 10;
pod_name=$(oc get pod -l app=citus-workers-rep --no-headers -o custom-columns=":metadata.name" -n "${registry_name}")
for i in ${pod_name} ;do
 timeCount=0;
 while [[ $(oc get pods $i -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' -n ${registry_name}) != "True" ]]; do
   echo "Waiting for ${i} pod" && sleep 10;
   timeCount=$(( $timeCount + 10 ))
   if [[ timeCount -eq 60 ]]
   then
      oc delete pod -l app='citus-master-rep' -n ${registry_name}
      while [[ $(oc get pods -l app='citus-master-rep' -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' -n ${registry_name}) != "True" ]]; do
           echo "Waiting for Citus Master Replica is ready after restart"  && sleep 5;
      done
      oc delete pod $i -n ${registry_name}
   fi
 done
done
echo "End restoring citus-workers-rep"
echo "Start restoring form-management-modeler"
echo "Start restoring from-management-modeler-db pod"
time velero restore create --include-resources pods --selector app=form-management-modeler-db --from-backup "${velero_backup}" --wait
echo "Start restoring form-management-modeler application"
time velero restore create --selector app=form-management-modeler --from-backup "${velero_backup}" --wait
timeCount=0
while [[ $(oc get pods -l app='form-management-modeler' -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' -n ${registry_name}) != "True" ]]; do
  echo "Waiting for form-modeler-database pod" && sleep 5;
  while [[ $(oc get pods -l app='form-management-modeler-db' -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' -n ${registry_name}) != "True" ]]; do
     echo "Waiting for form-modeler-database pod" && sleep 10;
     timeCount=$(( $timeCount + 10 ))
     if [[ timeCount -eq 60  ]]
     then
        oc delete pod -l app='form-management-modeler-db' -n ${registry_name}
     fi
  done
done
echo "End restoring form-management-modeler"
echo "Start restoring form-management-provider"
echo "Start restoring database pod for form-management-provider database pod"
time velero restore create --include-resources pods --selector app=form-management-provider-db --from-backup "${velero_backup}" --wait
echo "Start restoring form-management-provider application."
time velero restore create --selector app=form-management-provider --from-backup "${velero_backup}" --wait
timeCount=0
while [[ $(oc get pods -l app='form-management-provider' -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' -n ${registry_name}) != "True" ]]; do
  echo "Waiting for form-management-provider pod" && sleep 5;
  while [[ $(oc get pods -l app='form-management-provider-db' -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' -n ${registry_name}) != "True" ]]; do
     echo "Waiting for form-management-provider-database pod" && sleep 10;
     timeCount=$(( $timeCount + 10 ))
     if [[ timeCount -eq 60  ]]
     then
        oc delete pod -l app='form-management-provider-db' -n ${registry_name}
     fi
  done
done
echo "End restoring form-management-provider"
echo "Start restoring Kafka cluster zookeeper"
time velero restore create --from-backup "${velero_backup}" --selector strimzi.io/name=kafka-cluster-zookeeper --include-resources pods --wait
sleep 10
time velero restore create --from-backup "${velero_backup}" --selector strimzi.io/name=kafka-cluster-zookeeper --wait
sleep 20
echo "Deleting pods for DNS resolving"
oc delete pods --selector strimzi.io/name=kafka-cluster-zookeeper -n ${registry_name}
pod_name=$(oc get pod -l strimzi.io/name=kafka-cluster-zookeeper --no-headers -o custom-columns=":metadata.name" -n "${registry_name}")
for i in ${pod_name} ;do
 timeCount=0;
 while [[ $(oc get pods $i -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' -n ${registry_name}) != "True" ]]; do
   echo "Waiting for ${i} pod" && sleep 10;
   timeCount=$(( $timeCount + 10 ))
   if [[ timeCount -eq 60 ]]
   then
      oc delete pod $i -n ${registry_name}
   fi
 done
done
echo "Start restoring Kafka pods"
time velero restore create --from-backup "${velero_backup}" --selector strimzi.io/name=kafka-cluster-kafka --include-resources pods --wait
sleep 10
time velero restore create --from-backup "${velero_backup}" --selector strimzi.io/name=kafka-cluster-kafka --wait
sleep 20
oc delete pods --selector strimzi.io/name=kafka-cluster-kafka -n ${registry_name}
pod_name=$(oc get pod -l strimzi.io/name=kafka-cluster-kafka --no-headers -o custom-columns=":metadata.name" -n "${registry_name}")
for i in ${pod_name} ;do
 timeCount=0;
 while [[ $(oc get pods $i -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' -n ${registry_name}) != "True" ]]; do
   echo "Waiting for ${i} pod" && sleep 10;
   timeCount=$(( $timeCount + 10 ))
   if [[ timeCount -eq 60 ]]
   then
      oc delete pod $i -n ${registry_name}
   fi
 done
done

echo "Start restoring Redash resources"
echo "Start restoring Redash  Postgresql Admin pod"
time  velero create restore --from-backup "${velero_backup}" --selector app=postgresql-admin --include-resources pods --wait
sleep 10
sleep "Restoring StatefulSet for redash postgresql admin pod"
time  velero create restore --from-backup "${velero_backup}" --selector app=postgresql-admin --wait
pod_name=$(oc get pod -l app=postgresql-admin --no-headers -o custom-columns=":metadata.name" -n "${registry_name}")
for i in ${pod_name} ;do
 timeCount=0;
 while [[ $(oc get pods $i -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' -n ${registry_name}) != "True" ]]; do
   echo "Waiting for ${i} pod" && sleep 10;
   timeCount=$(( $timeCount + 10 ))
   if [[ timeCount -eq 60 ]]
   then
      oc delete pod $i -n ${registry_name}
   fi
 done
done
oc get pod -l app=postgresql-admin -n ${registry_name}
sleep 30
echo "Start restoring Redash postgresql viewer pod"
time  velero create restore --from-backup "${velero_backup}" --selector app=postgresql-viewer --include-resources pods --wait
sleep "Restoring StatefulSet for redash postgresql viewer pods"
time  velero create restore --from-backup "${velero_backup}" --selector app=postgresql-viewer --wait
pod_name=$(oc get pod -l app=postgresql-viewer --no-headers -o custom-columns=":metadata.name" -n "${registry_name}")
for i in ${pod_name} ;do
 timeCount=0;
 while [[ $(oc get pods $i -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' -n ${registry_name}) != "True" ]]; do
   echo "Waiting for ${i} pod" && sleep 10;
   timeCount=$(( $timeCount + 10 ))
   if [[ timeCount -eq 60 ]]
   then
      oc delete pod $i -n ${registry_name}
   fi
 done
done
oc get pod -l app=postgresql-viewer -n ${registry_name}
sleep 30
echo "Start restoring Redash redis admin pod"
time  velero create restore --from-backup "${velero_backup}" --selector app=redis-admin --include-resources pods --wait
sleep 10
echo "Start restoring Redash redis viewer pod"
sleep 10
time  velero create restore --from-backup "${velero_backup}" --selector app=redis-viewer --include-resources pods --wait
sleep "Restoring StatefulSet for redash redis admin/viewer pods."
time  velero create restore --from-backup "${velero_backup}" --selector app=redis --wait
sleep 10
pod_name=$(oc get pod -l app=redis-admin --no-headers -o custom-columns=":metadata.name" -n "${registry_name}")
for i in ${pod_name} ;do
 timeCount=0;
 while [[ $(oc get pods $i -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' -n ${registry_name}) != "True" ]]; do
   echo "Waiting for ${i} pod" && sleep 10;
   timeCount=$(( $timeCount + 10 ))
   if [[ timeCount -eq 60 ]]
   then
      oc delete pod $i -n ${registry_name}
   fi
 done
done
pod_name=$(oc get pod -l app=redis-viewer --no-headers -o custom-columns=":metadata.name" -n "${registry_name}")
for i in ${pod_name} ;do
 timeCount=0;
 while [[ $(oc get pods $i -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' -n ${registry_name}) != "True" ]]; do
   echo "Waiting for ${i} pod" && sleep 10;
   timeCount=$(( $timeCount + 10 ))
   if [[ timeCount -eq 60 ]]
   then
      oc delete pod $i -n ${registry_name}
   fi
 done
done
echo "Start restoring redash admin pods"
time velero create restore --selector  app.kubernetes.io/instance=redash-admin --from-backup  "${velero_backup}" --wait
timeCount=0
pod_name=$(oc get pod -l app.kubernetes.io/instance=redash-admin --no-headers -o custom-columns=":metadata.name" -n "${registry_name}")
for i in ${pod_name} ;do
 timeCount=0;
   while [[ $(oc get pods $i -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' -n ${registry_name}) != "True" ]]; do
     echo "Waiting for $i pod " && sleep 10;
     timeCount=$(( $timeCount + 10 ))
     if [[ timeCount -eq 60  ]]
     then
        oc delete pod -l app=redis-admin -n ${registry_name}
        while [[ $(oc get pods -l app=redis-admin -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' -n ${registry_name}) != "True" ]]; do
          echo "Waiting for redis admin pod" && sleep 5
        done
        oc delete pod $i -n ${registry_name}
        sleep 10
        i=$(oc get pod -l app.kubernetes.io/instance=redash-admin --no-headers -o custom-columns=":metadata.name" -n "${registry_name}" | grep -ve "adhocworker" -ve "scheduled" )
     fi
   done
done
echo "Start restoring redash viewer pods"
time velero create restore --selector  app.kubernetes.io/instance=redash-viewer --from-backup  "${velero_backup}" --wait
pod_name=$(oc get pod -l app.kubernetes.io/instance=redash-viewer --no-headers -o custom-columns=":metadata.name" -n "${registry_name}")
for i in ${pod_name} ;do
   timeCount=0;
   while [[ $(oc get pods $i -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' -n ${registry_name}) != "True" ]]; do
     echo "Waiting for $i pod" && sleep 10;
     timeCount=$(( $timeCount + 10 ))
     if [[ timeCount -eq 60  ]]
     then
        oc delete pod -l app=redis-viewer -n ${registry_name}
        while [[ $(oc get pods -l app=redis-viewer -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' -n ${registry_name}) != "True" ]]; do
          echo "Waiting for redis viewer pod" && sleep 5
        done
        oc delete pod $i -n ${registry_name}
        sleep 10
        i=$(oc get pod -l app.kubernetes.io/instance=redash-viewer --no-headers -o custom-columns=":metadata.name" -n "${registry_name}" | grep -ve "adhocworker" -ve "scheduledworker" )
     fi
   done
done
echo "Start restoring all others resources"
time velero restore create --from-backup "${velero_backup}" --exclude-resources pods,routes,objectbucketclaimse --wait
echo "End restoring all others resources"
for obc_name in $(rclone lsf minio:${minio_bucket_name}/openshift-backups/backups/${backup_name}/obc-backup | tr -d '/');
do
  echo $obc_name
  acess_key_rook=$(oc get secret/"${obc_name}" -n "${registry_name}" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
  access_secret_key_rook=$(oc get secret/${obc_name} -n "${registry_name}" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)
  bucket_name=$(oc get objectbucketclaims/${obc_name} -n "${registry_name}" -o jsonpath='{.spec.bucketName}')
  mkdir -p ~/.config/rclone

  echo "
  [minio]
  type = s3
  env_auth = false
  access_key_id = ${access_key_aws}
  secret_access_key = ${access_secret_key_aws}
  endpoint = ${minio_endpoint}
  region = eu-central-1
  location_constraint = EU
  acl = bucket-owner-full-control
  [rook]
  type = s3
  v2_auth = true
  env_auth = false
  access_key_id = ${acess_key_rook}
  secret_access_key = ${access_secret_key_rook}
  endpoint = ${rook_s3_endpoint}
  acl = bucket-owner-full-control
  bucket_acl = authenticated-read" > ~/.config/rclone/rclone.conf

  echo "Restoring ObjectBucketClaim ${obc_name}"
  rclone  -v sync minio:${minio_bucket_name}/openshift-backups/backups/${backup_name}/obc-backup/${obc_name} rook:${bucket_name}
done
echo "Waiting all pods restorting"
sleep 200

echo "Restore JenkinsAuthorizationRoleMapping"
oc delete jenkinsauthorizationrolemapping -n ${registry_name} --all

for jauthrolemap in $(ls /tmp/openshift-resources | grep "jenkinsauthorizationrolemapping");
do
  oc apply -f /tmp/openshift-resources/$object
done

rm -rf /tmp/openshift-resources


docker run -it --rm \
    -e OC_CLI_LOGIN_COMMAND="oc login --token=sha256~dz8Kw--gsaxdwLW2KPegZV_KSEZnzehx8YtahQePzJc --server=https://api.1-9-3-7.mdtu-ddm.projects.epam.com:6443" \
    -e DEST_NEXUS_PASSWORD="FsJdbgzpWKrXgc3G" \
    -e SRC="nexus-docker-registry.apps.cicd2.mdtu-ddm.projects.epam.com/mdtu-ddm-edp-cicd/infrastructure-jenkins-agent-mdtuddm-23111:1.5.0-MDTUDDM-23111-SNAPSHOT.1" \
    -e DEST="control-plane/infrastructure-jenkins-agent-mdtuddm-23111:1.5.0-MDTUDDM-23111-SNAPSHOT.1" \
    nexus-docker-hosted.apps.cicd2.mdtu-ddm.projects.epam.com/kovtun/cicd2totarget:latest