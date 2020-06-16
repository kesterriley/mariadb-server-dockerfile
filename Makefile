#------------------------------------------------------------------
# Project build information
#------------------------------------------------------------------


#------------------------------------------------------------------
# CI targets
#------------------------------------------------------------------

build:
	docker build --build-arg BUILD_DATE=`date -u +"%Y-%m-%dT%H:%M:%SZ"` \
							 --build-arg VCS_REF=`git rev-parse --short HEAD` \
							 --build-arg VERSION=`cat VERSION` \
							 -t $(IMAGE_NAME):latest .

scan:
	docker run --rm -v $(HOME):/root/.cache/ -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy --exit-code 0 --severity MEDIUM,HIGH --ignore-unfixed $(IMAGE_NAME):latest
	# trivy --light -s "UNKNOWN,MEDIUM,HIGH,CRITICAL" --exit-code 1 $(IMAGE)

dockerSave:
	docker save -o image.tar $(IMAGE_NAME)

dockerLoad:
	docker load -i image.tar

publishLatest:
		echo "$(DOCKERHUB_PASS)" | docker login -u "$(DOCKERHUB_USERNAME)" --password-stdin
		IMAGE_TAG="0.0.$(CIRCLE_BUILD_NUM)"
		docker tag $(IMAGE_NAME):latest $(IMAGE_NAME):$(IMAGE_TAG)
		docker push $(IMAGE_NAME):latest
		docker push $(IMAGE_NAME):$(IMAGE_TAG)

publishTagged:
		echo "$(DOCKERHUB_PASS)" | docker login -u "$(DOCKERHUB_USERNAME)" --password-stdin
		IMAGE_TAG=$(CIRCLE_TAG/v/'')
		docker tag $(IMAGE_NAME):latest $(IMAGE_NAME):$(IMAGE_TAG)
		docker push $(IMAGE_NAME):latest
		docker push $(IMAGE_NAME):$(IMAGE_TAG)
