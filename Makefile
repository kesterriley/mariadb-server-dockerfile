#------------------------------------------------------------------
# Project build information
#------------------------------------------------------------------
PROJNAME := kubernetes-toolkit
KUBERNETES_VERSION := 1.17.2

# GCR_REPO := eu.gcr.io/swade1987
# GCLOUD_SERVICE_KEY ?="unknown"
# GCLOUD_SERVICE_EMAIL := circle-ci@swade1987.iam.gserviceaccount.com
# GOOGLE_PROJECT_ID := swade1987
# GOOGLE_COMPUTE_ZONE := europe-west2-a

CIRCLE_BUILD_NUM ?="unknown"
IMAGE := $(PROJNAME):$(KUBERNETES_VERSION)

#------------------------------------------------------------------
# CI targets
#------------------------------------------------------------------

build:
	docker build --build-arg BUILD_DATE=`date -u +"%Y-%m-%dT%H:%M:%SZ"` \
							 --build-arg VCS_REF=`git rev-parse --short HEAD` \
							 --build-arg VERSION=`cat VERSION` \
							 -t $(IMAGE_NAME):latest .
#
# push-to-gcr: configure-gcloud-cli
# 	docker tag $(IMAGE) $(GCR_REPO)/$(IMAGE)
# 	gcloud docker -- push $(GCR_REPO)/$(IMAGE)
# 	docker rmi $(GCR_REPO)/$(IMAGE)
#
# configure-gcloud-cli:
# 	echo '$(GCLOUD_SERVICE_KEY)' | base64 --decode > /tmp/gcloud-service-key.json
# 	gcloud auth activate-service-account $(GCLOUD_SERVICE_EMAIL) --key-file=/tmp/gcloud-service-key.json
# 	gcloud --quiet config set project $(GOOGLE_PROJECT_ID)
# 	gcloud --quiet config set compute/zone $(GOOGLE_COMPUTE_ZONE)

scan:
	docker run --rm -v $(HOME):/root/.cache/ -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy --exit-code 0 --severity MEDIUM,HIGH --ignore-unfixed $(IMAGE_NAME):latest
	# trivy --light -s "UNKNOWN,MEDIUM,HIGH,CRITICAL" --exit-code 1 $(IMAGE)
