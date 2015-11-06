#!/bin/bash
#####################################################################
#
# Initialize Socius Live script
#
# Notes: 
#   * GCloud Disk Doc: https://cloud.google.com/compute/docs/disks/#comparison_of_disk_types
# 
# Maintainer: Samuel Cozannet <samuel@blended.io>, http://blended.io 
#
#####################################################################

# Validating I am running on debian-like OS
[ -f /etc/debian_version ] || {
	echo "We are not running on a Debian-like system. Exiting..."
	exit 0
}

# Load Configuration
MYNAME="$(readlink -f "$0")"
MYDIR="$(dirname "${MYNAME}")"
MYCONF="${MYDIR}/../etc/project.conf"
MYLIB="${MYDIR}/../lib/bashlib.sh"

for file in "${MYCONF}" "${MYLIB}" "${MYDIR}/../etc/couchbase.conf" "${MYDIR}/../lib/gcelib.sh"; do
	[ -f ${file} ] && source ${file} || { 
		echo "Could not find required files. Exiting..."
		exit 0
	}
done 

# Check install of all dependencies
ensure_cmd_or_install_package_apt jq jq

# Check install Google Cloud SDK 
ensure_gcloud_or_install
log debug ready to start...

# Initialize environment
switch_project

#####################################################################
#
# Delete k8s cluster & assets
#
#####################################################################

# Deleting k8s clusters
# gcloud container clusters delete -q "${APP_CLUSTER_ID}" --zone ${ZONE} \
# 	|| log err "No Kubernetes cluster found"

#####################################################################
#
# Delete Couchbase cluster & assets
#
#####################################################################

# Delete Couchbase Cluster
MYSERVICE=couchbase
case "${CB_DEP_MODE}" in
	"gke" )
		# # Deleting k8s clusters
		# COUCHBASE_CLUSTER="$(cat ${MYDIR}/../tmp/couchbase_cluster)"
		# gcloud container clusters delete "${COUCHBASE_CLUSTER}" --zone ${ZONE} \
		# 	|| log err Could not delete Kubernetes cluster 	
	;;
	"gce" )
		# Delete Couchbase Load Balancing
		gcloud compute forwarding-rules delete -q cb-rule \
			|| log err Could not delete forwarding-rules
		gcloud compute target-pools delete -q cb-pool \
			|| log err Could not delete target-pools
		gcloud compute http-health-checks delete -q cb-check  \
			|| log err Could not delete http-health-checks
		gcloud compute addresses delete -q network-lb-ip-1  \
			|| log err Could not delete addresses
		gcloud compute firewall-rules delete -q cb-fw \
			|| log err Could not delete firewall rules

		# Delete Couchbase Instances
		for NODE_ID in $(seq -f "%03g" 1 1 ${CB_CLUSTER_SIZE}); do
			# Delete instances
			gcloud compute instances delete -q ${MYSERVICE}-${NODE_ID} \
				|| log err Could not delete instances

			# Delete data disk
			#gcloud compute disks delete -q "${MYSERVICE}-${NODE_ID}-data" \
			#	|| log err Could not delete disks
		done
	;;
	* )
		log notice CB_DEP_MODE can only be gce or gke. Update etc/socius-couchbase.conf
	;;
esac

# Cleanup Temporary files
[ -d "${MYDIR}/../tmp" ] && rm -rf "${MYDIR}/../tmp"
