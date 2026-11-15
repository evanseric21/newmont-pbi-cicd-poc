"""Shared helpers for Power BI REST calls using the pipeline service principal."""
import os
import sys

import requests
from azure.identity import ClientSecretCredential

PBI_API = "https://api.powerbi.com/v1.0/myorg"
PBI_SCOPE = "https://analysis.windows.net/powerbi/api/.default"


def require_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        sys.exit(f"::error::Missing required environment variable {name}")
    return value


def credential() -> ClientSecretCredential:
    return ClientSecretCredential(
        tenant_id=require_env("AZURE_TENANT_ID"),
        client_id=require_env("AZURE_CLIENT_ID"),
        client_secret=require_env("AZURE_CLIENT_SECRET"),
    )


class PowerBI:
    def __init__(self, cred: ClientSecretCredential):
        self._cred = cred

    def _headers(self) -> dict:
        token = self._cred.get_token(PBI_SCOPE).token
        return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

    def request(self, method: str, path: str, **kwargs) -> requests.Response:
        resp = requests.request(method, f"{PBI_API}{path}", headers=self._headers(), timeout=120, **kwargs)
        if resp.status_code >= 400:
            sys.exit(f"::error::{method} {path} failed ({resp.status_code}): {resp.text}")
        return resp

    def find_dataset_id(self, workspace_id: str, name: str) -> str:
        datasets = self.request("GET", f"/groups/{workspace_id}/datasets").json()["value"]
        for ds in datasets:
            if ds["name"] == name:
                return ds["id"]
        sys.exit(f"::error::Semantic model '{name}' not found in workspace {workspace_id}")


def write_summary(markdown: str) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(markdown + "\n")
    print(markdown)


def set_output(name: str, value: str) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(f"{name}={value}\n")
