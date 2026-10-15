---
name: run-tests
description: >-
  Run OpenShift Pipelines acceptance tests, upgrade tests, provision clusters,
  and manage CI infrastructure via release-tests-infra scripts.
  Active when working in the release-tests-infra repository.
---

# OpenShift Pipelines CI Operations

## When to activate

Use this skill when the user asks to:
- Run acceptance or upgrade tests
- Set up a fresh cluster for testing
- Provision or destroy clusters
- Check test status or diagnose failures
- Analyze a PipelineRun (results, logs, duration, pass/fail)
- Clean up AWS resources
- Install/uninstall the Pipelines operator
- Configure test environments or MCP server

## Per-operation env files

Each operation uses a separate env file. NEVER use `.env` directly — always use the files in `env/`:

| Operation | Env file | Script |
|-----------|----------|--------|
| **Acceptance** | `env/.env.acceptance` | `ENV_FILE=env/.env.acceptance ./scripts/run-workflow.sh` |
| **UI acceptance** | `env/.env.acceptance-ui` | `ENV_FILE=env/.env.acceptance-ui ./scripts/run-ui-workflow.sh` |
| **Upgrade** | `env/.env.upgrade` | `ENV_FILE=env/.env.upgrade ./scripts/run-upgrade-tests.sh` |

---

## MANDATORY: Collect user input before running

Use the AskQuestion tool to collect ALL empty required fields in ONE prompt. Do NOT stop the script — gather inputs interactively and proceed.

Steps:
1. Read the env file for the requested operation
2. Check every required field
3. If ANY required field is empty, use AskQuestion to collect ALL empty values at once. Each field should be a separate question with predefined options where applicable.
4. Write the collected values to the env file
5. Re-read to verify all fields are filled
6. Run the script

---

## Acceptance tests flow

### Step 1: Read and validate

Read `env/.env.acceptance`. Check these required fields:

| # | Field | Options / Input type |
|---|-------|---------------------|
| 1 | `INSTALLER` | Options: `none` (Recommended), `cluster-platforms`, `aws-ipi` |
| 2 | `CLUSTER_NAME` | Free text (e.g., my-cluster) |
| 3 | `APISERVER` | Free text (e.g., https://api.example.com:6443) |
| 4 | `KUBEADMIN_PASSWORD` | Free text |
| 5 | `OPERATOR_VERSION` | Free text (e.g., 1.23.0, 1.22.3) |
| 6 | `OPERATOR_ENVIRONMENT` | Options: `pre-stage` (Recommended), `prod`, `stage` |
| 7 | `TAGS` | Options: `e2e` (Recommended), `sanity` |
| 8 | `TEST_FRAMEWORK` | Options: `gauge` (Recommended), `ginkgo` |
| 9 | `KONFLUX_INDEX_IMAGE` | Free text — only ask if environment is pre-stage/stage |

Auto-set (do NOT ask):
- `CATALOG_SOURCE`: `redhat-operators` if prod, `custom-operators` if pre-stage/stage

### Step 2: Collect inputs using AskQuestion

Use the AskQuestion tool to collect ALL empty fields in a single interactive prompt. Include predefined options where listed above. Example:

```
AskQuestion with questions:
  - id: installer, prompt: "Installer type?", options: [{id: "none", label: "none (Recommended)"}, {id: "cp", label: "cluster-platforms"}, {id: "aws", label: "aws-ipi"}]
  - id: cluster_name, prompt: "Cluster name?"
  - id: apiserver, prompt: "Cluster API URL?"
  - id: password, prompt: "Kubeadmin password?"
  - id: version, prompt: "Operator version? (e.g., 1.23.0)"
  - id: environment, prompt: "Operator environment?", options: [{id: "pre-stage", label: "pre-stage (Recommended)"}, {id: "prod", label: "prod"}, {id: "stage", label: "stage"}]
  - id: tags, prompt: "Test scope?", options: [{id: "e2e", label: "e2e - full suite (Recommended)"}, {id: "sanity", label: "sanity - quick smoke"}]
  - id: framework, prompt: "Test framework?", options: [{id: "gauge", label: "gauge (Recommended)"}, {id: "ginkgo", label: "ginkgo"}]
  - id: index_image, prompt: "Konflux index image? (for pre-stage/stage, e.g., quay.io/openshift-pipeline/pipelines-index-4.21:v1.23.0)"
```

Only include questions for fields that are actually empty. Skip fields that already have values.

### Step 3: Write and verify (only after user provides values)

After the user provides values:
1. Write each value to `env/.env.acceptance` using file editing
2. Read the file back to confirm no required fields are still empty
3. If any are still empty, ask again

### Step 4: Run

```bash
ENV_FILE=env/.env.acceptance ./scripts/run-workflow.sh
```

---

## UI acceptance tests flow

### Step 1: Read and validate

Copy template if needed: `cp env/env.acceptance-ui.template env/.env.acceptance-ui`

Required fields (same cluster/operator as acceptance, plus UI-specific):

| # | Field | Default / notes |
|---|-------|-----------------|
| 1 | `CLUSTER_NAME` | Free text |
| 2 | `OPERATOR_VERSION` | e.g. 1.23.0 |
| 3 | `OPERATOR_ENVIRONMENT` | `pre-stage` (needs `KONFLUX_INDEX_IMAGE`) |
| 4 | `MARKERS` | `sanity` |
| 5 | `GIT_UI_TESTS_BRANCH` | Auto from OCP version via `ci-config.yaml` (or set explicitly) |

Optional: `APP_TIMEOUT` (default `90000`), `CAPTURE_SCREENSHOTS` (default `true`), `CAPTURE_RECORDINGS` (default `true`), `UPLOAD_RECORDINGS_ON_FAILURE` (default `false` — upload .webm to GCS only when tests fail; requires `CAPTURE_RECORDINGS=true`), `SETUP_TESTING_ACCOUNTS=false`, `UI_IMAGE=quay.io/openshift-pipeline/ui-ci:latest`

### Step 2: Run

Same provisioning model as acceptance (`run-workflow.sh`): `APISERVER` is the **management** cluster (Tekton host). Set `INSTALLER=aws-ipi` or `aro` to let the pipeline provision the **test** cluster; use `none` / `cluster-platforms` with an existing test cluster.

```bash
ENV_FILE=env/.env.acceptance-ui ./scripts/run-ui-workflow.sh
```

Or PipelineRun only (after setup):

```bash
ENV_FILE=env/.env.acceptance-ui ./scripts/hack/create-pipelinerun-ui.sh
```

### Step 5: Monitor and analyze

**While running**, poll status periodically:

```bash
oc get pipelinerun -n pipelines-ci --sort-by=.metadata.creationTimestamp -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[0].reason' | tail -3

oc get taskrun -n pipelines-ci -l tekton.dev/pipelineRun=<name> --sort-by=.metadata.creationTimestamp -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[0].reason'
```

**Once the PipelineRun finishes** (Succeeded or Failed), run the post-run analysis below.

### Step 6: Post-run analysis (after PipelineRun completes)

Use the Tekton MCP server if available (`tekton` server in MCP config). If MCP is not connected, fall back to `oc` commands.

**Analysis flow:**

1. **Get PipelineRun summary** — MCP: `get_pipelinerun(name, namespace="pipelines-ci")` or `oc`:

```bash
oc get pipelinerun -n pipelines-ci <name> -o jsonpath='{.status.conditions[0]}' | python3 -m json.tool
```

2. **List all TaskRuns with status** — MCP: `list_taskruns(namespace="pipelines-ci", label_selector="tekton.dev/pipelineRun=<name>")` or `oc`:

```bash
oc get taskrun -n pipelines-ci -l tekton.dev/pipelineRun=<name> \
  --sort-by=.metadata.creationTimestamp \
  -o custom-columns='TASK:.metadata.labels.tekton\.dev/pipelineTask,STATUS:.status.conditions[0].reason,START:.status.startTime,END:.status.completionTime,DURATION:.status.conditions[0].message'
```

3. **For FAILED tasks, get logs** — MCP: `get_taskrun_logs(name, namespace="pipelines-ci", tail=200)` or `oc`:

```bash
pod=$(oc get taskrun -n pipelines-ci <taskrun-name> -o jsonpath='{.status.podName}')
for step in $(oc get pod -n pipelines-ci "$pod" -o jsonpath='{.spec.containers[*].name}'); do
  echo "=== $step ==="
  oc logs -n pipelines-ci "$pod" -c "$step" --tail=50
done
```

4. **Present a summary report** with:
   - Overall result: Succeeded / Failed / timeout
   - Duration (start to completion)
   - Task-by-task breakdown: name, status, duration
   - For failures: root cause from logs, suggested fix from the Common Errors table
   - Pass/fail ratio (e.g., "14/16 tasks passed")

5. **If the run failed**, offer next actions via AskQuestion:

```
AskQuestion with questions:
  - id: next_action, prompt: "PipelineRun failed. What would you like to do?", options:
    - {id: "retry", label: "Retry the failed tasks (Recommended)"}
    - {id: "logs", label: "Show full logs for all failed tasks"}
    - {id: "restart", label: "Restart the entire PipelineRun"}
    - {id: "diagnose", label: "Deep-dive diagnose the failure"}
    - {id: "skip", label: "Skip — I'll handle it manually"}
```

If user picks "retry" and MCP is connected, use `restart_pipelinerun(name, namespace="pipelines-ci")`.

---

## Upgrade tests flow

### Step 1: Read and validate

Read `env/.env.upgrade`. Check these required fields:

| # | Field | Options / Input type |
|---|-------|---------------------|
| 1 | `INSTALLER` | Options: `none` (Recommended), `cluster-platforms`, `aws-ipi` |
| 2 | `CLUSTER_NAME` | Free text |
| 3 | `APISERVER` | Free text |
| 4 | `KUBEADMIN_PASSWORD` | Free text |
| 5 | `PRE_UPGRADE_VERSION` | Free text (e.g., 1.22.3) |
| 6 | `PRE_UPGRADE_OPERATOR_ENVIRONMENT` | Options: `prod` (Recommended), `pre-stage` |
| 7 | `PRE_UPGRADE_KONFLUX_INDEX_IMAGE` | Free text — only if pre-stage |
| 8 | `UPGRADE_VERSION` | Free text (e.g., 1.23.0) |
| 9 | `UPGRADE_OPERATOR_ENVIRONMENT` | Options: `pre-stage` (Recommended), `prod`, `stage` |
| 10 | `UPGRADE_KONFLUX_INDEX_IMAGE` | Free text — required for pre-stage/stage |

Auto-set:
- `PRE_UPGRADE_CATALOG_SOURCE`: `redhat-operators` if prod, `custom-operators` if pre-stage
- `UPGRADE_CATALOG_SOURCE`: `redhat-operators` if prod, `custom-operators` if pre-stage

### Step 2: Collect inputs using AskQuestion

Use AskQuestion to collect ALL empty fields interactively with predefined options. Only ask for fields that are empty.

### Step 3: Write, verify, run (only after user provides values)

```bash
ENV_FILE=env/.env.upgrade ./scripts/run-upgrade-tests.sh
```

### Step 4: Post-run analysis

Same as acceptance tests Step 6. Use Tekton MCP or `oc` to get PipelineRun summary, task statuses, failed task logs, and present a report with next-action options.

---

## Other operations

| Operation | Command |
|-----------|---------|
| Provision amd64 cluster | `./scripts/hack/provision-cluster-local.sh` |
| Provision arm64 cluster | `ARCH=arm64 ./scripts/hack/provision-cluster-local.sh` |
| Provision FIPS cluster | `FIPS=true ./scripts/hack/provision-cluster-local.sh` |
| Destroy cluster | `./scripts/hack/provision-cluster-local.sh --destroy` |
| Install operator | `CHANNEL=pipelines-1.23 CATALOG_SOURCE=custom-operators bash config/operators/install-pipelines.sh` |
| Uninstall operator | `bash config/operators/uninstall-pipelines.sh` |
| Cleanup PVCs | `./scripts/hack/cleanup-pipeline-pvcs.sh --finished` |
| Cleanup AWS | `./scripts/hack/cleanup-orphan-clusters.sh` |
| Configure MCP | `./scripts/hack/configure-mcp.sh` |

## Check test status

Prefer Tekton MCP tools when the `tekton` MCP server is connected. Fall back to `oc` commands otherwise.

### With Tekton MCP (preferred)

Use GetMcpTools to discover the `tekton` server, then:

| What | MCP tool | Key params |
|------|----------|------------|
| Latest runs | `list_pipelineruns` | `namespace="pipelines-ci"`, `limit=5` |
| Run details | `get_pipelinerun` | `name=<run>`, `namespace="pipelines-ci"` |
| Task statuses | `list_taskruns` | `namespace="pipelines-ci"`, `label_selector="tekton.dev/pipelineRun=<run>"` |
| Task details | `get_taskrun` | `name=<taskrun>`, `namespace="pipelines-ci"` |
| Task logs | `get_taskrun_logs` | `name=<taskrun>`, `namespace="pipelines-ci"`, `tail=200` |
| Restart run | `restart_pipelinerun` | `name=<run>`, `namespace="pipelines-ci"` |

### With oc (fallback)

```bash
# Latest pipeline runs
oc get pipelinerun -n pipelines-ci --sort-by=.metadata.creationTimestamp \
  -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[0].reason' | tail -5

# Task status for a run
oc get taskrun -n pipelines-ci -l tekton.dev/pipelineRun=<name> \
  --sort-by=.metadata.creationTimestamp \
  -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[0].reason'

# Logs for a failed task
pod=$(oc get taskrun -n pipelines-ci <taskrun-name> -o jsonpath='{.status.podName}')
oc logs -n pipelines-ci "$pod" -c step-run --tail=50
```

### Setup Tekton MCP

If the `tekton` MCP server is not connected, run:

```bash
./scripts/hack/configure-mcp.sh
```

Then restart the IDE. The script auto-detects the active cluster and writes `.claude/settings.json` (used by both Cursor and Claude Code).

## Common errors

| Error | Fix |
|-------|-----|
| `exec format error` on gauge-go | Wrong arch binary; delete gomod-cache PVC, retrigger |
| `ImagePullBackOff` on `registry.stage.redhat.io` | Run `create-secrets.sh` with Vault |
| `VpcLimitExceeded` | Run `cleanup-orphan-clusters.sh` |
| `InstalledStatus: False` | Restart stuck pods in openshift-pipelines |
| `kube:admin` auth error | Patch cluster secret: admin-name should be `kubeadmin` |
| Task timeout | Check go-mod-cache completed; verify GOCACHE usage |

## Auto-resolution

`ci-config.yaml` maps `OPERATOR_VERSION` to `CHANNEL` and `GIT_RELEASE_TESTS_BRANCH` automatically. For UI runs, `GIT_UI_TESTS_BRANCH` is resolved from OCP version (`OPENSHIFT_VERSION` or `oc get clusterversion`). Do not set these unless the user explicitly asks to override them.
