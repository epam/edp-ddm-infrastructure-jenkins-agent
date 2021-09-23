#!/usr/bin/env bash

registry_name="$1"
edp_ns="$2"
backup_name="$3"

noobaa_s3_host=$(oc get route/s3 -n openshift-storage -o jsonpath='{.spec.host}')
noobaa_s3_endpoint="https://${noobaa_s3_host}"

echo "Getting AWS_KEY for secret"
access_key_aws=$(oc get secret/backup-credentials -n ${edp_ns} -o jsonpath='{.data.backup-s3-like-storage-credentials}' | base64 -d | awk -F : '{print $1}')
echo "Getting AWS_SECRET_KEY for secret"
access_secret_key_aws=$(oc get secret/backup-credentials -n ${edp_ns} -o jsonpath='{.data.backup-s3-like-storage-credentials}' | base64 -d | awk -F : '{print $2}')
echo "Start Velero section"

velero_backup=$(oc get regbackup/${backup_name}  -o jsonpath=\'{.spec.velero-backup-name}\'| cut -c2- |rev | cut -c2- | rev)
echo ${velero_backup}
echo "Start restoring configmaps"
time velero restore create --include-resources configmaps --from-backup "${velero_backup}" --wait
echo "End restore configmaps"
echo "Start restoring secrets"
time velero restore create --include-resources secrets --from-backup "${velero_backup}" --wait
echo "End restore secrets"
echo "Start restoring nexus"
time velero create restore --selector app=nexus --from-backup  "${velero_backup}" --wait
echo "End restoring nexus"
echo "Start restoring gerrit"
time velero create restore --selector app=gerrit --from-backup  "${velero_backup}" --wait
echo "End restoring gerrit"
echo "Start restoring jenkins"
time velero create restore --selector app=jenkins --from-backup  "${velero_backup}" --wait
echo "End restoring jenkins"
echo "Start restoring citus-master"
time velero restore create --selector app=citus-master --from-backup "${velero_backup}" --wait
while [[ "$(oc get pods -n ${registry_name} -l=app='citus-master' -o 'jsonpath={.items[*].status.containerStatuses[0].ready}')" != "true" && $(curl citus-master.${registry_name}.svc.cluster.local:5432 --connect-timeout 5 | grep "Empty reply from server") == '' ]]; do
  sleep 10
  pod_name=`oc get pod -l app=citus-master --no-headers -o NAME -n ${registry_name}`
  oc delete $pod_name -n ${registry_name}
    while [[ $(oc get pods -l app='citus-master' -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' -n ${registry_name}) != "True" ]]; do
      echo "waiting for pod" && sleep 1;
    done
done
echo "End restoring citus-master"
echo "Start restoring citus-master-rep"

time velero restore create --selector app=citus-master-rep --from-backup ${velero_backup} --wait

while [[ "$(oc get pods -n ${registry_name} -l=app='citus-master-rep' -o 'jsonpath={.items[*].status.containerStatuses[0].ready}')" != "true" && $(curl citus-master-rep.${registry_name}.svc.cluster.local:5432 --connect-timeout 5 |grep "Empty reply from server") == '' ]]; do
sleep 10

  pod_name=`oc get pod -l app=citus-master-rep --no-headers -o NAME -n ${registry_name}`
  oc delete $pod_name -n ${registry_name}
    while [[ $(oc get pods -l app='citus-master-rep' -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' -n "${registry_name}") != "True" ]]; do
      echo "waiting for pod" && sleep 1;
     done
done
echo "End restoring citus-master-rep"
echo "Start restoring citus-workers"
time velero restore create --selector app=citus-workers --from-backup "${velero_backup}" --wait
sleep 10
  pod_name=$(oc get pod -l app=citus-workers --no-headers -o NAME -n "${registry_name}")
for i in ${pod_name} ;do
while [[ "$(oc get $i -n "${registry_name}" -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}')" != "True" ]]; do
    sleep 10
    oc delete "$i" -n "${registry_name}" ;
    echo "Waiting citus-worker pod"
    sleep 20
  done
done
echo "End restoring citus-workers"
echo "Start restoring citus-workers-rep"
time velero restore create --selector app=citus-workers-rep --from-backup "${velero_backup}" --wait
sleep 10
pod_name=$(oc get pod -l app=citus-workers-rep --no-headers -o NAME -n "${registry_name}")
for i in ${pod_name} ;do
while [[ "$(oc get $i -n "${registry_name}" -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}')" != "True" ]]; do
    oc delete "$i" -n "${registry_name}" ;
    echo "Waiting citus-worker-rep pod"
    sleep 20
  done
done
echo "End restoring citus-workers-rep"
echo "Start restoring form-management-modeler"
time velero restore create --include-resources pods --selector app=form-management-modeler-db --from-backup "${velero_backup}" --wait

time velero restore create --selector app=form-management-modeler --from-backup "${velero_backup}" --wait
pod_name_app=$(oc get pod -l app=form-management-modeler --no-headers -o NAME -n "${registry_name}")
sleep 10
for i in ${pod_name_app} ;do
while [[ "$(oc get $i -n "${registry_name}" -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}')" != "True" ]]; do
    sleep 10
    oc delete "$i" -n "${registry_name}" ;
    echo "Waiting app=form-management-modeler pod"
    sleep 20
  done
done
echo "End restoring form-management-modeler"
echo "Start restoring form-management-provider"
time velero restore create --include-resources pods --selector app=form-management-provider-db --from-backup "${velero_backup}" --wait
time velero restore create --selector app=form-management-provider --from-backup "${velero_backup}" --wait
sleep 10
pod_name_app=$(oc get pod -l app=form-management-provider-db --no-headers -o NAME -n "${registry_name}")
for i in ${pod_name_app} ;do
while [[ "$(oc get $i -n "${registry_name}" -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}')" != "True" ]]; do
    sleep 10
    oc delete "$i" -n "${registry_name}" ;
    echo "Waiting app=form-management-provider pod"
    sleep 20
  done
done
echo "End restoring form-management-provider"
echo "Start restoring all others resources"
time velero restore create --from-backup "${velero_backup}" --exclude-resources pods --wait
echo "End restoring all others resources"
echo "Start restoring KeycloakAuthFlow"
time velero create restore --include-resources keycloakauthflows --from-backup "${velero_backup}" --wait
echo "End restore KeycloakAuthFlow"

echo "End Velero section"
for bucket_claim in $(oc get objectbucketclaim -n "${registry_name}" -o=NAME) ; do
  echo $bucket_claim

obc_name=$(awk 'BEGIN{split(ARGV[1],var,"/");print var[2]}' "$bucket_claim")

echo $obc_name

oc delete -n ${registry_name} obc/$obc_name
oc delete -n ${registry_name} cm/$obc_name
oc delete -n ${registry_name} secret/$obc_name
sleep 10

cat <<EOF | oc apply -f -
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: "${obc_name}"
  namespace: "${registry_name}"
spec:
  additionalConfig:
    bucketclass: registry-bucket-class
  generateBucketName: "${obc_name}"
  storageClassName: registry-bucket
  ssl: false
EOF

sleep 10

bucket=$(oc get "${bucket_claim}" -n "${registry_name}" -o=jsonpath="{.spec.bucketName}")
echo "Start restore for ${bucket}"
bucket_secret=$(awk 'BEGIN{split(ARGV[1],var,"/");print var[2]}' "${bucket_claim}")
echo ${bucket_secret}
echo sleep 10
acess_key_noobaa=$(oc get secret/"${bucket_secret}" -n "${registry_name}" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
access_secret_key_noobaa=$(oc get secret/${bucket_secret} -n "${registry_name}" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)
mkdir -p ~/.config/rclone
get_registry_backup_name=$(oc get regbackup -o=NAME | grep ${backup_name})
registry_backup_name=$(awk 'BEGIN{split(ARGV[1],var,"/");print var[2]}' "${get_registry_backup_name}")
s3_backup_location=$(oc get regbackup/${registry_backup_name}  -o jsonpath=\'{.spec.objectbucket-backup-link}\'| cut -c7- |rev | cut -c3- | rev)
echo $s3_backup_location

echo "
[s3_bucket]
type = s3
provider = AWS
env_auth = false
access_key_id = ${access_key_aws}
secret_access_key = ${access_secret_key_aws}
region = eu-central-1
location_constraint = EU
acl = bucket-owner-full-control

[noobaa]
type = s3
provider = Ceph
env_auth = false
access_key_id = ${acess_key_noobaa}
secret_access_key = ${access_secret_key_noobaa}
endpoint = ${noobaa_s3_endpoint}
acl = bucket-owner-full-control
bucket_acl = authenticated-read" > ~/.config/rclone/rclone.conf

rclone  -v sync s3_bucket:${s3_backup_location} noobaa:${bucket}

if [ $? -eq 0 ]; then
 echo "Restore was compete with no errors"
else
  echo "Backup complete with ERROR"
fi ; done

echo "fix for rejected routes"
for i in $(oc get svc -n ${registry_name} -o=NAME| awk -F / {'print $2'});
do
route_count=$(oc get routes -n ${registry_name} --field-selector=spec.to.name=$i,spec.path!='' --no-headers | wc -l)
    if [[ "${route_count}" -ge "2" ]]; then
oc get routes -n ${registry_name} --field-selector=spec.to.name=$i,spec.path!='' --no-headers |grep -v HostAlreadyClaimed | awk {'print $1'}| xargs -r oc delete route -n ${registry_name};
    fi ; done
