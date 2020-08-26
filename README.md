# Spark k8s base image

This images is intended to be used to build and deploy applications to a k8s cluster, from
within gitlab-ci.

This image includes:
 * Docker client 17.12.0-ce
 * Docker-compose 1.22.0
 * Google cloud sdk 306.0.0
 * Helm 2.14.3 (helm binary)
 * Helm 3.3.0 (helm3 binary)
 * Deploy scripts on `scripts`
