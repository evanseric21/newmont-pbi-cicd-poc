"""Bind the semantic model to its connection on the shared gateway, run a full refresh and wait for it.

A successful refresh in the target environment is one of the promotion checks.

Environment variables:
  AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET  service principal
  WORKSPACE_ID, SEMANTIC_MODEL_NAME
  GATEWAY_ID      on-premises data gateway (cluster) id
  CONNECTION_ID   gateway connection id for this environment's source. In the POC: test-database
                  connection for Dev/QA, prod-database connection for Prod. At Newmont, with one
                  Databricks host + HTTP path, every environment can use the same connection id.
"""
import argparse
import sys
import time

from pbi_common import PowerBI, credential, require_env, write_summary

TERMINAL = {"Completed", "Failed", "Cancelled", "Disabled", "TimedOut"}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout-minutes", type=int, default=60)
    parser.add_argument("--poll-seconds", type=int, default=15)
    args = parser.parse_args()

    workspace_id = require_env("WORKSPACE_ID")
    model_name = require_env("SEMANTIC_MODEL_NAME")
    gateway_id = require_env("GATEWAY_ID")
    connection_id = require_env("CONNECTION_ID")

    pbi = PowerBI(credential())
    dataset_id = pbi.find_dataset_id(workspace_id, model_name)

    pbi.request(
        "POST",
        f"/groups/{workspace_id}/datasets/{dataset_id}/Default.BindToGateway",
        json={"gatewayObjectId": gateway_id, "datasourceObjectIds": [connection_id]},
    )
    print(f"Bound {model_name} ({dataset_id}) to gateway {gateway_id} / connection {connection_id}")

    resp = pbi.request(
        "POST",
        f"/groups/{workspace_id}/datasets/{dataset_id}/refreshes",
        json={"type": "full", "commitMode": "transactional", "retryCount": 0},
    )
    location = resp.headers.get("Location")
    request_id = location.rstrip("/").split("/")[-1] if location else resp.headers["x-ms-request-id"]
    print(f"Refresh requested: {request_id}")

    deadline = time.time() + args.timeout_minutes * 60
    status, detail = "Unknown", {}
    while time.time() < deadline:
        time.sleep(args.poll_seconds)
        detail = pbi.request("GET", f"/groups/{workspace_id}/datasets/{dataset_id}/refreshes/{request_id}").json()
        status = detail.get("extendedStatus") or detail.get("status")
        print(f"  refresh status: {status}")
        if status in TERMINAL:
            break

    write_summary(f"### Refresh\n- Semantic model: `{model_name}`\n- Status: **{status}**\n")
    if status != "Completed":
        messages = detail.get("messages") or detail.get("serviceExceptionJson") or ""
        sys.exit(f"::error::Refresh did not complete successfully (status={status}). {messages}")


if __name__ == "__main__":
    main()
