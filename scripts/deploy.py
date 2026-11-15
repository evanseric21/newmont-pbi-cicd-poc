"""Publish the PBIP items in ./src to a Fabric workspace with fabric-cicd.

Environment variables:
  AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET  service principal
  WORKSPACE_ID                                           target workspace
  FABRIC_ENV                                             DEV | QA | PROD (key in src/parameter.yml)
"""
import argparse
from pathlib import Path

from fabric_cicd import FabricWorkspace, publish_all_items

from pbi_common import credential, require_env, set_output, write_summary


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-directory", default=str(Path(__file__).resolve().parents[1] / "src"))
    args = parser.parse_args()

    env = require_env("FABRIC_ENV")
    workspace_id = require_env("WORKSPACE_ID")

    workspace = FabricWorkspace(
        workspace_id=workspace_id,
        environment=env,
        repository_directory=args.repository_directory,
        item_type_in_scope=["SemanticModel", "Report"],
        token_credential=credential(),
    )
    publish_all_items(workspace)

    set_output("published", "true")
    write_summary(f"### Deploy\n- Environment: **{env}**\n- Workspace: `{workspace_id}`\n- Items: SemanticModel, Report\n")


if __name__ == "__main__":
    main()
