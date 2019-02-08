#!/bin/bash

#SECURITY CREDENTIALS
ssh_key=~/.ssh/aws_project
ssh_key_name="my_key"
USER_ID="970033870840"

#name for
TITLE="analysis"
INSTACE_TYPE="c5.xlarge"
AMI="ami-0bdf93799014acdc4" #ubuntu ami
DEFAULT_USER="ubuntu"
CPUS_PER_MACHINE=1
NUMBER_OF_NODES=4
DISK_SIZE_PER_MACHINE=30
REGION=eu-central-1
TAG="my_tag"
S3Bucket=""
S3BucketFolder="$S3Bucket""_$TITLE"


#INPUT FILES
master_config=./files/master.json
node_config=./files/node.json
temp_dir=./temp/
analysis_dir=./analysis/



#CHECK IF INPUT FILES EXISTS
if [ ! -f "$master_config" ]; then
    echo "Master machine configuration file -- NOT FOUND!"

else
    echo "Master machine configuration file -- OK!"
fi

if [ ! -f "$node_config" ]; then
    echo "Node machine configuration file -- NOT FOUND!"

else
    echo "Node machine configuration file -- OK!"
fi


#PLACEMENT GROUP
#creating placement group name
placement_group_name=$TITLE"_placement_group"

#checking if placement group wtih the same name exist, if not create it
if [[ $(aws ec2 describe-placement-groups --output text | sed 's/PLACEMENTGROUPS\t//' | sed 's/\t.*//' | grep -w -i $placement_group_name -c) -eq 0 ]] ; then
    aws ec2 create-placement-group --group-name $placement_group_name --strategy cluster
fi

#SECURITY GROUP

#creating security group names
security_group_name=$TITLE"_security_group"

#public ip of machine which perform this script
local_machine_public_IP=$(curl http://checkip.amazonaws.com)

#create new security group if don't exist
if [[ $(aws ec2 describe-security-groups --query 'SecurityGroups[*].GroupName' --output text | grep -w "$security_group_name" -c) -eq 1 ]] ; then
    #create group
    aws ec2 create-security-group --group-name "$security_group_name"
    #enable connection within cluster in one scurity group
    aws ec2 authorize-security-group-ingress --group-name "$security_group_name" --protocol tcp --port 0-65535 --source-group "$security_group_name"
fi
#allow to ssh from local machine (this computer)
aws ec2 authorize-security-group-ingress --group-name $security_group_name --protocol tcp --port 22 --cidr ${local_machine_public_IP}/32

#get from just created group it's ID (it is necesary for create instances)
security_group_id=$(aws ec2 describe-security-groups --query 'SecurityGroups[*].[GroupName, GroupId]' --output text | grep "$security_group_name" | sed 's/.*\t//')

#IAM SETTING SECTION
#iam role is necesary for attaching policy to EC2 allowing access to s# Bucket

#create instance profile name
instance_profile_name=$TITLE"_instance_profile"
IAM_role_name=$TITLE"_IAM_role"

if [ $(aws iam list-instance-profiles --query InstanceProfiles[*].instance_profile_name | grep -w $instance_profile_name -c) -eq 1 ] ; then
    # removing role from instance proffile is necesary to remove later profile
    if ! [ "$(aws iam get-instance-profile --instance-profile-name $instance_profile_name --query "InstanceProfile".Roles[*].RoleName)" == 'null' ] ; then
        aws iam remove-role-from-instance-profile --instance-profile-name $instance_profile_name --role-name $(aws iam get-instance-profile --instance-profile-name $instance_profile_name --query "InstanceProfile".Roles[*].RoleName --output text)
    fi
    aws iam delete-instance-profile --instance-profile-name $instance_profile_name
fi

# if exists, delete old IAM role
if [ $(aws iam list-roles --query Roles[*].RoleName | grep -w $IAM_role_name -c) -eq 1 ] ; then
    # if policies attached, delete them:
    for policyAttached in $(aws iam list-role-policies --role-name $IAM_role_name --query PolicyNames[*] --output text)
    do
        aws iam delete-role-policy --role-name $IAM_role_name --policy-name $policyAttached
    done
    aws iam delete-role --role-name $IAM_role_name
fi

aws iam create-role --role-name $IAM_role_name --assume-role-policy-document file://$EC2trustFile

# edit permissions policy file to include appropriate S3 folder and edit condition for terminate instances policy
cp $permissionsPolicyFile $tempPermissionsPolicyFile

sed -i -e 's|defaultBucket|'"$S3BucketFolder"'/*|' \
    -e 's|arn:aws:ec2:region:userID:instance|arn:aws:ec2:'$region':'$userID':instance|' \
    -e 's|"ec2:ResourceTag/tag-name":"tag-value"|"ec2:ResourceTag/'$tag'":"'$caseName'"|' "$tempPermissionsPolicyFile"

# attach new role policy
aws iam put-role-policy --role-name $IAM_role_name --policy-name $iamPolicyName --policy-document file://$tempPermissionsPolicyFile

# create the instance profile required by EC2 to contain the role
if [ $(aws iam list-instance-profiles --query InstanceProfiles[*].instance_profile_name | grep -w testProfile -c) -eq 0 ] ; then
    aws iam create-instance-profile --instance-profile-name $instance_profile_name
fi

# add the role to the instance profile
aws iam add-role-to-instance-profile --instance-profile-name $instance_profile_name --role-name $IAM_role_name

# associate-iam-instance-profile with instance
sed -i 's|instance_profile_name|'$instance_profile_name'|' $temp_master_config


# waitings help with: An error occurred (InvalidParameterValue) when calling the RunInstances operation: Value (testProfile) for parameter iamInstanceProfile.name is invalid. Invalid IAM Instance Profile name
sleep 30s


# create instances
aws ec2 run-instances --cli-input-json file://"$temp_master_config"
aws ec2 run-instances --cli-input-json file://"$temp_node_config"

# remove temporary files
rm -r $temp_dir


chars="/-\|"
# wait for master initialization
while [[ ! ( $(aws ec2 describe-instances --filter Name=tag:Name,Values="master" --query 'Reservations[*].Instances[*].[State.Name]' --output text | grep -w "running" -c) -eq 1 && $(aws ec2 describe-instances --filter Name=tag:Name,Values="node" --query 'Reservations[*].Instances[*].[State.Name]' --output text | grep -w "running" -c) -eq $NUMBER_OF_NODES-1 ) ]]

do
  for (( i=0; i<${#chars}; i++ )); do
    sleep 0.2
    echo -en "     Initialization in progress" "\r"
    echo -en "  ${chars:$i:1}" "\r"
  done
done
printf "Initialization finished \n"

# connecting to master instance

# get masterIP, read names and IPs of all instances, sort to get only master data with grep and remove junk with sed
masterIP="NULL"
while [[ $masterIP == "NULL" ]]
do
    masterIP=$(aws ec2 describe-instances --filter Name="tag:Name",Values="master" Name="instance-state-name",Values="running" --query 'Reservations[*].Instances[*].[PublicIpAddress]' --output text)
done

# fetching master private IP
master_priv_IP=$(aws ec2 describe-instances --filter Name="tag:Name",Values="master" Name="instance-state-name",Values="running" --query 'Reservations[*].Instances[*].[PrivateIpAddress]' --output text)

# fetching nodes private IP
node_priv_IP=$(aws ec2 describe-instances --filter Name="tag:Name",Values="node" Name="instance-state-name",Values="running" --query 'Reservations[*].Instances[*].[PrivateIpAddress]' --output text | tr '\n' ' ') # format ip1 ip2 ip3

# ENABLE AGENT KEY FORWARDING
ssh-add $ssh_key_name

# creating known host file
ssh -A "$DEFAULT_USER""@""$masterIP" /bin/bash << EOF
    ssh-keyscan -H -t rsa $node_priv_IP  >> ~/.ssh/known_hosts
EOF

#COPYING DATA DO MASTER
while
    scp -qr "$analysis_dir" "$DEFAULT_USER""@""$masterIP":"\${HOME}/analysis/"
    ssh -q "$DEFAULT_USER""@""$masterIP" ! test -e "\${HOME}/analysis/"
do
      for (( i=0; i<${#chars}; i++ )); do
        sleep 0.2
        echo -en "     Copying data to master" "\r"
        echo -en "  ${chars:$i:1}" "\r"
      done
    done
if ssh -q "$DEFAULT_USER""@""$masterIP" test -e "$remoteOFScript" ; then
    printf "Data copied successfully\n"
else
    printf "ERROR, exiting...\n"
    exit 1
fi

#INSTALL REQUIRED PACKAGES ON MASTER
ssh -A "$DEFAULT_USER""@""$masterIP" /bin/bash << EOF
     sudo DEBIAN_FRONTEND=noninteractive apt-get -y update
     sudo DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
     sudo DEBIAN_FRONTEND=noninteractive apt-get -y install nfs-kernel-server
     sudo DEBIAN_FRONTEND=noninteractive apt-get -y install mpich
     sudo DEBIAN_FRONTEND=noninteractive apt-add-repository ppa:elmer-csc-ubuntu/elmer-csc-ppa
     sudo DEBIAN_FRONTEND=noninteractive apt-get -y update
     sudo DEBIAN_FRONTEND=noninteractive apt-get -y install elmerfem-csc
EOF

#INSTALL REQUIRED PACKAGES ON NODES
ssh -A "$DEFAULT_USER""@""$masterIP" /bin/bash << EOF
for ip in $node_priv_IP ; do
    ssh \$ip "sudo DEBIAN_FRONTEND=noninteractive apt-get -y update && sudo DEBIAN_FRONTEND=noninteractive apt-get -y upgrade && sudo DEBIAN_FRONTEND=noninteractive apt-get -y install nfs-kernel-server && sudo DEBIAN_FRONTEND=noninteractive apt-get -y install mpich && sudo DEBIAN_FRONTEND=noninteractive apt-add-repository ppa:elmer-csc-ubuntu/elmer-csc-ppa && sudo DEBIAN_FRONTEND=noninteractive apt-get -y update && sudo DEBIAN_FRONTEND=noninteractive apt-get -y install elmerfem-csc"
done
EOF

# CRETING NFS SERVER
ssh -A "$DEFAULT_USER""@""$masterIP" /bin/bash << EOF
    sudo sh -c "echo '/home/'$DEFAULT_USER'/analysis *(rw,sync,no_subtree_check)' >> /etc/exports"
    sudo exportfs -ra
    sudo service nfs-kernel-server start
EOF

# MOUNTING MASTER DIRECTORY ON NODES
ssh -A "$DEFAULT_USER""@""$masterIP" /bin/bash << EOF
for ip in $node_priv_IP ; do
    ssh \$ip "sudo mount $master_priv_IP:\${HOME}/analysis \${HOME}/analysis"
done
EOF

# save IPs to host_file
ssh -A "$userName""@""$masterIP" /bin/bash << EOF
    printf "$master_priv_IP"" $node_priv_IP" | tr ' ' '\n' > /home/ubuntu/host_file # format ip1 \n ip2 \n ...
EOF

# get instances IDs from this case to allow termination via Master
instancesIDs=$(aws ec2 describe-instances --filter Name=tag:$my_tag,Values=$TITLE Name="instance-state-name",Values="running" --query 'Reservations[*].Instances[*].[InstanceId]' --output text | tr '\n' ' ')

# run script
nohup ssh -A "$DEFAULT_USER""@""$masterIP" /bin/bash << EOF &
     cd /home/ubuntu
     mpiexec -np $NUMBER_OF_NODES*$CPUS_PER_MACHINE -f /home/ubuntu/host_file ElmerSolver_mpi
     # get OpenFoam script PID
     ElmerPID=\$(echo \$!)
     # wait for a program to finish
     wait $ElmerPID
     printf "Calculation finished\n"
     aws s3 cp --recursive "~/analysis" s3://"$S3BucketFolder"
     echo $instancesIDs
     aws ec2 terminate-instances --region eu-central-1 --instance-ids $instancesIDs
EOF
