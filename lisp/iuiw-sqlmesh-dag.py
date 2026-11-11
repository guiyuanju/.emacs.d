#!/usr/bin/env python3
"""Print the SQLMesh project in the current directory as JSON.

  {"<schema.name>": {"path": "<file or null>", "deps": ["<schema.name>", ...]}, ...}

Run with the project's own Python so its SQLMesh version loads the models.
"""
import contextlib
import io
import json
import sys

from sqlmesh import Context

with contextlib.redirect_stdout(io.StringIO()):
    ctx = Context(paths=".")

names = {fqn: model.name for fqn, model in ctx.models.items()}
graph = {}
for fqn, deps in ctx.dag.graph.items():
    model = ctx.models.get(fqn)
    graph[names.get(fqn, fqn)] = {
        "path": str(model._path) if model is not None and model._path else None,
        "deps": sorted(names.get(dep, dep) for dep in deps),
    }
json.dump(graph, sys.stdout)
