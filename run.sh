#!/bin/bash

set -o errexit

LOG_DESTINATION="${LOG_DESTINATION:-${0}.log}"
FIRETAIL_API="${FIRETAIL_API:-https://api.logging.eu-west-1.prod.firetail.app/gcp/apigw/bulk}"

# args
declare \
  FT_LOGGING_ENDPOINT \
  FT_APP_TOKEN \
  GCP_REGION \
  GCP_PROJECT_NUM \
  GCP_GATEWAY_ID \
  GCP_RESOURCE_PREFIX

# derived from args
declare \
  PUBSUB_TOPIC_NAME \
  GCP_PROJECT_ID \
  GCP_FUNCTION_NAME

function main() {
  get_arguments "$@"
  check_gcloud_cli
  set_gcp_project
  create_pubsub_topic
  deploy_cloud_function
}

function check_gcloud_cli() {
  if ! command -v gcloud >/dev/null; then
    local err_msg="Failed to get gcloud CLI from PATH."
    log ERROR "${err_msg}"
    alert_quit "${err_msg} Please install and authenticate gcloud CLI"
  fi
}

function set_gcp_project(){
  gcloud config set project "${GCP_PROJECT_NUM}" ||
    alert_quit "Failed to set project ID to ${GCP_PROJECT_NUM}"
  GCP_PROJECT_ID=$(gcloud projects describe "${GCP_PROJECT_NUM}" --format='value(projectId)')
}

function get_arguments() {
  (($# == 0)) && {
    show_help
    exit 0
  }
  while true; do
    case "$1" in
    --help)
      show_help
      exit 0
      ;;
    --ft-logging-endpoint=*)
      FT_LOGGING_ENDPOINT="${1#--ft-logging-endpoint=}"
      log INFO "FT_LOGGING_ENDPOINT is ${FT_LOGGING_ENDPOINT}"
      ;;
    --ft-logging-endpoint)
      FT_LOGGING_ENDPOINT="${2}"
      shift
      log INFO "FT_LOGGING_ENDPOINT is ${FT_LOGGING_ENDPOINT}"
      ;;
    --ft-app-token=*)
      FT_APP_TOKEN="${1#--ft-app-token=}"
      log INFO "FT_APP_TOKEN is ${FT_APP_TOKEN}"
      ;;
    --ft-app-token)
      FT_APP_TOKEN="${2}"
      shift
      log INFO "FT_APP_TOKEN is ${FT_APP_TOKEN}"
      ;;
    --gcp-region=*)
      GCP_REGION="${1#--gcp-region=}"
      log INFO "GCP_REGION is ${GCP_REGION}"
      ;;
    --gcp-region)
      GCP_REGION="${2}"
      shift
      log INFO "GCP_REGION is ${GCP_REGION}"
      ;;
    --gcp-gateway-id=*)
      GCP_GATEWAY_ID="${1#--gcp-gateway-id=}"
      log INFO "GCP_GATEWAY_ID is ${GCP_GATEWAY_ID}"
      ;;
    --gcp-gateway-id)
      GCP_GATEWAY_ID="${2}"
      shift
      log INFO "GCP_GATEWAY_ID is ${GCP_GATEWAY_ID}"
      ;;
    --gcp-project-num=*)
      GCP_PROJECT_NUM="${1#--gcp-project-num=}"
      log INFO "GCP_PROJECT_NUM is ${GCP_PROJECT_NUM}"
      ;;
    --gcp-project-num)
      GCP_PROJECT_NUM="${2}"
      shift
      log INFO "GCP_PROJECT_NUM is ${GCP_PROJECT_NUM}"
      ;;
    --gcp-resource-prefix=*)
      GCP_RESOURCE_PREFIX="${1#--gcp-resource-prefix=}"
      log INFO "GCP_RESOURCE_PREFIX is ${GCP_RESOURCE_PREFIX}"
      ;;
    --gcp-resource-prefix)
      GCP_RESOURCE_PREFIX="${2}"
      shift
      log INFO "GCP_RESOURCE_PREFIX is ${GCP_RESOURCE_PREFIX}"
      ;;
    "")
      break
      ;;
    --*)
      show_help
      alert_quit "unrecognized flag: '${1}'"
      ;;
    *)
      show_help
      alert_quit "unrecognized argument: '${1}'"
      ;;
    esac
    shift
  done
  check_args_provided
}

function check_args_provided() {
  if [[ -z "${FT_LOGGING_ENDPOINT}" ]]; then
    show_help
    alert_quit "--ft-logging-endpoint is missing"
  fi
  if [[ -z "${FT_APP_TOKEN}" ]]; then
    show_help
    alert_quit "--ft-app-token is missing"
  fi
  if [[ -z "${GCP_REGION}" ]]; then
    show_help
    alert_quit "--gcp-region is missing"
  fi
  if [[ -z "${GCP_GATEWAY_ID}" ]]; then
    show_help
    alert_quit "--gcp-gateway-id is missing"
  fi
  if [[ -z "${GCP_PROJECT_NUM}" ]]; then
    show_help
    alert_quit "--gcp-project-num is missing"
  fi
  if [[ -z "${GCP_RESOURCE_PREFIX}" ]]; then
    show_help
    alert_quit "--gcp-resource-prefix is missing"
  fi
}

function create_pubsub_topic() {
  PUBSUB_TOPIC_NAME="${GCP_RESOURCE_PREFIX}-pubsub-topic-logs-to-firetail"
  destination="pubsub.googleapis.com/projects/${GCP_PROJECT_ID}/topics/${PUBSUB_TOPIC_NAME}"
  log_sink_name="${GCP_RESOURCE_PREFIX}-firetail-log-routing"

  log_filter="resource.type=apigateway.googleapis.com/Gateway AND "
  log_filter+="resource.labels.gateway_id=${GCP_GATEWAY_ID} AND "
  log_filter+="resource.labels.location=${GCP_REGION}"

  gcloud services enable pubsub.googleapis.com --project "${GCP_PROJECT_ID}" ||
    alert_quit "Failed to enable pubsub.googleapis.com"

  gcloud pubsub topics create "${PUBSUB_TOPIC_NAME}" --project="${GCP_PROJECT_ID}" ||
    alert_quit "Failed to create pubsub topic"

  gcloud logging sinks create "${log_sink_name}" "${destination}" \
    --project="${GCP_PROJECT_ID}" \
    --description="log router for firetail" \
    --log-filter="${log_filter}" ||
    alert_quit "Failed to create logging sink"

  service_account=$(
    gcloud logging sinks describe "${log_sink_name}" \
      --format='value(writerIdentity)' \
      --project "${GCP_PROJECT_ID}"
  )

  gcloud pubsub topics add-iam-policy-binding \
    "projects/${GCP_PROJECT_ID}/topics/${PUBSUB_TOPIC_NAME}" \
    --member="${service_account}" \
    --role=roles/pubsub.publisher ||
    alert_quit "Failed to add IAM policy binding"
}

function deploy_cloud_function() {
  GCP_FUNCTION_NAME="${GCP_RESOURCE_PREFIX}-logging-function"

  gcloud services enable cloudbuild.googleapis.com --project "${GCP_PROJECT_ID}" ||
    alert_quit "Failed to enable cloudbuild.googleapis.com"
  gcloud services enable cloudfunctions.googleapis.com --project "${GCP_PROJECT_ID}" ||
    alert_quit "Failed to enable cloudfunctions.googleapis.com"

  gcloud functions deploy "${GCP_FUNCTION_NAME}" \
    --entry-point="subscribe" \
    --gen2 \
    --memory="256MB" \
    --no-allow-unauthenticated \
    --project="${GCP_PROJECT_ID}" \
    --region="${GCP_REGION}" \
    --runtime="python312" \
    --set-env-vars=FIRETAIL_API="${FIRETAIL_API}" \
    --set-env-vars=FIRETAIL_APP_TOKEN="${FT_APP_TOKEN}" \
    --source="src/" \
    --timeout="60s" \
    --trigger-topic="${PUBSUB_TOPIC_NAME}" ||
    alert_quit "Failed to deploy Cloud Function"

}

function log() (
  log_level="${1}"
  timestamp=$(date '+%F %T%z')
  IFS=" "
  shift
  # keep aligned
  printf "[%-5s ${timestamp}] ${*}\n" "${log_level}"
) >>"${LOG_DESTINATION}"

function alert_quit() (
  IFS=" "
  echo -e "\033[0;1;31m${0}: ${*}\033[0m"
  exit 1
)

# Prints usage
# Output:
#   Help usage
function show_help() {
  top_line="Usage: ${0} --ft-logging-endpoint=<endpoint> --ft-app-token=<token> "
  top_line+="--gcp-region=<region> --gcp-gateway-id=<id> --gcp-project-num=<number> "
  top_line+="--gcp-resource-prefix=<prefix>"

  echo -e "\n${top_line}\n"
  echo "  --ft-logging-endpoint  FireTail logging endpoint"
  echo "  --ft-app-token         FireTail application token"
  echo "  --gcp-region           Region where the Gateway is deployed"
  echo "  --gcp-gateway-id       GCP gateway ID"
  echo "  --gcp-project-num      GCP project number"
  echo "  --gcp-resource-prefix  Prefix added to resources created by this script"
  echo "  --help                 Show usage"
  echo ""
}

main "$@"
