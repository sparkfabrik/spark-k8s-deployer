# Spark k8s base image

This images is intended to be used to build and deploy applications to a k8s cluster, from
within gitlab-ci.

This image includes:
 * Docker client 20.10.7-ce
 * Docker-compose 1.29.2
 * Google cloud sdk 346.0.0
 * Helm 3.7.1 (helm3 binary)
 * AWS CLI 1.16.305
 * YQ 4.14.2
 * FLUX2 0.26.2
 * Stern 1.20.1
 * Deploy scripts on `scripts`
