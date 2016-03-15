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

for file in $(find ${MYDIR}/../etc -name "*.conf") $(find ${MYDIR}/../lib -name "*lib*.sh" | sort) ; do
    echo Sourcing ${file}
    source ${file}
    sleep 1
done 

# Check install of all dependencies
bash::lib::ensure_cmd_or_install_package_apt jq jq

# Check install Google Cloud SDK 
gce::lib::ensure_gcloud_or_install
bash::lib::log debug ready to start...

# Initialize environment
gce::lib::switch_project

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
			2>/dev/null 1>/dev/null && \
			bash::lib::log info Deleted forwarding-rules || \
			bash::lib::die Could not delete forwarding-rules
		gcloud compute target-pools delete -q cb-pool \
			2>/dev/null 1>/dev/null && \
			bash::lib::log info Deleted target-pools || \
			bash::lib::die Could not delete target-pools
		gcloud compute http-health-checks delete -q cb-check  \
			2>/dev/null 1>/dev/null && \
			bash::lib::log info Deleted http-health-checks || \
			bash::lib::die Could not delete http-health-checks
		gcloud compute addresses delete -q network-lb-ip-1  \
			2>/dev/null 1>/dev/null && \
			bash::lib::log info Deleted addresses || \
			bash::lib::die Could not delete addresses
		gcloud compute firewall-rules delete -q cb-fw \
			2>/dev/null 1>/dev/null && \
			bash::lib::log info Deleted firewall-rules || \
			bash::lib::die Could not delete firewall-rules

		# Delete Couchbase Instances
		for NODE_ID in $(seq -f "%03g" 1 1 ${CB_CLUSTER_SIZE}); do
			# Delete instances
			gcloud compute instances delete -q ${MYSERVICE}-${NODE_ID} \
				2>/dev/null 1>/dev/null && \
				bash::lib::log info Deleted compute instances || \
				bash::lib::die Could not delete compute instances

			# Delete data disk
			#gcloud compute disks delete -q "${MYSERVICE}-${NODE_ID}-data" \
			#	|| log err Could not delete disks
		done
	;;
	* )
		bash::lib::log notice CB_DEP_MODE can only be gce or gke. Update etc/couchbase.conf
	;;
esac

# Cleanup Temporary files
[ -d "${MYDIR}/../tmp" ] && rm -rf "${MYDIR}/../tmp"
