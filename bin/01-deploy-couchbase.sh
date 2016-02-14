#!/bin/bash
#####################################################################
#
# Deploy Couchbase on N GCE instances running Ubuntu 12.04
#
# Notes: This could be improved with a Configuration Engine
#   such as http://tugdualgrall.blogspot.fr/2013/05/create-couchbase-cluster-in-one-command.html
# 
# Maintainer: Samuel Cozannet <samuel@blended.io>, http://blended.io 
#
#####################################################################

# Validating I am running on debian-like OS
[ -f /etc/debian_version ] || {
	echo "We are not running on a Debian-like system.."
	exit 0
}

# Load Configuration
MYNAME="$(readlink -f "$0")"
MYSERVICE="couchbase"
MYDIR="$(dirname "${MYNAME}")"
MYCONF="${MYDIR}/../etc/project.conf"
MYSERVICECONF="${MYDIR}/../etc/${MYSERVICE}.conf"
MYLIB="${MYDIR}/../lib/bashlib.sh"
MYVOLUMESDIR="${MYDIR}/../persistent-disks"

if [ $(grep "YOUR_PROJECT_NAME" "${MYCONF}" | wc -l ) -eq 1 ]
then
    echo "You did not set your project in ${MYCONF}. Please do and restart"
    exit 1
fi

for file in "${MYCONF}" "${MYLIB}" "${MYSERVICECONF}" "${MYDIR}/../lib/gcelib.sh"; do
	[ -f ${file} ] && source ${file} || { 
		echo "Could not find required file ${file}.."
		exit 1
	}
done 

if [ "${CB_DEP_MODE}" != "gce" ]; then
	die This script deploys Couchbase with containers on GCE. Please update etc/couchbase.conf 
fi

# Check if we are sudoer or not
if [ $(is_sudoer) -eq 0 ]; then
    die "You must be root or sudo to run this script"
fi

[ ! -d "${MYDIR}/../tmp" ] && mkdir -p "${MYDIR}/../tmp"

# Setup
switch_project

#####################################################################
#
# Create Infrastructure
#
#####################################################################

# Create infrastructure
NODE_LIST=""
log debug Creating Infrastructure
for NODE_ID in $(seq -f "%03g" 1 1 ${CB_CLUSTER_SIZE}); do
	# Create data disk
	log debug Creating disk for ${MYSERVICE}-${NODE_ID}
	sed -e s/DISK_ID/${NODE_ID}/g \
		-e s/DISK_SIZE/${CB_DEFAULT_DISK_SIZE}/g \
		-e s/DISK_TYPE/${CB_DEFAULT_DISK_TYPE}/g \
		"${MYVOLUMESDIR}/${MYSERVICE}-disk.json.template" > "${MYDIR}/../tmp/${MYSERVICE}-${NODE_ID}.json"

	create_gcloud_disk "${MYDIR}/../tmp/${MYSERVICE}-${NODE_ID}.json"

	# Create instances
	log debug Creating instance ${MYSERVICE}-${NODE_ID}
	gcloud compute instances create ${MYSERVICE}-${NODE_ID} \
		--machine-type "${DEFAULT_MACHINE_TYPE}" \
		--image ubuntu-12-04 \
		--zone ${ZONE} \
		--disk name=${MYSERVICE}-${NODE_ID}-data,device-name="${MYSERVICE}"-data,mode=rw,boot=no,auto-delete=yes \
		1>/dev/null 2>/dev/null \
		&& log info Successfully created Instance ${MYSERVICE}-${NODE_ID} \
		|| die Could not create instance ${MYSERVICE}-${NODE_ID}

	# Create Firewall rules
	log debug Adding tags to units for load balancing
	gcloud compute instances add-tags "${MYSERVICE}-${NODE_ID}" --tags "cb-lb" \
		1>/dev/null 2>/dev/null \
		&& log info Successfully tagged Instance ${MYSERVICE}-${NODE_ID} as cb-lb \
		|| die Could not tag instance ${MYSERVICE}-${NODE_ID} with cb-lb
	EXT_FW_LIST="tcp:${CB_CLUSTER_PORT}"
	for PORT in 8092 ; do
		EXT_FW_LIST="${EXT_FW_LIST},tcp:${PORT}"
	done
	# for PORT in  11209-11211 4369 8092 18091 18092 11214 11215 21100-21299; do
	#	EXT_FW_LIST="${EXT_FW_LIST},tcp:${PORT}"
	#done

	# Storing Node list for Load Balancer
	if [ "${NODE_ID}" = "001" ]; then 
		NODE_LIST="${MYSERVICE}-${NODE_ID}"
	else
		NODE_LIST="${NODE_LIST},${MYSERVICE}-${NODE_ID}"
	fi
done

log debug Create firewall rule for traffic on ${EXT_FW_LIST}
gcloud compute firewall-rules create "cb-fw" \
	--target-tags "cb-lb" \
	--allow "${EXT_FW_LIST}" \
	1>/dev/null 2>/dev/null \
	&& log info Successfully created Firewall Rule cb-fw \
	|| die Could not create Firewall rule cb-fw

#####################################################################
#
# Internal Firewalling: we take a shortcut between the Couchbase
# cluster and the GKE cluster. Over time this should be more 
# constrained
#
#####################################################################

# INT_FW_LIST="tcp:11209-11211"

#log debug Create firewall rule for traffic on ${INT_FW_LIST}
#gcloud compute firewall-rules create "cb-fw-gke" \
#	--target-tags "cb-lb" \
#	--allow "${INT_FW_LIST}" \
#	--source-ranges 10.200.0.0/14 10.240.0.0/16

log debug Writing install scripts for this cluster
FOUND_COUCHBASE_IPS=""
while [ "x${FOUND_COUCHBASE_IPS}" = "x" ]; do 
	FOUND_COUCHBASE_IPS="$(gcloud compute instances list --format json | jq '.[].networkInterfaces | .[].networkIP' | tr -d "\"" | tr '\n' ' ')"
	sleep 5
done

log info found IP Addresses \"${FOUND_COUCHBASE_IPS}\" for cluster

#####################################################################
#
# Setup Nodes
#
#####################################################################

# Script to execute on Ubuntu Servers
cp "${MYDIR}/../containers/couchbase-server/00-bootstrap.sh.template" "${MYDIR}/../tmp/00-bootstrap.sh"

sed -e s/CB_DEFAULT_USERNAME/"${CB_DEFAULT_USERNAME}"/g \
	-e s/CB_DEFAULT_PASSWORD/"${CB_DEFAULT_PASSWORD}"/g \
	-e s/CB_CLUSTER_USER/"${CB_CLUSTER_USER}"/g \
	-e s/CB_CLUSTER_PASSWORD/"${CB_CLUSTER_PASSWORD}"/g \
	-e s/CB_DEFAULT_BUCKET/"${CB_DEFAULT_BUCKET}"/g \
	-e s/CB_CLUSTER_ID/"${CB_CLUSTER_ID}"/g \
	-e s/CB_CLUSTER_PORT/"${CB_CLUSTER_PORT}"/g \
	-e s/FOUND_COUCHBASE_IPS/"${FOUND_COUCHBASE_IPS}"/g \
	"${MYDIR}/../containers/couchbase-server/01-deploy.sh.template" > "${MYDIR}/../tmp/01-deploy.sh"

chmod +x "${MYDIR}/../tmp/00-bootstrap.sh"
chmod +x "${MYDIR}/../tmp/01-deploy.sh"

# Copy & execute scripts to instances
log debug Copying scripts to instances
for NODE_ID in $(seq -f "%03g" 1 1 ${CB_CLUSTER_SIZE}); do
	log debug Copying files to ${MYSERVICE}-${NODE_ID}
	gcloud compute copy-files \
		"${MYDIR}/../tmp/01-deploy.sh" \
		"${MYDIR}/../tmp/00-bootstrap.sh" \
		"${MYSERVICE}-${NODE_ID}":~/ \
		--zone "${ZONE}" \
		1>/dev/null 2>/dev/null \
		&& log info Successfully copied scripts to ${MYSERVICE}-${NODE_ID} \
		|| die Could not copy scripts ${MYSERVICE}-${NODE_ID}

	log debug Setting exec flag on scripts on ${MYSERVICE}-${NODE_ID}
	gcloud compute ssh "${MYSERVICE}-${NODE_ID}" --command "chmod +x ~/*.sh" \
		1>/dev/null 2>/dev/null
	log debug Executing bootstrap on ${MYSERVICE}-${NODE_ID}
	gcloud compute ssh "${MYSERVICE}-${NODE_ID}" --command "sudo ~/00-bootstrap.sh" \
		1>/dev/null 2>/dev/null \
		&& log info Successfully bootstrapped Instance ${MYSERVICE}-${NODE_ID} \
		|| die Could not bootstrap instance ${MYSERVICE}-${NODE_ID}
done

# Wait a few secs for cluster to be up everywhere
log debut Let us sleep for 30sec so our nodes start nicely...
sleep 30 

# Create Cluster (only on first node)
log debug Executing Deploy on "${MYSERVICE}-001"
gcloud compute ssh "${MYSERVICE}-001" --command "sudo ~/01-deploy.sh" \
		1>/dev/null 2>/dev/null \
		&& log info Successfully deployed Instance ${MYSERVICE} \
		|| die Could not deploy ${MYSERVICE}

#####################################################################
#
# Creating Load Balancer
# Doc: https://cloud.google.com/compute/docs/load-balancing/network/example
#
#####################################################################

# Give some time to have the cluster rebalanced
sleep 10

# Creating load balancer service
log debug Creating Load balancer
gcloud compute addresses create network-lb-ip-1 \
    --region "${REGION}" \
	1>/dev/null 2>/dev/null \
	&& log info Successfully created network network-lb-ip-1 \
	|| die Could not create network network-lb-ip-1

# Adding health check for cluster 
# See https://issues.couchbase.com/browse/MB-5814
gcloud compute http-health-checks create cb-check \
	--port ${CB_CLUSTER_PORT} \
	--request-path "/pools/default/buckets/${CB_DEFAULT_BUCKET}/stats" \
	1>/dev/null 2>/dev/null \
	&& log info Successfully created health-check cb-check \
	|| die Could not create health-check cb-check

gcloud compute target-pools create cb-pool \
    --region "${REGION}" \
    --health-check cb-check \
	1>/dev/null 2>/dev/null \
	&& log info Successfully created target-pool cb-pool \
	|| die Could not create target-pool cb-pool

gcloud compute target-pools add-instances cb-pool \
    --instances "${NODE_LIST}" \
    --zone "${ZONE}" \
	1>/dev/null 2>/dev/null \
	&& log info Successfully add instances to cb-pool \
	|| die Could not add instances to cb-pool

STATIC_EXTERNAL_IP="$(gcloud compute addresses list | tail -n1 | awk '{ print $3 }')"

gcloud compute forwarding-rules create cb-rule \
    --region "${REGION}" \
    --port-range ${CB_CLUSTER_PORT} \
    --target-pool cb-pool \
    --address "${STATIC_EXTERNAL_IP}" \
	1>/dev/null 2>/dev/null \
	&& log info Successfully created forwarding rule cb-rule \
	|| die Could not create forwarding rule cb-rule

log debug Successfully deployed a load balanced Couchbase Cluster
log debug You can access it on "${STATIC_EXTERNAL_IP}" on ports "${EXT_FW_LIST}"
