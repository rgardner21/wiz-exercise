# RUNBOOK1 — Portable deployment guide

A rebuild-anywhere version of the Wiz exercise runbook. Every account-specific
value is a parameter set once in Phase A; nothing downstream is hardcoded.

**What changed from RUNBOOK.md**

- Laptop/tool installation removed (Homebrew, VSCode, CLI installs). Docker setup
  is kept — the architecture flag is the single most common cause of a
  crash-looping pod.
- AWS account preparation (root MFA, budgets, creating the IAM user) removed. In
  someone else's sandbox you are handed credentials; you don't build the account.
- Added Phase A preflight, because the exercise needs an account that permits a
  **public S3 bucket**, and many sandboxes forbid exactly that.
- All identifiers are derived from `sts get-caller-identity` or from your
  parameter file.

**Assumed already installed:** `aws` v2, `terraform` ≥ 1.6, `kubectl`, `helm`,
`docker`, `gh`, `jq`. Verify in one line:

```bash
aws --version && terraform -version && kubectl version --client && \
  helm version --short && docker --version && gh --version && jq --version
```

---

## Phase A — Preflight: can this account host the exercise?

Run this **before** you spend 25 minutes building an EKS cluster. Each check
below maps to something that has to be true; the appendix explains what to do
when one fails.

### A.1 Confirm which account you are in

```bash
export AWS_PROFILE=<the profile for the target account>
aws sts get-caller-identity
```

Read the `Account` and `Arn` back and make sure it is the account you intend to
build in. Everything from here derives from this identity.

> If the sandbox gives you SSO rather than an access key:
> `aws configure sso --profile <name>` then `aws sso login --profile <name>`.
> The rest of the runbook is unchanged — only how the profile authenticates
> differs.

### A.2 Run the preflight script

Save as `preflight.sh`, `chmod +x preflight.sh`, run it. It only reads.

```bash
#!/usr/bin/env bash
# Preflight for the Wiz exercise. Read-only. Non-zero exit = blocker found.
set -uo pipefail
REGION="${REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) || exit 1
FAIL=0
note() { printf '  %-8s %s\n' "$1" "$2"; }

echo "Account $ACCOUNT_ID / region $REGION"

echo "[1] Account-level S3 Block Public Access"
BPA=$(aws s3control get-public-access-block --account-id "$ACCOUNT_ID" \
        --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,BlockPublicPolicy,IgnorePublicAcls,RestrictPublicBuckets]' \
        --output text 2>/dev/null)
if [ -z "$BPA" ]; then
  note OK "no account-level block (bucket-level settings will apply)"
elif echo "$BPA" | grep -qi true; then
  note BLOCKER "account-level BPA is ON -> $BPA"
  note ""      "the exercise requires a public backup bucket; see Appendix 1"
  FAIL=1
else
  note OK "account-level BPA present but all false"
fi

echo "[2] GuardDuty detector already present?"
D=$(aws guardduty list-detectors --region "$REGION" --query 'DetectorIds' --output text 2>/dev/null)
[ -n "$D" ] && { note CONFLICT "detector $D exists -> import or skip (Appendix 2)"; FAIL=1; } \
            || note OK "none; Terraform will create one"

echo "[3] Config recorder already present? (max 1 per region)"
R=$(aws configservice describe-configuration-recorders --region "$REGION" \
      --query 'ConfigurationRecorders[].name' --output text 2>/dev/null)
[ -n "$R" ] && { note CONFLICT "recorder '$R' exists -> import or skip (Appendix 2)"; FAIL=1; } \
            || note OK "none; Terraform will create one"

echo "[4] GitHub OIDC provider already present? (max 1 per URL per account)"
P=$(aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text 2>/dev/null \
      | tr '\t' '\n' | grep -i 'token.actions.githubusercontent.com')
[ -n "$P" ] && { note CONFLICT "$P exists -> import or skip (Appendix 2)"; FAIL=1; } \
            || note OK "none; Terraform will create one"

echo "[5] Availability zones (EKS needs >= 2, this build uses 3)"
AZ=$(aws ec2 describe-availability-zones --region "$REGION" \
       --query 'length(AvailabilityZones[?State==`available`])' --output text 2>/dev/null)
[ "${AZ:-0}" -ge 3 ] && note OK "$AZ available" || { note BLOCKER "only ${AZ:-0} AZs"; FAIL=1; }

echo "[6] Quotas"
q() { aws service-quotas get-service-quota --service-code "$1" --quota-code "$2" \
        --region "$REGION" --query 'Quota.Value' --output text 2>/dev/null; }
EIP=$(q ec2 L-0263D0A3); VCPU=$(q ec2 L-1216C47A); VPC=$(q vpc L-F678F1CE)
awk -v v="${EIP:-0}" 'BEGIN{exit !(v>=5)}'  && note OK "Elastic IPs ${EIP:-?} (need 3)"  || { note BLOCKER "Elastic IPs ${EIP:-?} < 5"; FAIL=1; }
awk -v v="${VCPU:-0}" 'BEGIN{exit !(v>=8)}' && note OK "vCPUs ${VCPU:-?} (need ~6)"      || { note BLOCKER "vCPU quota ${VCPU:-?} < 8"; FAIL=1; }
awk -v v="${VPC:-0}" 'BEGIN{exit !(v>=1)}'  && note OK "VPCs ${VPC:-?}"                  || note WARN "check VPC quota"

echo "[7] Can we create IAM roles? (dry probe)"
aws iam get-account-summary >/dev/null 2>&1 \
  && note OK "IAM readable — confirm create rights with Appendix 3 if unsure" \
  || { note BLOCKER "cannot read IAM; the deploy roles cannot be created"; FAIL=1; }

echo
[ "$FAIL" -eq 0 ] && echo "PREFLIGHT PASSED" || echo "PREFLIGHT FOUND ISSUES — read the appendix before building"
exit $FAIL
```

```bash
REGION=us-east-1 ./preflight.sh
```

**Check:** `PREFLIGHT PASSED`. Anything else — resolve it now. A Config-recorder
collision surfaces 20 minutes into `apply`, after the cluster is already built
and billing.

### A.3 Time and cost awareness

A full build is roughly **30–40 minutes** (EKS control plane ~15, node group ~5,
ALB ~5). Sandbox accounts are often reaped on a timer — confirm you have a
window. Rough run rate is **$0.30–0.40/hour** (EKS control plane $0.10, 2×
t3.medium, t3.small, NAT gateways, ALB). NAT gateways dominate if you leave it
running.

---

## Phase B — Set your deployment parameters

This is the file you edit per account. Everything else reads from it.

```bash
cd <your clone of the repo>
cat > deploy.env <<'EOF'
# ---- edit these ----
export AWS_PROFILE=default                     # profile for the TARGET account
export REGION=us-east-1
export PROJECT=wizex                           # prefix for every resource name
export GITHUB_REPOSITORY=<owner>/<repo>        # owner/name that may assume the deploy roles
export ALERT_EMAIL=<an inbox you can open>     # SNS confirmation lands here
export SSH_KEY_PATH="$HOME/.ssh/wizex"         # created below if missing
export SSH_INGRESS_CIDR=0.0.0.0/0              # exercise asks for this; see note
# ---- derived; leave alone ----
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export TFSTATE_BUCKET="${PROJECT}-tfstate-${ACCOUNT_ID}"
export TFLOCK_TABLE="${PROJECT}-tfstate-locks"
EOF

source deploy.env
echo "$ACCOUNT_ID / $REGION / $TFSTATE_BUCKET"
```

`deploy.env` holds an email address and possibly your IP — **it must never be
committed.** Confirm it is ignored:

```bash
grep -qxF 'deploy.env' .gitignore || echo 'deploy.env' >> .gitignore
git check-ignore -v deploy.env
```

**On `SSH_INGRESS_CIDR`:** the brief asks for `0.0.0.0/0`, and that is what
produces the finding. While building, `"$(curl -s ifconfig.me)/32"` gives you the
same finding with far less exposure — a public MongoDB 4.4 host is found by
scanners within minutes. Widen it before recording. Whichever you choose, it goes
in `deploy.env`, never in a committed file.

### B.1 SSH key

```bash
[ -f "$SSH_KEY_PATH" ] || ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -C "$PROJECT" -N ""
ssh-keygen -l -f "${SSH_KEY_PATH}.pub"
```

A key from a previous account is fine to reuse, but a fresh one per engagement is
cleaner — you can hand over or destroy it without touching your own keys.

### B.2 Repo-owned identifiers

Two committed files name a specific GitHub owner. Update them when the repo moves:

```bash
sed -i '' "s|@[A-Za-z0-9-]*|@${GITHUB_REPOSITORY%%/*}|g" .github/CODEOWNERS
grep -n '@' .github/CODEOWNERS
```

`terraform/locals.tf` tags everything with `Owner`. Change it if the resources
should not carry your name:

```bash
grep -n 'Owner' terraform/locals.tf
```

---

## Phase C — Docker readiness

Kept from the original because this is where an Apple-silicon laptop bites.

```bash
docker run --rm hello-world
```

"Cannot connect to the Docker daemon" means Docker Desktop isn't running.

```bash
uname -m           # arm64 on Apple silicon
docker buildx ls   # need linux/amd64 in the platform list
```

If only `linux/arm64` appears, register the emulator:

```bash
docker run --privileged --rm tonistiigi/binfmt --install amd64
docker buildx create --name wizbuilder --use --bootstrap
docker buildx ls
```

The cluster runs amd64 nodes. Building arm64 produces a pod that crash-loops with
`exec format error` — and the image pulls and starts, so it looks like an app bug
rather than an architecture mismatch. Build amd64 everywhere and there is one
architecture in play end to end.

**Check:** `docker buildx ls` lists `linux/amd64`.

---

## Phase D — Bootstrap the Terraform state backend

Created by hand because Terraform cannot store its own state in a bucket it has
not created yet. Names come from `deploy.env`, so this is account-safe.

```bash
source deploy.env

if [ "$REGION" = "us-east-1" ]; then
  aws s3api create-bucket --bucket "$TFSTATE_BUCKET" --region "$REGION"
else
  aws s3api create-bucket --bucket "$TFSTATE_BUCKET" --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION"
fi

aws s3api put-bucket-versioning --bucket "$TFSTATE_BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-public-access-block --bucket "$TFSTATE_BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

aws dynamodb create-table --table-name "$TFLOCK_TABLE" --region "$REGION" \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

`us-east-1` must **not** get a `LocationConstraint` — passing it there is an
error, which is why the conditional exists.

This state bucket is locked down hard, unlike the backup bucket the exercise asks
you to expose. That contrast is worth a sentence in your walkthrough.

**Check:**

```bash
aws s3 ls | grep "$TFSTATE_BUCKET"
aws dynamodb describe-table --table-name "$TFLOCK_TABLE" --region "$REGION" \
  --query 'Table.TableStatus'
```

---

## Phase E — Configure Terraform

Generate both config files from `deploy.env` rather than editing templates by
hand. Editing `.example` files instead of the real ones is the single easiest
mistake to make here, and it fails in confusing ways much later.

```bash
source deploy.env
cd terraform

cat > backend.hcl <<EOF
bucket         = "${TFSTATE_BUCKET}"
key            = "wiz-exercise/terraform.tfstate"
region         = "${REGION}"
dynamodb_table = "${TFLOCK_TABLE}"
encrypt        = true
EOF

cat > terraform.tfvars <<EOF
region            = "${REGION}"
project           = "${PROJECT}"
alert_email       = "${ALERT_EMAIL}"
github_repository = "${GITHUB_REPOSITORY}"
ssh_public_key    = "$(cat "${SSH_KEY_PATH}.pub")"
ssh_ingress_cidr  = "${SSH_INGRESS_CIDR}"
EOF

cat backend.hcl terraform.tfvars
```

Both are gitignored. Confirm before continuing:

```bash
git check-ignore -v backend.hcl terraform.tfvars
```

Then initialize:

```bash
terraform init -reconfigure -backend-config=backend.hcl
```

`-reconfigure` matters when moving between accounts — it discards the cached
backend from the previous account instead of trying to migrate state into the new
bucket.

> A `dynamodb_table is deprecated, use use_lockfile` warning is expected on
> Terraform ≥ 1.11 and is cosmetic. It prints to stderr, so `$(terraform output
> -raw ...)` still captures clean values.

**Check:** ends with "Terraform has been successfully initialized!"

---

## Phase F — Build the infrastructure

Two passes on purpose. The Kubernetes and Helm providers must connect to a
cluster that does not exist yet; one-shot produces a confusing "Provider
configuration is unknown".

### F.1 Network and cluster (~20 min)

```bash
terraform apply -target=module.vpc -target=module.eks
```

Ignore the yellow "Resource targeting is in effect" warning — a partial apply is
exactly the intent.

### F.2 Everything else (~5 min)

```bash
terraform apply
```

Creates the MongoDB VM, the public backup bucket, CloudTrail, GuardDuty, Config,
alarms, ECR, the GitHub OIDC roles, and the Kubernetes namespace/secret/binding.

### F.3 Confirm the alert email

Open the inbox for `ALERT_EMAIL` and click the "AWS Notification - Subscription
Confirmation" link. Unconfirmed, the topic stays `PendingConfirmation` and no
detective-control alert ever fires — half the demo.

```bash
aws sns list-subscriptions --region "$REGION" \
  --query "Subscriptions[?contains(TopicArn,'${PROJECT}')].[Endpoint,SubscriptionArn]" --output table
```

A real ARN rather than `PendingConfirmation` means it is confirmed.

### F.4 Capture the outputs

```bash
terraform output
terraform output -json > ../outputs-${ACCOUNT_ID}.json
```

Keep the JSON — the IPs and ARNs change with every account, and it saves
re-deriving them for evidence. It contains account identifiers, so treat it as
local-only:

```bash
grep -qxF 'outputs-*.json' ../.gitignore || echo 'outputs-*.json' >> ../.gitignore
```

---

## Phase G — Verify the MongoDB VM

```bash
source deploy.env
cd terraform
MONGO_IP=$(terraform output -raw mongodb_public_ip)
ssh -i "$SSH_KEY_PATH" ubuntu@"$MONGO_IP"
```

On the box:

```bash
systemctl status mongod --no-pager
mongo --quiet --eval 'db.version()'
curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/   # IMDSv2 should refuse
```

Bootstrap is cloud-init; if Mongo is not up yet, watch `/var/log/cloud-init-output.log`.

---

## Phase H — Build and deploy the application

### H.1 kubectl

```bash
source deploy.env
aws eks update-kubeconfig --region "$REGION" \
  --name "$(terraform -chdir=terraform output -raw eks_cluster_name)"
kubectl get nodes
```

Two `Ready` nodes, no external IPs — they are in private subnets, as required.

> **Identity matters.** The principal that created the cluster gets admin via
> `enable_cluster_creator_admin_permissions`. If you build with one role and
> later use another, `kubectl` returns `Unauthorized` — see Appendix 4.

### H.2 Log Docker in to ECR

```bash
export ECR_URL=$(terraform -chdir=terraform output -raw ecr_repository_url)
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "${ECR_URL%%/*}"
```

`${ECR_URL%%/*}` trims to the registry host, which is what `docker login` wants.

### H.3 Build amd64 and push

The `--platform` flag is not optional:

```bash
docker buildx build --platform linux/amd64 -t "$ECR_URL:v1" --push app/
```

Images are **not** portable between accounts — ECR is per-account, so this
rebuild-and-push is required every time you move, even if the code is identical.

### H.4 Prove `wizexercise.txt` is in the image

```bash
docker run --rm --platform linux/amd64 --entrypoint sh "$ECR_URL:v1" \
  -c 'ls -l /app/wizexercise.txt && cat /app/wizexercise.txt'
docker image inspect "$ECR_URL:v1" --format '{{.Architecture}}'   # must say amd64
```

Screenshot the `cat`. Evidence item one: baked into a layer, not mounted.

### H.5 Deploy

```bash
cd k8s
kubectl kustomize . | sed "s|PLACEHOLDER_IMAGE:latest|$ECR_URL:v1|g" | kubectl apply -f -
kubectl -n wiz-todo rollout status deployment/wiz-todo --timeout=5m
cd ..
```

Namespace, Mongo secret, service account and cluster-admin binding already exist
from Phase F.

### H.6 Reach the app

```bash
export ALB=$(kubectl -n wiz-todo get ingress wiz-todo \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "http://$ALB"
```

`ADDRESS` takes 2–3 minutes to appear and another 2–3 before it serves traffic. A
`503` during that window is normal; a `503` that persists means no healthy targets
— check `kubectl -n wiz-todo get pods` first.

**Check:**

```bash
curl -s "http://$ALB/wizexercise.txt"
curl -s "http://$ALB/api/status" | jq
POD=$(kubectl -n wiz-todo get pods -l app.kubernetes.io/name=wiz-todo \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n wiz-todo exec "$POD" -- cat /app/wizexercise.txt
kubectl -n wiz-todo exec "$POD" -- printenv MONGODB_URI
```

`/api/status` should read `"database":"connected"` with `databaseVersion` showing
`4.4.x`. That outdated version is deliberate evidence — if it shows
`"database":"error"`, see Appendix 5.

---

## Phase I — CI/CD

### I.1 Point `gh` at the right repo

```bash
source deploy.env
gh auth status
gh repo set-default "$GITHUB_REPOSITORY"
```

### I.2 Variables and secrets

Re-run in full for every new account — the role ARNs embed the account ID, so
stale values cause OIDC failures that look like permission problems.

```bash
cd terraform
gh variable set AWS_REGION          --body "$REGION"
gh variable set AWS_PLAN_ROLE_ARN   --body "$(terraform output -raw github_actions_plan_role_arn)"
gh variable set AWS_APPLY_ROLE_ARN  --body "$(terraform output -raw github_actions_apply_role_arn)"
gh variable set AWS_APP_ROLE_ARN    --body "$(terraform output -raw github_actions_app_role_arn)"
gh variable set EKS_CLUSTER_NAME    --body "$(terraform output -raw eks_cluster_name)"
gh variable set TF_STATE_BUCKET     --body "$TFSTATE_BUCKET"
gh variable set TF_LOCK_TABLE       --body "$TFLOCK_TABLE"
gh variable set ECR_REPOSITORY      --body "${PROJECT}/wiz-todo"
cd ..

gh secret set MONGO_SSH_PUBLIC_KEY --body "$(cat "${SSH_KEY_PATH}.pub")"
gh secret set ALERT_EMAIL          --body "$ALERT_EMAIL"

gh variable list
```

`ECR_REPOSITORY` is the repository **name only**, not the full URL — the workflow
builds the path from the registry host it gets at login.

No AWS keys are stored. The workflows exchange a short-lived GitHub OIDC token for
temporary credentials, and the trust policy accepts only your repo, on `main` or
the `production` environment.

### I.3 Environment gate (browser)

`https://github.com/<owner>/<repo>/settings/environments` → **New environment** →
name it exactly `production` → **Configure**:

- **Required reviewers**: add yourself
- **Deployment branches**: Selected branches → `main`

The name must match exactly; the workflow and the IAM trust policy both reference
`production`, and a typo surfaces as an AWS auth error.

### I.4 Branch protection (browser)

`Settings` → `Branches` → pattern `main`: require a PR (1 approval), Code Owners
review, status checks `Static analysis` / `Terraform plan` / `Build and scan
image`, conversation resolution, block force pushes and deletions.

Enable this **last**. It blocks the direct pushes the earlier phases rely on.
Solo on the repo, "require 1 approval" means you cannot merge your own PR —
either add a collaborator or leave "Do not allow bypassing" unticked. Say which
you chose in the walkthrough; it is a real trade-off, not an oversight.

### I.5 Scanning

`Settings` → `Code security and analysis`: secret scanning, push protection,
Dependabot alerts, Dependabot security updates.

### I.6 Prove the pipelines

```bash
git checkout -b test-pipelines
git commit -am "Test the pipelines" --allow-empty
git push -u origin test-pipelines
gh pr create --fill
gh pr checks --watch
```

---

## Phase J — Evidence

Recollect for **every** account — IPs, ARNs and bucket URLs all change.

```bash
source deploy.env
cd terraform && terraform output -json > ../outputs-${ACCOUNT_ID}.json && cd ..
```

| Evidence | Command |
|---|---|
| File in the image | `docker run --rm --entrypoint sh "$ECR_URL:v1" -c 'cat /app/wizexercise.txt'` |
| File in the pod | `kubectl -n wiz-todo exec "$POD" -- cat /app/wizexercise.txt` |
| DB credential via env | `kubectl -n wiz-todo exec "$POD" -- printenv MONGODB_URI` |
| Outdated MongoDB | `curl -s "http://$ALB/api/status" \| jq .databaseVersion` |
| Public bucket | `curl -s --no-sign-request "$(terraform -chdir=terraform output -raw mongodb_backup_bucket_public_url)"` |
| Over-permissive pod | `kubectl -n wiz-todo get clusterrolebinding \| grep wiz` |
| SSH open to world | `terraform -chdir=terraform output -raw mongodb_public_ip` + the SG rule |
| Detective controls | GuardDuty findings, Config non-compliant rules, CloudTrail events |

---

## Phase K — Teardown

Do this before the sandbox window closes; a reaped account leaves orphaned state.

```bash
source deploy.env
cd terraform

kubectl delete ingress wiz-todo -n wiz-todo --ignore-not-found   # release the ALB first
terraform destroy

cd ..
aws s3 rm "s3://${TFSTATE_BUCKET}" --recursive
aws s3api delete-bucket --bucket "$TFSTATE_BUCKET" --region "$REGION"
aws dynamodb delete-table --table-name "$TFLOCK_TABLE" --region "$REGION"
```

Delete the ingress first — a Terraform-destroyed cluster can strand an ALB and
its security groups, which then blocks VPC deletion.

Confirm nothing is left billing:

```bash
aws ec2 describe-instances --region "$REGION" \
  --filters "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Project`].Value|[0]]' --output table
aws eks list-clusters --region "$REGION"
aws elbv2 describe-load-balancers --region "$REGION" --query 'LoadBalancers[].LoadBalancerName'
```

---

## Appendix 1 — Account-level S3 Block Public Access

The exercise **requires** a publicly readable backup bucket. If account-level BPA
is on, `RestrictPublicBuckets` overrides any bucket policy and the bucket stays
private — `terraform apply` may still succeed, so the finding silently fails to
appear.

```bash
aws s3control get-public-access-block --account-id "$ACCOUNT_ID"
```

If it is on, you have three options:

1. **Ask the account owner to disable it** for the duration. In a shared sandbox
   this is a real change to their security posture — ask, do not assume.
   `aws s3control delete-public-access-block --account-id "$ACCOUNT_ID"`
2. **Check whether an SCP enforces it.** If so, you cannot turn it off from inside
   the account at all, and this account cannot host the exercise as written.
3. **Document the deviation.** Build everything else and explain in the
   walkthrough that public exposure was demonstrated by bucket policy but blocked
   by a compensating account control. That is a defensible answer — arguably a
   better one — but decide deliberately rather than discovering it live.

---

## Appendix 2 — Singleton collisions

These are one-per-account (or one-per-region) resources. If the target account
already has one, `apply` fails partway.

| Resource | Symptom | Fix |
|---|---|---|
| GuardDuty detector | `detector already exists` | `terraform import aws_guardduty_detector.this <id>` |
| Config recorder | `MaxNumberOfConfigurationRecordersExceededException` | `terraform import aws_config_configuration_recorder.this default` |
| GitHub OIDC provider | `EntityAlreadyExists` | `terraform import aws_iam_openid_connect_provider.github <arn>` |
| CloudTrail | usually fine (5 per account) | rename via `PROJECT` if it collides |

Import IDs:

```bash
aws guardduty list-detectors --region "$REGION" --query 'DetectorIds[0]' --output text
aws configservice describe-configuration-recorders --region "$REGION" --query 'ConfigurationRecorders[0].name' --output text
aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[?contains(Arn,'githubusercontent')].Arn" --output text
```

Importing adopts a resource you did not create — and `terraform destroy` will then
**delete it**, disabling security tooling that predates you. In someone else's
account, prefer removing the resource from the config for that run over importing
it, and say so in the walkthrough.

---

## Appendix 3 — Insufficient IAM permissions

Terraform needs to create IAM roles and policies. Sandboxes often restrict this,
sometimes requiring a permission boundary on every role. Symptoms are
`AccessDenied` on `iam:CreateRole`, or `explicit deny in a service control policy`.

```bash
aws iam simulate-principal-policy \
  --policy-source-arn "$(aws sts get-caller-identity --query Arn --output text)" \
  --action-names iam:CreateRole iam:AttachRolePolicy ec2:RunInstances eks:CreateCluster \
  --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output table
```

Any `implicitDeny`/`explicitDeny` needs resolving with the account owner before
you build. If a permission boundary is mandated, every `aws_iam_role` needs
`permissions_boundary` — a code change, so raise it early.

---

## Appendix 4 — `kubectl` returns Unauthorized

The cluster creator gets admin. Switching principals loses access.

```bash
aws sts get-caller-identity                      # who am I now?
aws eks list-access-entries --cluster-name "$(terraform -chdir=terraform output -raw eks_cluster_name)" --region "$REGION"
```

Re-run with the creating profile, or grant your current principal:

```bash
aws eks create-access-entry --cluster-name <cluster> --region "$REGION" \
  --principal-arn "$(aws sts get-caller-identity --query Arn --output text)"
aws eks associate-access-policy --cluster-name <cluster> --region "$REGION" \
  --principal-arn "$(aws sts get-caller-identity --query Arn --output text)" \
  --access-scope type=cluster \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy
```

Most likely when the sandbox hands you a federated/SSO role whose ARN changes
between sessions.

---

## Appendix 5 — Pod and app failures

| Symptom | Cause | Fix |
|---|---|---|
| `CreateContainerConfigError`, "non-numeric user" | image sets `USER` by name; `runAsNonRoot` needs a numeric UID | `runAsUser`/`runAsGroup` are already set in `k8s/deployment.yaml` |
| `exec format error` / crash-loop | arm64 image on amd64 nodes | rebuild with `--platform linux/amd64` (Phase C) |
| Persistent `503` from ALB | no healthy targets | `kubectl -n wiz-todo get pods` and `get endpoints` — empty endpoints means no running pods |
| `"database":"error"`, version `null` | app user lacks `clusterMonitor` on `admin` for `serverStatus` | granted at bootstrap in `mongo_bootstrap.sh.tftpl`; if the VM predates that change, re-grant or rebuild the VM |
| Pods `Pending` | insufficient node capacity or vCPU quota | check quotas (Phase A) |

---

## Appendix 6 — Account-move checklist

Everything that must change when moving to a new account. Miss one and the failure
usually appears far from its cause.

- [ ] `AWS_PROFILE` points at the new account; `aws sts get-caller-identity` confirms it
- [ ] Phase A preflight passes (**S3 BPA is the common blocker**)
- [ ] `deploy.env` rewritten; `ACCOUNT_ID` re-derived, not copied
- [ ] New state bucket + lock table (never share state across accounts)
- [ ] `terraform init -reconfigure` (not plain `init`)
- [ ] `backend.hcl` and `terraform.tfvars` regenerated from `deploy.env`
- [ ] Image rebuilt and pushed to the **new** account's ECR
- [ ] `kubeconfig` updated for the new cluster
- [ ] All GitHub variables re-set — role ARNs embed the account ID
- [ ] `production` environment and branch protection exist on the target repo
- [ ] `CODEOWNERS` names the new repo owner
- [ ] SNS subscription confirmed in the new account
- [ ] Evidence recollected (IPs, bucket URLs, ARNs are all new)
- [ ] Old account torn down, including state bucket and lock table
