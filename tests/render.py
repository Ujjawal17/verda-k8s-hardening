#!/usr/bin/env python3
"""Render every Helm-based Argo CD Application offline, so policies can be tested without a cluster.

Usage: python3 tests/render.py   -> writes tests/out/<app>.yaml
"""
import glob, os, subprocess, tempfile, yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "tests", "out")
os.makedirs(OUT, exist_ok=True)

for path in sorted(glob.glob(os.path.join(ROOT, "argocd", "apps", "*.yaml"))):
    app = yaml.safe_load(open(path))
    spec = app["spec"]
    for src in spec.get("sources", [spec.get("source")]):
        if not src or "chart" not in src:
            continue
        values = src.get("helm", {}).get("valuesObject", {})
        with tempfile.NamedTemporaryFile("w", suffix=".yaml") as vf:
            yaml.safe_dump(values, vf)
            vf.flush()
            rendered = subprocess.run(
                ["helm", "template", app["metadata"]["name"], src["chart"],
                 "--repo", src["repoURL"], "--version", src["targetRevision"],
                 "--namespace", spec["destination"]["namespace"], "--include-crds",
                 "--kube-version", "1.36.5", "-f", vf.name],
                check=True, capture_output=True, text=True).stdout
        with open(os.path.join(OUT, app["metadata"]["name"] + ".yaml"), "w") as f:
            f.write(rendered)
        print("rendered", app["metadata"]["name"])
