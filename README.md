# Spark k8s deployer image

This images is intended to be used to build and deploy applications to a k8s cluster, from
within gitlab-ci.

This image includes:
 * Docker client 20.10.7
 * Docker-compose v2.14.0
 * Google cloud sdk 405.0.0
 * Helm 3.7.1
 * Deploy scripts on `scripts`
 * Aws cli 1.16.305
 * [YQ](https://github.com/mikefarah/yq) v4.14.2
 * Flux 0.26.2
 * Stern 1.22.0
