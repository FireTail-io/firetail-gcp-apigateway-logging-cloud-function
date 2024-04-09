#!/bin/bash

echo "Which region do you want to connect to?"
echo "1. EU"
echo "2. US"
read -p "Enter your choice (1 or 2): " choice

case $choice in
    1)
        endpoint="https://api.logging.eu-west-1.prod.firetail.app/gcp/apigw/bulk"
        ;;
    2)
        endpoint="https://api.logging.us-east-2.prod.us.firetail.app/gcp/apigw/bulk"
        ;;
    *)
        echo "Invalid choice. Please enter 1 or 2."
        exit 1
        ;;
esac

read -p "Enter APP Token: " token

read -p "Enter Google location: " location

gcloud api-gateway gateways list --location=$location

read -p "Enter Google API Gateway ID: " gateway_id


echo "You have chosen to connect to the $location location. $gateway_id $endpoint"