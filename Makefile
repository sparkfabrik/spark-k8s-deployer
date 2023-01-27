# You can test the deployer container running:
#
# make cli
#
DOCKER_VERSION=20.10.5

cli: build-docker-image
  # Run the cli.
	docker run --rm -v ${PWD}:/mnt \
	--entrypoint "" \
	--hostname "SPARK-K8S-DEPLOYER-TEST" --name spark-k8s-deployer \
	-v /var/run/docker.sock:/var/run/docker.sock \
	-it sparkfabrik/spark-k8s-deployer:latest bash -il

build-docker-image:
	docker build -t sparkfabrik/spark-k8s-deployer:latest -f Dockerfile .

build-docker-image-build-args:
	docker build -t sparkfabrik/spark-k8s-deployer:latest -f Dockerfile . --build-arg QEMU_ARCHS="aarch64 arm x86_64"

tests:
	cd test && DOCKER_VERSION=$(DOCKER_VERSION) docker-compose run --rm docker-client ash -c "sleep 3; docker run --rm hello-world"
