#!/usr/bin/env bash

if [[ $# -eq 0 ]] ; then
    echo 'run script with registry name and backup type'
    exit 1
fi

registry_name="$1"
edp_ns="$2"
backup_type="$3"

declare -a openshift_resources=("service" "gerrit" "jenkins" "codebase" "keycloakclient" "jenkinsauthorizationrolemapping")
execution_time=$(date '+%Y-%m-%d-%H-%M-%S')
backup_date=$(date '+%Y-%m-%d-%H-%M-%S')


echo "Getting AWS_KEY for secret"
access_key_aws=$(oc get secret/backup-credentials -n ${edp_ns} -o jsonpath='{.data.backup-s3-like-storage-access-key-id}' | base64 -d )
echo "Getting AWS_SECRET_KEY for secret"
access_secret_key_aws=$(oc get secret/backup-credentials -n ${edp_ns} -o jsonpath='{.data.backup-s3-like-storage-secret-access-key}' | base64 -d )
echo "Getting Minio Url from secret"
minio_endpoint=$(oc get secret/backup-credentials -n ${edp_ns} -o jsonpath='{.data.backup-s3-like-storage-url}' | base64 -d)
echo "Getting Rook endpoint"
rook_s3_endpoint=$(oc get cephobjectstore/mdtuddm -n openshift-storage -o=jsonpath='{.status.info.endpoint}')
echo "Getting backupBucket for secret"
destination_bucket=$(oc get secret/backup-credentials -n ${edp_ns} -o jsonpath='{.data.backup-s3-like-storage-location}' | base64 -d)

velero backup create ${registry_name}-${execution_time} --include-namespaces ${registry_name} --wait

for bucket_claim in $(oc get objectbucketclaim -n ${registry_name} --no-headers -o=custom-columns="NAME:.metadata.name") ; do
  bucket=$(oc get objectbucketclaim/"${bucket_claim}" -n "${registry_name}" -o=jsonpath="{.spec.bucketName}")
  echo "Start backup for ${bucket}"

  access_key_rook=$(oc get secret/"${bucket_claim}" -n "${registry_name}" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
  access_secret_key_rook=$(oc get secret/"${bucket_claim}" -n "${registry_name}" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)
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
  provider = Ceph
  env_auth = false
  access_key_id = ${access_key_rook}
  secret_access_key = ${access_secret_key_rook}
  endpoint = ${rook_s3_endpoint}
  acl = bucket-owner-full-control
  bucket_acl = authenticated-read" > ~/.config/rclone/rclone.conf

  rclone sync rook:${bucket} minio:${destination_bucket}/openshift-backups/backups/${registry_name}-${execution_time}/obc-backup/${bucket_claim}/

done

echo "Get Openshift resources and backup them"
rm -rf /tmp/openshift-resources  && mkdir -p /tmp/openshift-resources

for resources_kind in "${openshift_resources[@]}"
do
    for name in $(oc get ${resources_kind} -n ${registry_name} --no-headers -o custom-columns="NAME:.metadata.name" | sed 'N;s/\n/ /g')
    do
      echo ${resources_kind}/${name}
      oc get ${resources_kind}/${name} -n ${registry_name} -o yaml > /tmp/openshift-resources/${resources_kind}-${name}.yaml
    done
done
rclone copy /tmp/openshift-resources minio:/${destination_bucket}/openshift-backups/backups/${registry_name}-${execution_time}/openshift-resources
rm -rf /tmp/openshift-resources

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
    minio-endpoint: ${minio_endpoint}
    objectbucket-backup-link: s3://${destination_bucket}/openshift-backups/backups/${registry_name}-${execution_time}/obc-backup/
EOF
fi

registry_ddm_resource=$(oc get regbackup/${registry_name}-${execution_time})

if [ "${registry_ddm_resource}" ] ; then
   echo "CR present in cluster" ;
else
   echo "CR not present in cluster" ;
fi
