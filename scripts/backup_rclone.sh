#!/usr/bin/env bash

if [[ $# -eq 0 ]] ; then
    echo 'run script with registry name and backup type'
    exit 1
fi

registry_name="$1"
edp_ns="$2"
backup_type="$3"

noobaa_s3_host=$(oc get route/s3 -n openshift-storage -o jsonpath='{.spec.host}')
noobaa_s3_endpoint="https://${noobaa_s3_host}"

execution_time=$(date '+%Y-%m-%d-%H-%M-%S')
backup_date=$(date '+%Y-%m-%d-%H-%M-%S')


echo "Getting AWS_KEY for secret"
access_key_aws=$(oc get secret/backup-credentials -n ${edp_ns} -o jsonpath='{.data.backup-s3-like-storage-credentials}' | base64 -d | awk -F : '{print $1}')
echo "Getting AWS_SECRET_KEY for secret"
access_secret_key_aws=$(oc get secret/backup-credentials -n ${edp_ns} -o jsonpath='{.data.backup-s3-like-storage-credentials}' | base64 -d | awk -F : '{print $2}')
echo "Getting backupBucket for secret"
destination_bucket=$(oc get secret/backup-credentials -n ${edp_ns} -o jsonpath='{.data.backup-s3-like-storage-location}' | base64 -d)

for bucket_claim in $(oc get objectbucketclaim -n ${registry_name} -o=NAME) ; do
bucket=$(oc get "${bucket_claim}" -n "${registry_name}" -o=jsonpath="{.spec.bucketName}")
echo "Start backup for ${bucket}"
bucket_secret=$(awk 'BEGIN{split(ARGV[1],var,"/");print var[2]}' "${bucket_claim}")

acess_key_noobaa=$(oc get secret/"${bucket_secret}" -n "${registry_name}" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
access_secret_key_noobaa=$(oc get secret/"${bucket_secret}" -n "${registry_name}" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)
mkdir -p ~/.config/rclone

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

rclone sync noobaa:${bucket} s3_bucket:${destination_bucket}/backups/obc-backup/${registry_name}/${execution_time}/${bucket_secret}/


if [ $? -eq 0 ]; then
cat <<EOF | oc apply -f -
apiVersion: ddm.registy.jenkins/v1
kind: RegistryBackup
metadata:
  name: ${registry_name}-${execution_time}
spec:
  type: ${backup_type}
  date: ${execution_time}
  registry-alias: ${registry_name}
  velero-backup-name: ${registry_name}-${execution_time}
  objectbucket-backup-link: s3://${destination_bucket}/backups/obc-backup/${registry_name}/${execution_time}/${bucket_secret}/
EOF

echo "s3://${destination_bucket}/backups/obc-backup/${registry_name}/${execution_time}/${bucket_secret}/"
else
  echo "Backup complete with ERROR"
fi ; done

velero backup create ${registry_name}-${execution_time} --include-namespaces ${registry_name} --wait

registry_ddm_resource=$(oc get regbackup/${registry_name}-${execution_time})

if [ "${registry_ddm_resource}" ] ; then
   echo "CR present in cluster" ;
else
   echo "CR not present in cluster" ;
fi
