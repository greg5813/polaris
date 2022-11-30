#!/bin/bash
set -e

echo "Testing to ensure that the webhook starts up, allows a correct deployment to pass, and prevents a incorrectly formatted deployment."

BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

function get_timeout() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    date -v+4M +%s
  else
    date -d "+4 minutes" +%s
  fi
}

function check_webhook_is_ready() {
    # Get the epoch time in one minute from now
    local timeout_epoch

    # Reset another 4 minutes to wait for webhook
    timeout_epoch=$(get_timeout)

    # loop until this fails (desired condition is we cannot apply this yaml doc, which means the webhook is working
    echo "Waiting for webhook to be ready"
    while ! kubectl get pods -n polaris | grep -E "webhook.*1/1.*Running"; do
        check_timeout "${timeout_epoch}"
        echo -n "."
    done

    check_timeout "${timeout_epoch}"

    echo "Webhook started!"
}

# Check if timeout is hit and exit if it is
function check_timeout() {
    local timeout_epoch="${1}"
    if [[ "$(date +%s)" -ge "${timeout_epoch}" ]]; then
        echo -e "Timeout hit waiting for readiness: exiting"
        grab_logs
        clean_up
        exit 1
    fi
}

# Clean up all your stuff
function clean_up() {
    echo -e "\n\nCleaning up (you may see some errors)...\n\n"
    kubectl delete ns scale-test || true
    kubectl delete ns mutate-test || true
    kubectl delete ns polaris || true
    kubectl delete ns tests || true
    # Clean up files you've installed (helps with local testing)
    for filename in test/webhook_cases/*.yaml; do
        # || true to avoid issues when we cannot delete
        kubectl delete -f $filename ||true
    done
    echo "Uninstalling webhook and webhook config"
    kubectl delete validatingwebhookconfigurations polaris-webhook --wait=false || true
    kubectl delete validatingwebhookconfigurations polaris-validate-webhook --wait=false || true
    kubectl delete mutatingwebhookconfigurations polaris-mutate-webhook --wait=false || true
    kubectl -n polaris delete deploy -l app=polaris --wait=false || true
    echo -e "\n\nDone cleaning up\n\n"
}

function grab_logs() {
    kubectl -n polaris get pods -oyaml -l app=polaris
    kubectl -n polaris describe pods -l app=polaris
    kubectl -n polaris logs -l app=polaris -c webhook-certificate-generator
    kubectl -n polaris logs -l app=polaris
}

clean_up || true

echo -e "Setting up..."
kubectl create ns scale-test
kubectl create ns mutate-test
kubectl create ns polaris
kubectl create ns tests

kubectl get validatingwebhookconfiguration

echo "Installing a bad deployment"
kubectl apply -n scale-test -f ./test/webhook_cases/failing_test.deployment.yaml

echo "Installing the webhook"
helm repo add fairwinds-stable https://charts.fairwinds.com/stable
helm install polaris fairwinds-stable/polaris --namespace polaris --create-namespace \
  --set dashboard.enable=false \
  --set webhook.enable=true \
  --set image.tag=$CI_SHA1

echo "Waiting for the webhook to come online"
check_webhook_is_ready
sleep 5

kubectl logs -n polaris $(kubectl get po -oname -n polaris | grep webhook) --follow &

echo "Webhook started"
ALL_TESTS_PASSED=1

echo "Running tests against correctly configured objects"
for filename in test/webhook_cases/passing_test.*.yaml; do
    echo -e "\n\n"
    echo -e "${BLUE}TEST CASE: $filename${NC}"
    if ! kubectl apply -n tests -f $filename; then
        ALL_TESTS_PASSED=0
        echo -e "${RED}****Test Failed: Polaris prevented a resource with no configuration issues****${NC}"
    else
        echo -e "${GREEN}****Test Passed: Polaris correctly allowed this resource****${NC}"
    fi
    kubectl delete -n tests -f $filename || true
done

echo "Running tests against incorrectly configured objects"
for filename in test/webhook_cases/failing_test.*.yaml; do
    echo -e "\n\n"
    echo -e "${BLUE}TEST CASE: $filename${NC}"
    if kubectl apply -n tests -f $filename; then
        ALL_TESTS_PASSED=0
        echo -e "${RED}****Test Failed: Polaris should have prevented this resource due to configuration issues.****${NC}"
        kubectl logs -n polaris $(kubectl get po -oname -n polaris | grep webhook)
    else
      echo -e "${GREEN}****Test Passed: Polaris correctly prevented this resource****${NC}"
    fi
    kubectl delete -n tests -f $filename || true
done

echo "Checking ability to scale"
kubectl -n scale-test scale deployment nginx-deployment --replicas=2
sleep 5
kubectl get po -n scale-test
pod_count=$(kubectl get po -n scale-test -oname | wc -l)
if [ $pod_count != 2 ]; then
  ALL_TESTS_PASSED=0
  echo "Existing deployment was unable to scale after webhook installed: found $pod_count pods"
fi

echo "Checking mutations"
helm upgrade --install polaris fairwinds-stable/polaris --namespace polaris --create-namespace \
  --set dashboard.enable=false \
  --set webhook.enable=true \
  --set webhook.mutate=true \
  --set image.tag=$CI_SHA1
echo "Waiting for the webhook to come online"
check_webhook_is_ready
kubectl apply -n mutate-test -f test/webhook_cases/mutation.deployment.yaml
if ! kubectl get -n mutate-test deployment nginx-deployment-mutated -oyaml | grep "imagePullPolicy: Always"; then
  ALL_TESTS_PASSED=0
  echo -e "${RED}****Test Failed: Polaris failed to mutate this resource****${NC}"
else
  echo -e "${GREEN}****Test Passed: Polaris mutated this resource****${NC}"
fi
kubectl delete -n mutate-test -f test/webhook_cases/mutation.deployment.yaml || true
sleep 5


echo "Done with tests"

if [ -z $SKIP_FINAL_CLEANUP ]; then
  echo "Doing final cleanup..."
  clean_up
fi

#Verify that all the tests passed.
if [ $ALL_TESTS_PASSED -eq 1 ]; then
    echo "Tests Passed."
else
    echo "Tests Failed."
    exit 1
fi
