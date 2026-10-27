# You can test the deployer container running:
#
# make cli
#
DOCKER_VERSION=20.10.5
# The google-cloud-cli image defaults live in the Dockerfile. To build on another
# tag, override GOOGLE_CLOUD_CLI_IMAGE_TAG and GOOGLE_CLOUD_CLI_IMAGE_DIGEST
# together: the digest selects the image and the tag alone is ignored.
dockerfile_arg = $(shell sed -n 's/^ARG $(1)=//p' Dockerfile)
GOOGLE_CLOUD_CLI_IMAGE_TAG ?= $(call dockerfile_arg,GOOGLE_CLOUD_CLI_IMAGE_TAG)
GOOGLE_CLOUD_CLI_IMAGE_DIGEST ?= $(call dockerfile_arg,GOOGLE_CLOUD_CLI_IMAGE_DIGEST)

cli: build-docker-image
	# Run the cli.
	docker run --rm -v ${PWD}:/mnt \
	--entrypoint "" \
	--hostname "SPARK-K8S-DEPLOYER-TEST" --name spark-k8s-deployer \
	-v /var/run/docker.sock:/var/run/docker.sock \
	-it sparkfabrik/spark-k8s-deployer:latest bash -il

build-docker-image:
	docker --debug buildx build \
		-t sparkfabrik/spark-k8s-deployer:latest \
		--build-arg GOOGLE_CLOUD_CLI_IMAGE_TAG=$(GOOGLE_CLOUD_CLI_IMAGE_TAG) \
		--build-arg GOOGLE_CLOUD_CLI_IMAGE_DIGEST=$(GOOGLE_CLOUD_CLI_IMAGE_DIGEST) \
		-f Dockerfile .

build-docker-image-build-args:
	docker --debug buildx build \
		-t sparkfabrik/spark-k8s-deployer:latest \
		--build-arg GOOGLE_CLOUD_CLI_IMAGE_TAG=$(GOOGLE_CLOUD_CLI_IMAGE_TAG) \
		--build-arg GOOGLE_CLOUD_CLI_IMAGE_DIGEST=$(GOOGLE_CLOUD_CLI_IMAGE_DIGEST) \
		--build-arg QEMU_ARCHS="aarch64 arm x86_64" \
		-f Dockerfile .

tests:
	cd test && DOCKER_VERSION=$(DOCKER_VERSION) docker-compose run --rm docker-client ash -c "sleep 3; docker run --rm hello-world"

# Run the cluster resolver test suite inside the deployer image, which ships the
# yq4 the resolver needs to parse the cluster configuration.
test-cluster-resolver: build-docker-image
	docker run --rm -v ${PWD}:/mnt -w /mnt \
		--entrypoint "" \
		sparkfabrik/spark-k8s-deployer:latest \
		bash test/cluster-resolver/run.sh
