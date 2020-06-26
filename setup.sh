#!/bin/sh
# Copyright 2020 Google LLC
# Author: ljr@google.com (Leo Rudberg)

set -u

HELP="
Cloud Build Notifiers setup script.

This script runs almost all of the setup required for configuring, building,
and deploying a notifier on GCP. It is based on the guide here:
https://cloud.google.com/cloud-build/docs/configure-notifications
Setting up any secret_name must be done outside
this script. This script is assumed to be run in the root of your
cloud-build-notifiers clone/fork.

The currently supported notifier types (which correspond to the directories in
the repo) are:

* http
* slack
* smtp

Usage [in the cloud-build-notifiers repo root]:

./setup.sh <notifier-type> <local-config-path> [secret-name]

Concrete example:

./setup.sh \
  smtp \
  ~/notifier-configs/my-smtp-config.yaml \
  my-smtp-password

For help/usage:

./setup.sh --help
"


main () {
  # Simple argument checks.
  if [ "$*" = "--help" ]; then
    echo "${HELP}"
    exit 0
  elif [ $# -lt 2 ] || [ $# -gt 3 ]; then
    fail "${HELP}"
  fi


  NOTIFIER_TYPE="$1"
  SOURCE_CONFIG_PATH="$2"
  SECRET_NAME="${3:-}" # Optional secret_name name.

  # Check that the user is using a supported notifier type in the correct
  # directory.
  case "${NOTIFIER_TYPE}" in
  http|smtp|slack|bigquery) ;;
  *) fail "${HELP}"
  esac

  if [ ! -d "${NOTIFIER_TYPE}" ]; then
    fail "expected to run from the root of the cloud-build-notifiers repo"
  fi

  if [ ! -r "${SOURCE_CONFIG_PATH}" ]; then
    fail "expected file at local source config path ${SOURCE_CONFIG_PATH} to be readable"
  fi

  # Project ID, assumed to NOT be org-scoped (only alphanumeric and dashes).
  PROJECT_ID=$(gcloud config get-value project) \
    || fail "could not get default project"
  if [ "${PROJECT_ID}" = "(unset)" ]; then
    fail "default project not set; run \"gcloud config set project <project_id>\"" \
      "or set the CLOUDSDK_CORE_PROJECT environment variable"
  fi
  if [ -z "${PROJECT_ID##*:*}" ]; then
    fail "org-scoped project IDs are not allowed by this script"
  fi
  PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" \
    --format="value(projectNumber)") \
    || fail "could not get project number"

  SOURCE_CONFIG_BASENAME=$(basename "${SOURCE_CONFIG_PATH}")
  DESTINATION_BUCKET_NAME="${PROJECT_ID}-notifiers-config"
  DESTINATION_BUCKET_URI="gs://${DESTINATION_BUCKET_NAME}"
  DESTINATION_CONFIG_PATH="${DESTINATION_BUCKET_URI}/${SOURCE_CONFIG_BASENAME}"
  IMAGE_PATH="gcr.io/${PROJECT_ID}/notifiers/${NOTIFIER_TYPE}"
  SERVICE_NAME="${NOTIFIER_TYPE}-notifier"
  SUBSCRIPTION_NAME="${NOTIFIER_TYPE}-subscription"
  INVOKER_SA="cloud-run-pubsub-invoker@${PROJECT_ID}.iam.gserviceaccount.com"
  PUBSUB_SA="service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com"

  # Turn on command echoing after all of the variables have been set so we
  # don't log spam unnecessarily.
  set -x

  if [ -n "${SECRET_NAME}" ]; then
    add_secret_name_accessor_permission
  fi

  upload_config
  build_notifier
  deploy_notifier
  SERVICE_URL=$(gcloud run services describe "${SERVICE_NAME}" \
    --format="value(status.url)")
  add_sa_token_creator_permission
  create_invoker_sa
  add_invoker_permission
  create_pubsub_subscription
  check_pubsub_subscription

  echo "** NOTIFIER SETUP COMPLETE **" 1>&2
}

fail () {
  echo "$*" 1>&2
  exit 1
}

add_secret_name_accessor_permission () {
  gcloud secrets add-iam-policy-binding "${SECRET_NAME}" \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor" \
    || fail "failed to set up secret access"
}

upload_config () {
  # We allow this `mb` command to error since we rely on the `cp` command hard-
  # erroring if there's an actual problem (since `mb` fails if the bucket
  # already exists).
  gsutil mb "${DESTINATION_BUCKET_URI}"

  gsutil cp "${SOURCE_CONFIG_PATH}" "${DESTINATION_CONFIG_PATH}" \
    || fail "failed to copy config to GCS"
}

build_notifier () {
  gcloud builds submit . \
    --config="${NOTIFIER_TYPE}/cloudbuild.yaml" \
    --substitutions="_IMAGE_PATH=${IMAGE_PATH}" \
    || fail "failed to build notifier on GCB"
}

deploy_notifier () {
  gcloud run deploy "${SERVICE_NAME}" \
    --image="${IMAGE_PATH}" \
    --no-allow-unauthenticated \
    --update-env-vars="CONFIG_PATH=${DESTINATION_CONFIG_PATH}, PROJECT_ID=${PROJECT_ID}" \
    || fail "failed to deploy notifier service -- check service logs"
}

add_sa_token_creator_permission () {
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${PUBSUB_SA}" \
    --role="roles/iam.serviceAccountTokenCreator"
}

create_invoker_sa () {
  gcloud iam service-accounts create cloud-run-pubsub-invoker \
    --display-name "Cloud Run Pub/Sub Invoker"
}

add_invoker_permission () {
  gcloud run services add-iam-policy-binding "${SERVICE_NAME}" \
    --member="serviceAccount:${INVOKER_SA}" \
    --role=roles/run.invoker
}

create_pubsub_subscription () {
  gcloud pubsub subscriptions create "${SUBSCRIPTION_NAME}" \
    --topic=cloud-builds \
    --push-endpoint="${SERVICE_URL}" \
    --push-auth-service-account="${INVOKER_SA}"
}

check_pubsub_subscription () {
  gcloud pubsub subscriptions describe "${SUBSCRIPTION_NAME}" \
    || fail "expected the notifier Pub/Sub subscription to exist"
}

main "$@"