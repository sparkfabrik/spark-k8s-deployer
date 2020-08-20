# You can test the deployer container running:
#
# make cli
#
cli: build-docker-image
  # Run the cli.
	docker run --rm -v ${PWD}:/mnt \
	--hostname "SPARK-K8S-DEPLOYER-TEST" --name spark-k8s-deployer \
	-v /var/run/docker.sock:/var/run/docker.sock \
	-it sparkfabrik/spark-k8s-deployer:latest bash -il \
	--entrypoint /bin/bash

build-docker-image:
	docker build -t sparkfabrik/spark-k8s-deployer:latest -f Dockerfile .
