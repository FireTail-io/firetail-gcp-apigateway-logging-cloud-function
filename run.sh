#!/bin/bash

LOG_DESTINATION="${LOG_DESTINATION:-${0}.log}"
FIRETAIL_API="${FIRETAIL_API:-https://api.logging.eu-west-1.prod.firetail.app/gcp/apigw/bulk}"
DEFAULT_GCP_FUNCTION_NAME="firetail_logging"
PUBSUB_TOPIC_NAME="firetail-apigateway-stackdriver-sink"

declare \
  FT_LOGGING_ENDPOINT \
  FT_APP_TOKEN \
  GCP_REGION \
  GCP_GATEWAY_ID \
  GCP_FUNCTION_NAME \
  GCP_PROJECT_ID

function main() {
  check_gcloud_cli
  get_gcp_project_id
  get_arguments "$@"
  create_pubsub_topic
  deploy_cloud_function
}

function check_gcloud_cli() {
  if ! command -v gcloud >/dev/null; then
    local err_msg="Failed to get gcloud CLI from PATH. Please install and authenticate gcloud CLI"
    log ERROR "${err_msg}"
    alert_quit "${err_msg}"
  fi
}

function get_gcp_project_id() {
  gcp_account="$(gcloud auth list --filter=status:ACTIVE --format="value(account)")"
  log INFO "GCP Account: ${gcp_account}"
  echo "GCP account: ${gcp_account}"
  PS3="Enter the number of the project for Cloud Function deployment: "
  select gcp_project_id in $(gcloud projects list --format="value(projectId)"); do
    gcloud config set project "${gcp_project_id}" ||
      alert_quit "Failed to set project ID to ${gcp_project_id}"
    GCP_PROJECT_ID="${gcp_project_id}"
    log INFO "Cloud Function will deploy to ${gcp_project_id}"
    # if invalid response, keep prompting
    [[ -n "${response}" ]] && break
  done
}

function get_arguments() {
  while true; do
    case "$1" in
    --help)
      show_help
      exit
      ;;
    --ft-logging-endpoint=*)
      FT_LOGGING_ENDPOINT="${1#--ft-logging-endpoint=}"
      log INFO "FT_LOGGING_ENDPOINT = ${FT_LOGGING_ENDPOINT}"
      ;;
    --ft--app-token=*)
      FT_APP_TOKEN="${1#--ft-app-token=}"
      log INFO "FT_APP_TOKEN = ${FT_APP_TOKEN}"
      ;;
    --gcp-region=*)
      GCP_REGION="${1#--gcp-region=}"
      log INFO "GCP_REGION = ${GCP_REGION}"
      ;;
    --gcp-gateway-id=*)
      GCP_GATEWAY_ID="${1#--gcp-gateway-id=}"
      log INFO "GCP_GATEWAY_ID = ${GCP_GATEWAY_ID}"
      ;;
    --gcp-function-name=*)
      GCP_FUNCTION_NAME="${1#--gcp-function-name=}"
      if [[ "${GCP_FUNCTION_NAME}" == "" ]]; then
        log WARN "No function name provided, using default: '${DEFAULT_GCP_FUNCTION_NAME}'"
        GCP_FUNCTION_NAME="${DEFAULT_GCP_FUNCTION_NAME}"
      fi
      log INFO "GCP_FUNCTION_NAME = ${GCP_FUNCTION_NAME}"
      ;;
    "")
      break
      ;;
    *)
      alert_quit "unrecognized flag; try '${0} --help' for more information"
      ;;
    esac
    shift
  done
  check_args_provided
}

function check_args_provided() {
  if [[ -z "${FT_LOGGING_ENDPOINT}" ]]; then
    alert_quit "FireTail Region is missing; try '${0} --help' for more information"
  fi
  if [[ -z "${FT_APP_TOKEN}" ]]; then
    alert_quit "FireTail Token is missing; try '${0} --help' for more information"
  fi
  if [[ -z "${GCP_REGION}" ]]; then
    alert_quit "Region for Google Cloud Platform is missing; try '${0} --help' for more information"
  fi
  if [[ -z "${GCP_GATEWAY_ID}" ]]; then
    alert_quit "Gateway ID for Google Cloud Platform is missing; try '${0} --help' for more information"
  fi
}

function create_pubsub_topic() {
  destination="pubsub.googleapis.com/projects/${GCP_PROJECT_ID}/topics/${PUBSUB_TOPIC_NAME}"
  log_filter="resource.type=apigateway.googleapis.com/Gateway AND "
  log_filter+="resource.labels.gateway_id=${GCP_GATEWAY_ID} AND "
  log_filter="resource.labels.location=${GCP_REGION}"
  log_sink_name="firetail-log-routing"

  gcloud services enable pubsub.googleapis.com

  gcloud pubsub subscriptions create \
    --topic firetail-apigateway-stackdriver-sink firetail-subscription \
    --project="${GCP_PROJECT_ID}"

  gcloud pubsub topics create "${PUBSUB_TOPIC_NAME}" --project="${GCP_PROJECT_ID}"

  gcloud logging sinks create "${log_sink_name}" "${destination}" \
    --project="${GCP_PROJECT_ID}" \
    --description="log router for firetail" \
    --log-filter="${log_filter}"

  service_account=$(gcloud logging sinks describe --format='value(writerIdentity)' ${log_sink_name})

  gcloud pubsub topics add-iam-policy-binding "projects/${GCP_PROJECT_ID}/topics/${PUBSUB_TOPIC_NAME}" \
    --member="${service_account}" \
    --role=roles/pubsub.publisher
}

function deploy_cloud_function() {
  {
    gcloud services enable cloudbuild.googleapis.com
    gcloud services enable cloudfunctions.googleapis.com
  } >/dev/null

  if [[ "${GCP_FUNCTION_NAME}" =~ ^firetail_* ]]; then
    function_name_to_deploy="${GCP_FUNCTION_NAME}"
  else
    function_name_to_deploy="firetail_${GCP_FUNCTION_NAME}"
  fi

  topic_prefix="${GCP_FUNCTION_NAME}-pubsub-topic-logs-to-firetail"

  if ! gcloud functions deploy "${function_name_to_deploy}" \
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
    --trigger-topic="${topic_prefix}" \
    --trigger-topic=${PUBSUB_TOPIC_NAME}; then
    alert_quit "Failed to create Cloud Function"
  fi
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
  echo -e "\e[0;31m${0}: ${*}\e[0m"
  exit 1
)

# Prints usage
# Output:
#   Help usage
function show_help() {
  echo "Usage: ${0} --ft-logging-endpoint=<ft-logging-endpoint> --ft-app-token=<token> --gcp-region=<region> --gcp-gateway-id=<gateway-id> [--gcp-function-name=<function-name>]"
  echo "Flags require --key=value format"
  echo "  --ft-logging-endpoint  Endpoint for FireTail app"
  echo "  --ft-app-token         Token from target FireTail app"
  echo "  --gcp-region           Region for GCP Cloud Function"
  echo "  --gcp-gateway-id       GCP gateway ID"
  echo "  --gcp-function-name    Cloud Function name and for prefix for services"
  echo "  --help                 Show usage"
}

main "$@"