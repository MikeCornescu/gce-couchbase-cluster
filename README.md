# Installing Couchbase at scale on Google Compute Engine (GCE)

This project is about deploying a Couchbase Cluster on GCE, at a predictable scale, with minimum user interaction. Beside configuration, this would mean 2 command lines.

## Usage
### Cloning the repository

First you need to make sure you cloned this repo:

	sudo apt-get update && sudo apt-get install git-core
	[ ! -d ~/src ] && mkdir -p ~/src
	cd ~/src
	git clone https://github.com/blendedio/gce-couchbase-cluster couchbase
	cd couchbase

### Picking your version

If you'd like to deploy a Community Server 3.0.1, do: 

	git checkout 3.0.1

If you'd like to deploy a Community Server 4.0.0, do

	git checkout 4.0.0

### Configuring Google Cloud Platform & project

First you need to create a project in your Google Cloud Platform, then configure the following settings in **etc/project.conf**:

	# Project Settings
	PROJECT_ID=<PUT YOUR GCP PROJECT ID HERE>
	REGION=us-central1
	ZONE=${REGION}-f


### Configure the Couchbase cluster

Open **etc/couchbase.conf** and update the default settings with you preferred values

The deployment method must be kept at gce, but more options will be made available in the future.

	# Couchbase deployment mode
	# Can be gce or gke.
	# Note that GKE is not supported yet
	CB_DEP_MODE=gce

The cluster machine type. Note that Couchbase recommends at least 4 cores, which you would get with n1-standard-4 devices. The size of the cluster represents the number of VM you want to spin.

	# Cluster Settings
	DEFAULT_MACHINE_TYPE="n1-standard-2"
	CB_CLUSTER_SIZE=3

For storage, we will use separate secondary disks, to make the vertical scalability easier. Select the size in GB, and the type of disk. If you pick local-ssd, this will result in the disk being colocated with compute, which is faster but less safe.

	# Storage Settings
	# This is the disk size in GB we set for couchbase nodes
	CB_DEFAULT_DISK_SIZE=10
	# This is the default type of disk we set for the cluster
	# you can use pd-ssd, pd-standard or local-ssd
	CB_DEFAULT_DISK_TYPE=pd-ssd

Network settings. If you want to put the cluster in a specific network, use its ID from the GCP UI.

	CB_CLUSTER_ID="couchbase-cluster"
	CB_CLUSTER_NETWORK="default"
	CB_CLUSTER_PORT=8091

Change the default settings only if Couchbase changes their default values.

	# Default Settings
	CB_DEFAULT_USERNAME=Administrator
	CB_DEFAULT_PASSWORD=password

Change these settings to add the password you really want to use, and rename the first bucket created by our script.

	# Couchbase settings
	CB_CLUSTER_USER=Administrator
	CB_CLUSTER_PASSWORD=p@ssw0rd
	CB_DEFAULT_BUCKET=defaultbucket

### Bootstrap the deployment

You just need to run the bootstrap script

	./bin/00-bootstrap.sh

**Note**: You need to be sudoer for this. Anyway the code will tell you if you can't run it.

This will

* Install all requirements for the whole project if needed
* Install the gcloud command line, and update it to the latest version if needed

### Deploying the cluster

Run the deployment script

	./bin/01-deploy-couchbase.sh

This will

* For requested each unit of the cluster,
	* Create a disk on GCP using the settings you entered. You can tweak this by editing ./persistent-data/couchbase-disk.json.template
	* Spin VMs according to the instance type, and attach the disk to it. VMs run Ubuntu 12.04.
	* Run a first bootstrap script that will format the drive, and install Couchbase 3.0.1 Community Edition on them
	* Create a set of networking configuration to open ports 8091 and 8092, create a load balancing IP address and finally create a TCP load balancer between units.
* Then, for the first unit only,
	* Run a script will harvest all other units into the cluster, the rebalance it.
	* Create a first bucket  

### Using the cluster

For some reason, the load balancer provided by Google doesn't maintain session coherence, which is a shame. That means that if you need to send a single request to the cluster (push or pull), you'll be fine using the LB address.

However, if you intend to maintain a session opened (for administrative perspective) then this will not work properly. In this case you should use one of the units IP address.

# License
Copyright 2015 blended technologies s.l. <http://blended.io>

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
