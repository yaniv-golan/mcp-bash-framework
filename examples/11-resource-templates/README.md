# 11-resource-templates

**What you’ll learn**
- Discovering templates from `resources/*.meta.json` (no `uri` required)
- Manual template registration and override precedence
- Expanding templates client-side and reading the concrete URI, which the server matches back to its template (`{+path}` spans `/`)

**Prereqs**
- Bash 3.2+
- jq or gojq required; without it the server enters minimal mode and templates are unavailable

**Run**
```
./examples/run 11-resource-templates
```

**Transcript**
```
> resources/templates/list
< {"result":{"resourceTemplates":[{"name":"project-files","uriTemplate":"file:///{+path}",...},{"name":"repo-tree",...},{"name":"logs-by-date",...}]}}
> resources/read {"uri":"file://./resources/example.txt"}
< {"result":{"contents":[{"type":"text","text":"This file is reachable via the project-files template"}]}}
```

**Success criteria**
- `resources/templates/list` returns three templates sorted by name.
- Manual registration overrides `project-files` (description/annotations are taken from `server.d/register.json`).
- Reading `file://./resources/example.txt` succeeds (clients expand `project-files` to a concrete URI).

**Troubleshooting**
- Ensure `resources/*.meta.json` are present and readable.
- If the list is empty, check logs for validation warnings (missing `{variable}`, both `uri` and `uriTemplate`, or name collisions).
- Template changes reuse the existing `resources/list_changed` notification path; refresh templates after editing files if your client caches results.
