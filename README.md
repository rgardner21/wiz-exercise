# Wiz-style cloud security exercise — AWS

A deliberately vulnerable AWS environment, built with Terraform, plus a containerized
todo application on EKS that uses a self-managed MongoDB VM as its database.

The point of the exercise is to build misconfigurations on purpose, then show that
audit logging and cloud controls surface them. **Everything marked "INTENTIONAL" is a
finding you are meant to produce, not a mistake.**

---

## Read this before you deploy

This stack creates real, exploitable exposure: SSH open to the internet on a host
whose instance profile holds `AdministratorAccess`, and an S3 bucket that anyone on
the internet can list and read.

- Deploy into a **dedicated throwaway AWS account**, never a shared or production one.
- Put **no real data** in the database. The seeded rows are placeholder text.
- Set a **budget alarm** before applying. EKS, NAT, and an ALB run roughly $8–12 a day.
- **Tear it down** as soon as your walkthrough is recorded (`docs/TEARDOWN.md`).
- Consider narrowing `ssh_ingress_cidr` to your own `/32`. You keep the "SSH reachable
  from outside the VPC" finding and lose most of the real-world risk. The default is
  `0.0.0.0/0` because the brief asks for it.

Expect the host to be found and probed within minutes of coming up. That is normal for
this exercise and is itself good demo material in the GuardDuty findings.

---

## Architecture

```
                         Internet
                            │
        ┌───────────────────┼────────────────────────┐
        │                   │                        │
   SSH 22/tcp          ALB (internet-facing)     anonymous S3
   (INTENTIONAL)       Kubernetes Ingress        read + list
        │                   │                    (INTENTIONAL)
┌───────┼───────────────────┼────────────────────────┼────────┐
│ VPC 10.42.0.0/16          │                        │        │
│                           │                        │        │
│  PUBLIC SUBNETS           │                        │        │
│  ┌─────────────────┐   ┌──▼───┐                    │        │
│  │ MongoDB VM      │   │ ALB  │                    │        │
│  │ Ubuntu 20.04    │   └──┬───┘              ┌─────▼──────┐ │
│  │ MongoDB 4.4     │      │                  │ S3 backups │ │
│  │ AdministratorAccess    │                  │ public r+l │ │
│  └────────▲────────┘      │                  └─────▲──────┘ │
│           │ 27017         │                        │        │
│           │ (EKS nodes    │                   daily cron    │
│           │  only)        │                   mongodump     │
│  PRIVATE SUBNETS          │                        │        │
│  ┌────────┴───────────────▼───────────────┐        │        │
│  │ EKS managed nodes                      │────────┘        │
│  │  wiz-todo pods                         │                 │
│  │  ServiceAccount → cluster-admin        │                 │
│  │  MONGODB_URI from Secret (env var)     │                 │
│  └────────────────────────────────────────┘                 │
└──────────────────────────────────────────────────────────────┘

Observability: CloudTrail (multi-region, log validation, S3 data events)
               EKS control plane audit logs → CloudWatch
               VPC flow logs → CloudWatch
               GuardDuty · AWS Config rules · CloudWatch alarms → SNS
```

---

## Repository layout

```
app/                      Node.js + Express todo app
  Dockerfile              multi-stage build; copies wizexercise.txt into /app
  wizexercise.txt         PUT YOUR NAME HERE before the first build
  server.js               todo API + /api/status validation endpoint
  public/index.html       UI with a live proof panel
terraform/
  vpc.tf                  VPC, public/private subnets, NAT, flow logs
  eks.tf                  EKS in private subnets, ALB controller, ECR
  mongodb_vm.tf           outdated Ubuntu + MongoDB, public SSH, admin role
  s3_backups.tf           public-read + public-list backup bucket
  k8s_bootstrap.tf        namespace, mongo Secret, cluster-admin binding
  logging_cloudtrail.tf   control plane audit logging
  controls_preventative.tf
  controls_detective.tf
  github_oidc.tf          GitHub Actions roles, no static AWS keys
  templates/              MongoDB bootstrap + backup cron
k8s/                      Deployment, Service, Ingress, kustomization
.github/workflows/        iac.yml · app.yml · codeql.yml
docs/                     validation evidence, risk acceptance, teardown
```

---

## Deploy

### 0. Prerequisites

Terraform ≥ 1.6, AWS CLI v2, kubectl, Docker, and an SSH keypair:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/wizex -C wizex
```

### 1. Put your name in the image

```bash
echo "Your Full Name" > app/wizexercise.txt
```

Both pipelines fail if this still contains the placeholder.

### 2. Bootstrap remote state

```bash
aws s3api create-bucket --bucket YOUR-TFSTATE-BUCKET --region us-east-1
aws s3api put-bucket-versioning --bucket YOUR-TFSTATE-BUCKET \
  --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket YOUR-TFSTATE-BUCKET \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
aws dynamodb create-table --table-name YOUR-TFSTATE-LOCKS \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

### 3. First apply, from your workstation

The GitHub OIDC roles do not exist yet, so the first apply is local.

```bash
cd terraform
cp backend.hcl.example backend.hcl        # fill in
cp terraform.tfvars.example terraform.tfvars   # fill in
terraform init -backend-config=backend.hcl
terraform apply \
  -var="github_repository=rgardner21/wiz-exercise" \
  -var="ssh_public_key=$(cat ~/.ssh/wizex.pub)"
```

Roughly 20 minutes, mostly EKS. Confirm the SNS subscription email that arrives.

### 4. Hand the keys to GitHub

Add these **repository variables** (Settings → Secrets and variables → Actions → Variables):

| Variable | Value |
|---|---|
| `AWS_REGION` | your region |
| `AWS_PLAN_ROLE_ARN` | `terraform output github_actions_plan_role_arn` |
| `AWS_APPLY_ROLE_ARN` | `terraform output github_actions_apply_role_arn` |
| `AWS_APP_ROLE_ARN` | `terraform output github_actions_app_role_arn` |
| `ECR_REPOSITORY` | `terraform output ecr_repository_url` (path after the registry host) |
| `EKS_CLUSTER_NAME` | `terraform output eks_cluster_name` |
| `TF_STATE_BUCKET` | your state bucket |
| `TF_LOCK_TABLE` | your lock table |

And these **secrets**: `MONGO_SSH_PUBLIC_KEY`, `ALERT_EMAIL`.

Then create a `production` environment with required reviewers, so both pipelines
pause for approval before touching AWS.

### 5. Ship the app

Push to `main`. The app pipeline builds, verifies `wizexercise.txt`, scans, pushes to
ECR, deploys, and re-verifies the file inside the running pod. The ALB hostname lands
in the job summary.

---

## Requirement mapping

| Requirement | Where | Status |
|---|---|---|
| VM with 1+ year outdated Linux | `mongodb_vm.tf` — Ubuntu 20.04 (Apr 2020) | INTENTIONAL |
| MongoDB 1+ year outdated | `templates/mongo_bootstrap.sh.tftpl` — MongoDB 4.4, EOL Feb 2024 | INTENTIONAL |
| SSH exposed to the internet | `aws_security_group_rule.mongo_ssh_public` | INTENTIONAL |
| Overly permissive cloud permissions on the VM | `aws_iam_role_policy_attachment.mongo_admin` — `AdministratorAccess` | INTENTIONAL |
| DB reachable only from Kubernetes | `aws_security_group_rule.mongo_from_eks_nodes` — source is the EKS node SG | CONTROL |
| DB requires authentication | bootstrap enables `security.authorization`; app user is `readWrite` on one DB | CONTROL |
| Daily automated backups to object storage | `/etc/cron.d/mongo-backup` → `mongodump` → S3, 02:00 UTC daily | ✔ |
| Object storage public read + public list | `s3_backups.tf` — public access block off, `Principal: "*"` on `GetObject` and `ListBucket` | INTENTIONAL |
| Kubernetes cluster in a private subnet | `eks.tf` — node group `subnet_ids = module.vpc.private_subnets` | ✔ |
| MongoDB access via a Kubernetes env var | `k8s/deployment.yaml` — `MONGODB_URI` from `secretKeyRef` | ✔ |
| Container image contains `wizexercise.txt` | `app/Dockerfile` — `COPY wizexercise.txt /app/wizexercise.txt` | ✔ |
| Proof the file is in the running container | `docs/VALIDATION.md` + both pipeline verification steps | ✔ |
| Container app has cluster-admin | `kubernetes_cluster_role_binding_v1.app_cluster_admin` | INTENTIONAL |
| Exposed via Ingress + cloud load balancer | `k8s/ingress.yaml` → AWS ALB via the load balancer controller | ✔ |
| Control plane audit logging | `logging_cloudtrail.tf` (CSP) + EKS `cluster_enabled_log_types` (Kubernetes) | ✔ |
| At least one preventative control | `controls_preventative.tf` — 5 implemented | ✔ |
| At least one detective control | `controls_detective.tf` — GuardDuty, 8 Config rules, 5 alarms | ✔ |
| Code in VCS | this repository | ✔ |
| IaC CI/CD pipeline | `.github/workflows/iac.yml` | ✔ |
| Container build + deploy pipeline | `.github/workflows/app.yml` | ✔ |
| Pipeline and repo security controls | `docs/REPO-SECURITY.md` | ✔ |

### Controls in detail

**Preventative** (stop the bad state from being created)

1. `aws_ebs_encryption_by_default` — every new EBS volume in the region is encrypted, no opt-out.
2. IAM permissions boundary that denies stopping CloudTrail/Config/GuardDuty and denies
   exposing or deleting the audit log bucket, demonstrated on a bounded admin role.
3. IMDSv2 required (`http_tokens = "required"`) on the MongoDB VM and all EKS nodes,
   with hop limit 1 — this is what stops an SSRF from walking off with that
   `AdministratorAccess` credential.
4. Public access block enforced on the CloudTrail and Config buckets.
5. Account password policy: 14 characters, complexity, 90-day rotation, 12-password history.

**Detective** (find the bad state after the fact)

1. GuardDuty, findings ≥ Medium routed to SNS via EventBridge.
2. AWS Config recorder with 8 managed rules. Four should evaluate NON_COMPLIANT against
   the intentional findings; four confirm the preventative controls hold.
3. Five CloudWatch metric filters and alarms on the CloudTrail log group: unauthorized
   API calls, root account usage, security group changes, IAM policy changes, and
   anonymous S3 access to the backup bucket.
4. VPC flow logs to CloudWatch, feeding GuardDuty's network analysis.

---

## Demo script

1. Open the ALB URL. The status panel shows the pod name, the MongoDB server version
   (4.4.x — outdated), and the contents of `wizexercise.txt`.
2. `kubectl exec` into the pod and `cat /app/wizexercise.txt` (`docs/VALIDATION.md`).
3. From the pod, `kubectl auth can-i '*' '*' --all-namespaces` returns `yes` — cluster-admin
   on an internet-facing workload.
4. Open the public bucket URL in a logged-out browser. Anonymous listing, then download a
   `mongodump` archive.
5. SSH to the VM, `curl` IMDS without a token (blocked — IMDSv2), then with a token, and
   show the `AdministratorAccess` role.
6. Show CloudTrail recording all of the above, the NON_COMPLIANT Config rules, and the
   GuardDuty findings and alarm emails.
7. Tear it down.

Further reading: `docs/VALIDATION.md`, `docs/REPO-SECURITY.md`,
`docs/RISK-ACCEPTANCE.md`, `docs/TEARDOWN.md`.
