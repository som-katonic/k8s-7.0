#!/usr/bin/env python3
"""
Generate Terraform backend.tf from katonic.yml config.

Reads terraform_state section and writes the correct backend configuration
into the target terraform/{cloud}/ directory.

Called by entrypoint.sh before terraform init.
"""
import sys
import yaml
import os

BACKENDS = {
    "s3": """
terraform {{
  backend "s3" {{
    bucket         = "{bucket}"
    key            = "katonic/{cluster_name}/terraform.tfstate"
    region         = "{region}"
    dynamodb_table = "{lock_table}"
    encrypt        = true
  }}
}}
""",
    "gcs": """
terraform {{
  backend "gcs" {{
    bucket = "{bucket}"
    prefix = "katonic/{cluster_name}"
  }}
}}
""",
    "azurerm": """
terraform {{
  backend "azurerm" {{
    resource_group_name  = "{resource_group}"
    storage_account_name = "{storage_account}"
    container_name       = "{container}"
    key                  = "katonic/{cluster_name}/terraform.tfstate"
  }}
}}
""",
    "oss": """
terraform {{
  backend "oss" {{
    bucket   = "{bucket}"
    prefix   = "katonic/{cluster_name}"
    region   = "{region}"
    encrypt  = true
  }}
}}
""",
}

# Default backend type per cloud provider
CLOUD_DEFAULTS = {
    "aws": "s3",
    "gcp": "gcs",
    "azure": "azurerm",
    "oci": "s3",
    "alibaba": "oss",
}

def generate(config_path, tf_dir):
    with open(config_path) as f:
        config = yaml.safe_load(f)

    cloud = config.get("cloud_provider", "bare_metal")
    if cloud == "bare_metal":
        print("[tf-backend] Bare metal: no Terraform, skipping backend generation.")
        return

    tf_state = config.get("terraform_state", {})
    backend_type = tf_state.get("backend", CLOUD_DEFAULTS.get(cloud, "local"))

    if backend_type == "local":
        print("[tf-backend] WARNING: Using local Terraform state. Not recommended for production.")
        print("[tf-backend] Set terraform_state.backend in katonic.yml for remote state.")
        return

    if backend_type not in BACKENDS:
        print(f"[tf-backend] ERROR: Unknown backend type: {backend_type}")
        sys.exit(1)

    cluster_name = config.get("cluster_name", "katonic")
    region = tf_state.get("region", config.get("cloud_region", "us-east-1"))

    params = {
        "bucket": tf_state.get("bucket", f"{cluster_name}-tf-state"),
        "cluster_name": cluster_name,
        "region": region,
        "lock_table": tf_state.get("lock_table", f"{cluster_name}-tf-lock"),
        "resource_group": tf_state.get("resource_group", f"{cluster_name}-rg"),
        "storage_account": tf_state.get("storage_account", f"{cluster_name}tfstate".replace("-", "")),
        "container": tf_state.get("container", "tfstate"),
    }

    backend_tf = BACKENDS[backend_type].format(**params)

    # Write to terraform/{cloud}/backend.tf
    cloud_dir_map = {"aws": "aws", "azure": "azure", "gcp": "gcp", "oci": "oci", "alibaba": "alibaba"}
    target_dir = os.path.join(tf_dir, cloud_dir_map.get(cloud, cloud))
    os.makedirs(target_dir, exist_ok=True)
    target_file = os.path.join(target_dir, "backend.tf")

    with open(target_file, "w") as f:
        f.write(backend_tf.strip() + "\n")

    print(f"[tf-backend] Generated {target_file} ({backend_type} backend)")
    print(f"[tf-backend] Bucket: {params['bucket']}, Region: {region}")

if __name__ == "__main__":
    config_path = sys.argv[1] if len(sys.argv) > 1 else "/katonic/katonic.yml"
    tf_dir = sys.argv[2] if len(sys.argv) > 2 else "/katonic/terraform"
    generate(config_path, tf_dir)
