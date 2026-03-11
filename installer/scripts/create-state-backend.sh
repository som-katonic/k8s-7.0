#!/usr/bin/env bash
# ===========================================================================
# One-time setup: Create Terraform state backend (S3/GCS/Azure Blob/OSS)
#
# Usage:
#   ./create-state-backend.sh aws   katonic-tf-state us-east-1
#   ./create-state-backend.sh gcp   katonic-tf-state us-central1
#   ./create-state-backend.sh azure katonic-tf-state eastus
#   ./create-state-backend.sh alibaba katonic-tf-state cn-hangzhou
# ===========================================================================
set -euo pipefail

CLOUD="${1:?Usage: $0 <aws|gcp|azure|alibaba> <bucket-name> <region>}"
BUCKET="${2:?Bucket name required}"
REGION="${3:?Region required}"
LOCK_TABLE="${4:-${BUCKET}-lock}"

case "$CLOUD" in
  aws)
    echo "Creating S3 bucket: $BUCKET (region: $REGION)"
    aws s3 mb "s3://$BUCKET" --region "$REGION" 2>/dev/null || echo "Bucket exists"
    aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
    aws s3api put-bucket-encryption --bucket "$BUCKET" \
      --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
    aws s3api put-public-access-block --bucket "$BUCKET" \
      --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

    echo "Creating DynamoDB lock table: $LOCK_TABLE"
    aws dynamodb create-table \
      --table-name "$LOCK_TABLE" \
      --attribute-definitions AttributeName=LockID,AttributeType=S \
      --key-schema AttributeName=LockID,KeyType=HASH \
      --billing-mode PAY_PER_REQUEST \
      --region "$REGION" 2>/dev/null || echo "Table exists"
    ;;

  gcp)
    echo "Creating GCS bucket: $BUCKET (region: $REGION)"
    gsutil mb -l "$REGION" "gs://$BUCKET" 2>/dev/null || echo "Bucket exists"
    gsutil versioning set on "gs://$BUCKET"
    ;;

  azure)
    RG="${5:-${BUCKET}-rg}"
    SA=$(echo "$BUCKET" | tr -d '-')
    echo "Creating Azure resources (RG: $RG, SA: $SA, region: $REGION)"
    az group create --name "$RG" --location "$REGION" 2>/dev/null || true
    az storage account create --name "$SA" --resource-group "$RG" --location "$REGION" \
      --sku Standard_LRS --encryption-services blob 2>/dev/null || true
    KEY=$(az storage account keys list --account-name "$SA" --resource-group "$RG" --query '[0].value' -o tsv)
    az storage container create --name tfstate --account-name "$SA" --account-key "$KEY" 2>/dev/null || true
    ;;

  alibaba)
    echo "Creating OSS bucket: $BUCKET (region: $REGION)"
    aliyun oss mb "oss://$BUCKET" --region "$REGION" 2>/dev/null || echo "Bucket exists"
    ;;

  *)
    echo "Unknown cloud: $CLOUD"
    exit 1
    ;;
esac

echo ""
echo "Done. Add this to your katonic.yml:"
echo ""
echo "terraform_state:"
echo "  backend: $([ "$CLOUD" = "azure" ] && echo "azurerm" || echo "$CLOUD" | sed 's/alibaba/oss/' | sed 's/aws/s3/' | sed 's/gcp/gcs/')"
echo "  bucket: \"$BUCKET\""
echo "  region: \"$REGION\""
