#!/usr/bin/env bash

registry_name="$1"
edp_ns="$2"
backup_name="$3"

noobaa_s3_host=$(oc get route/s3 -n openshift-storage -o jsonpath='{.spec.host}')
noobaa_s3_endpoint="https://${noobaa_s3_host}"

echo "Getting AWS_KEY for secret"
access_key_aws=$(oc get secret/backup-credential -n ${edp_ns} -o jsonpath='{.data.backup-s3-like-storage-credentials}' | base64 -d | awk -F : '{print $1}')
echo "Getting AWS_SECRET_KEY for secret"
access_secret_key_aws=$(oc get secret/backup-credential -n ${edp_ns} -o jsonpath='{.data.backup-s3-like-storage-credentials}' | base64 -d | awk -F : '{print $2}')
echo "Start Velero section"


velero_backup=$(oc get regbackup/${backup_name}  -o jsonpath=\'{.spec.velero-backup-name}\'| cut -c2- |rev | cut -c2- | rev)
echo ${velero_backup}
time velero restore create --exclude-resources deploymentconfigs --from-backup ${velero_backup} --wait
sleep 30
time velero restore create --include-resources deploymentconfigs --from-backup ${velero_backup} --wait

oc get pod --selector=app=jenkins -n ${registry_name} -o=NAME | xargs -r oc delete -n ${registry_name}
oc get pod --selector=app=nexus -n ${registry_name} -o=NAME | xargs -r oc delete -n ${registry_name}
oc get pod --selector=app=gerrit -n ${registry_name} -o=NAME | xargs -r oc delete -n ${registry_name}

echo "End Velero section"
for bucket_claim in $(oc get objectbucketclaim -n ${registry_name} -o=NAME) ; do
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

