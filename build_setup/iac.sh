CURRENT_PROJECT_ID=$(gcloud info --format="value(config.project)")

GCP_REGION="europe-west1"
GATEWAY_NAME="gatewat"

#gcloud pubsub subscriptions create --topic firetail-apigateway-stackdriver-sink firetail-subscription --project=$CURRENT_PROJECT_ID 

FILTERS="resource.type=apigateway.googleapis.com/Gateway AND resource.labels.gateway_id=gatewat AND resource.labels.location=europe-west1"
DESTINATION="pubsub.googleapis.com/projects/$CURRENT_PROJECT_ID/topics/firetail-apigateway-stackdriver-sink"

gcloud pubsub topics create firetail-apigateway-stackdriver-sink --project=$CURRENT_PROJECT_ID

gcloud logging sinks create firetail-log-routing $DESTINATION \
    --project=$CURRENT_PROJECT_ID \
    --description="log router for firetail" \
    --log-filter="resource.type=apigateway.googleapis.com/Gateway AND resource.labels.gateway_id=${GATEWAY_NAME} AND resource.labels.location=europe-west1"

gcloud pubsub topics describe firetail-apigateway-stackdriver-sink --project=$CURRENT_PROJECT_ID

service_account=$(gcloud logging sinks describe --format='value(writerIdentity)' firetail-log-routing)

gcloud pubsub topics add-iam-policy-binding projects/${CURRENT_PROJECT_ID}/topics/firetail-apigateway-stackdriver-sink \
  --member=${service_account} --role=roles/pubsub.publisher

gcloud functions deploy firetail-apigateway-logging-2 \
--gen2 \
--runtime="python312" \
--entry-point="firetail_apigateway_logging" \
--memory="256MB" \
--timeout="60s" \
--project=$CURRENT_PROJECT_ID \
--region=$GCP_REGION \
--source="src/" \
--entry-point="subscribe" \
--trigger-topic="firetail-apigateway-stackdriver-sink" \
--set-env-vars FIRETAIL_APP_TOKEN=$FT_TOKEN,FIRETAIL_API="https://api.logging.eu-west-1.prod.firetail.app/gcp/apigw/bulk"



