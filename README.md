# Synthetic Monitoring for Private Cloud Director

This repository contains scripts and helm charts for deploying synthetic API monitors for [Private Cloud Director by Platform9](https://platform9.com/private-cloud-director/).

## Dependencies

This chart relies on an existing Postgresql database to persist monitor results along with an optional deployment of Grafana for dashboards and alerting.

### Postgresql

If you do not already have a suitable postgresql instance, you can use the [cnpg operator](https://cloudnative-pg.io/) to easily deploy one on your Kubernetes cluster, or you can deploy one directly using the official postgres docker images https://hub.docker.com/_/postgres.

Once you have a database deployed and accessible from the namespace where you plan to deploy the synthetic monitors, you will need to create an output configuration with the relevant details.

```
# cat 00-output.toml
[postgresql]
host = "10.0.0.1"
port = 5432
user = "ps_user"
password = "<db_password>"
db = "ps_db"
```

Then create a Kubernetes secret from the config file and deploy it into the same namespace as you plan to deploy the synthetic monitors.

```
kubectl create secret generic pcd-synthetic-db-conf --from-file=00-output.toml -n=monitoring  
```

### PCD DU configuration

Before installing the helm chart, you will need to create a Kubernetes secret from an openstack.rc file containing the authorization env vars for your PCD deployment. It is strongly recommended that you create a separate read-only user for this purpose. You can generate this file using the PCD Clarity UI ([instructions](https://docs.platform9.com/managed-openstack/getting-started-openstack-rc-file)). Note that the generated credentials file does not include your real password and so will need to be manually edited with complete credentials before use.

```
kubectl create secret generic mydu-pcd-synthetic --from-env-file=openstack.rc -n=monitoring
```

## Installation

```
helm repo add pcd-synth https://drmille2.github.io/pcd_synthetic_monitoring
helm repo update

helm install my-du pcd-synth/pcd-synthetic -n=monitoring
```
  
If you did not use the default resource names for the output configuiration and openstack rc secrets, you can use helm chart overrides to provide the correct names (`outputConfigNameOverride` and `pcdEnvSecretNameOverride`).

