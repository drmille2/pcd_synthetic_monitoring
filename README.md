# Synthetic Monitoring for Private Cloud Director

This repository contains scripts and helm charts for deploying synthetic API monitors for [Private Cloud Director by Platform9](https://platform9.com/private-cloud-director-community-edition/).

## Installation

```
helm repo add pcd-synth https://drmille2.github.io/pcd_synthetic_monitoring
helm repo update  
```

Before installing the helm chart, you will need to create a Kubernetes secret from an openstack.rc file containing the authorization env vars for your PCD deployment.

```
kubectl create secret generic pcd-rc --from-env-file=openstack.rc -n=monitoring
```

# TODO
the rest
