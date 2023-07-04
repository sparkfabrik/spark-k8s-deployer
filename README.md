# Spark k8s deployer image

This images is intended to be used to build and deploy applications to a k8s cluster, from
within gitlab-ci.

This image includes:

- Docker client 20.10.7
- Docker-compose v2.14.0
- Google cloud sdk 422.0.0
- Helm 3.11.2 (helm3 binary)
- Deploy scripts on `scripts`
- Flux 0.26.2
- YQ4 4.14.2
- Stern 1.24.0
- AWS-cli 1.16.305
