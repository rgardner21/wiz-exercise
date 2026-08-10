# Runbook — start to finish, assuming you've never done this

Written for: macOS, VSCode with Claude Code, Docker Desktop, AWS account
`<YOUR_ACCOUNT_ID>` (new and empty), working as the IAM user `RanchHand1`.

Total time: about 2 hours of wall clock, of which ~35 minutes is waiting on AWS.
Cost while it's up: roughly $8–12 per day, almost all of it EKS, NAT Gateway, and
the load balancer.

Work through the phases in order. Each one ends with a check — if the check
fails, don't move on, fix it there. The troubleshooting appendix at the bottom
covers the failures that actually happen.

---

## Three gotchas specific to your setup

Read these now, because each one costs an hour if you hit it blind.

**1. Your M4 builds the wrong CPU architecture by default.** The M4 is ARM, so
`docker build` produces an `arm64` image. The EKS worker nodes are `x86_64`
(amd64). An arm64 image on an amd64 node crashes with `exec format error` and
the pod sits in `CrashLoopBackOff` forever — the logs won't say why, because the
process never starts. Every `docker build` and `docker run` in this runbook
carries `--platform linux/amd64`. Don't drop the flag; it is the difference
between a working deploy and an hour of confused debugging.

**2. A brand-new AWS account may have a 5 vCPU limit.** This stack needs 6:
two `t3.medium` worker nodes (2 vCPU each) plus one `t3.small` (2 vCPU). If your
quota is 5, the node group fails to scale and Terraform hangs for 20 minutes
before erroring. Phase 1 checks this and requests an increase if needed —
approval can take a few hours, so do it first.

**3. GitHub's free tier only gives you code scanning on public repos.** The
pipelines upload Checkov, Trivy, and CodeQL results to GitHub's Security tab.
On a free **private** repo those upload steps fail. Phase 3 covers both options.

---

## Phase 0 — Install the tools on your Mac

Open Terminal (or the terminal inside VSCode: `` Ctrl+` ``).

### 0.1 Homebrew

Homebrew is the package manager everything else installs through. Check if you
already have it:

```bash
brew --version
```

If that says "command not found":

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

At the end it prints two or three commands starting with `eval` — run them, or
Homebrew won't be on your PATH.

### 0.2 The rest

```bash
brew install awscli terraform kubectl helm jq git gh
```

- `awscli` — talks to AWS from the command line
- `terraform` — builds the infrastructure from the code in `terraform/`
- `kubectl` — talks to the Kubernetes cluster
- `helm` — Terraform uses it to install the load balancer controller
- `jq` — formats JSON output so you can read it
- `gh` — GitHub's command line tool

### 0.3 Docker Desktop

Make sure Docker Desktop is running (whale icon in the menu bar). Then:

```bash
docker run --rm hello-world
```

If that prints a greeting, Docker works. If it says "Cannot connect to the
Docker daemon", Docker Desktop isn't running — open it from Applications and
wait for the whale to stop animating.

### 0.4 Enable cross-architecture builds

Your M4 reports `arm64`:

```bash
uname -m      # arm64
```

Docker Desktop can still produce amd64 images by emulating that architecture,
but only if the emulator is registered. Docker Desktop normally does this for
you — confirm it:

```bash
docker buildx ls
```

Look for a builder whose platforms include `linux/amd64`. If you only see
`linux/arm64`, register the emulator:

```bash
docker run --privileged --rm tonistiigi/binfmt --install amd64
docker buildx create --name wizbuilder --use --bootstrap
docker buildx ls
```

Expect the amd64 image build to take a few minutes rather than seconds. That's
the emulation tax, and it only applies to builds on your laptop — GitHub's
runners are amd64, so the pipeline builds at full speed.

> Worth knowing why we don't just switch the cluster to ARM nodes and build
> natively: that would make your local builds fast and the pipeline builds slow,
> since the runners would then be the ones emulating. Building amd64 everywhere
> keeps one architecture in play end to end, which is one less thing to explain
> when something crash-loops.

**Check:** every one of these prints a version, and `docker buildx ls` lists
`linux/amd64` among the supported platforms.

```bash
aws --version && terraform -version && kubectl version --client && \
  helm version --short && docker --version && gh --version
```

---

## Phase 1 — Prepare the AWS account

You'll log in as root exactly once, do four things, then never use root again.

### 1.1 Sign in as root

Go to the AWS console and sign in with the root email for account
`<YOUR_ACCOUNT_ID>`.

### 1.2 Turn on MFA for root

Top right → your account name → **Security credentials** → **Multi-factor
authentication (MFA)** → **Assign MFA device**. Use your phone's authenticator
app.

Do this even though it feels like a detour. Root on this account will shortly be
able to reach a machine with SSH open to the internet.

### 1.3 Let IAM users see billing

Top right → **Account** → scroll to **IAM user and role access to Billing
information** → **Edit** → tick **Activate IAM Access** → **Update**.

Only root can flip this. Without it, `RanchHand1` can't see the budget you're
about to create.

### 1.4 Create a budget so a mistake can't quietly cost you $400

Search for **Billing and Cost Management** → **Budgets** → **Create budget** →
**Customize (advanced)** → **Cost budget**.

- Period: Monthly, Recurring
- Budgeted amount: `100` (or whatever number would annoy you)
- Name: `wizex-budget`
- Alert threshold: 50% of budgeted amount → your email
- Add two more alerts at 80% and 100%

This is a safety net, not a control. Budgets alert, they don't stop spending.

### 1.5 Add MFA to RanchHand1 and create an access key

`RanchHand1` already has `AdministratorAccess`, so there are no permissions to
change here.

That level of access is genuinely required: Terraform creates IAM roles, an OIDC
identity provider, CloudTrail, AWS Config, GuardDuty, EKS, and VPC networking.
A hand-scoped policy for that ends up equivalent to admin with more ways to
break. In a disposable account with nothing else in it, that's a reasonable
trade — but it does mean this one user can do anything, so give it MFA.

**IAM** → **Users** → **RanchHand1** → **Security credentials** tab.

First: **Assign MFA device**, same authenticator app as root. This user is about
to be able to reach a machine with SSH open to the internet.

Then: **Create access key** → **Command Line Interface (CLI)** → tick the
acknowledgement → **Create access key**.

You get an **Access key ID** and a **Secret access key**. The secret is shown
once. Copy both somewhere safe for the next 60 seconds.

> Never paste that secret key into a chat window, a commit, or a config file in
> the repo. It goes in one place: the `aws configure` prompt below, which writes
> it to `~/.aws/credentials` outside your project folder.

### 1.6 Configure the CLI

Back in Terminal:

```bash
aws configure --profile ranchhand
```

Four prompts:

```
AWS Access Key ID     : <paste the access key ID>
AWS Secret Access Key : <paste the secret>
Default region name   : us-east-1
Default output format : json
```

Then make it the default for this terminal session:

```bash
export AWS_PROFILE=ranchhand
```

That `export` only lasts for the current terminal window. Every time you open a
new one, run it again. To make it permanent:

```bash
echo 'export AWS_PROFILE=ranchhand' >> ~/.zshrc
```

### 1.7 Sign out of root

Close the root browser session. From here you use `RanchHand1` for everything.

### 1.8 Check your EC2 quota

```bash
aws service-quotas get-service-quota \
  --service-code ec2 \
  --quota-code L-1216C47A \
  --query 'Quota.Value'
```

That's the "Running On-Demand Standard instances" quota, counted in vCPUs.

- **8 or more** — you're fine, move on.
- **Less than 8** — request an increase now, before you go further:

```bash
aws service-quotas request-service-quota-increase \
  --service-code ec2 --quota-code L-1216C47A --desired-value 16
```

Approval is often minutes but can take hours. Check with:

```bash
aws service-quotas list-requested-service-quota-change-history-by-quota \
  --service-code ec2 --quota-code L-1216C47A \
  --query 'RequestedQuotas[0].Status'
```

**Check:** this returns your account number and the RanchHand1 user ARN.

```bash
aws sts get-caller-identity
```

Expected:

```json
{
  "UserId": "AIDA...",
  "Account": "<YOUR_ACCOUNT_ID>",
  "Arn": "arn:aws:iam::<YOUR_ACCOUNT_ID>:user/RanchHand1"
}
```

If `Account` shows anything else, you're pointed at the wrong profile — go back
to 1.6.

---

## Phase 2 — Get the code onto your Mac and into VSCode

### 2.1 Unzip it somewhere sensible

```bash
mkdir -p ~/projects
cd ~/projects
unzip ~/Downloads/wiz-exercise.zip
cd wiz-exercise
```

### 2.2 Open it in VSCode

```bash
code .
```

If `code` isn't found: open VSCode, press `Cmd+Shift+P`, type
"shell command", pick **Install 'code' command in PATH**, then try again.

### 2.3 Point Claude Code at it

In the VSCode terminal, from inside `~/projects/wiz-exercise`:

```bash
claude
```

Claude Code reads the whole repo, so it's the fastest way to understand what a
file does or debug an error later. Useful prompts once you're in it:

- `explain what terraform/mongodb_vm.tf creates and which parts are the intentional findings`
- `terraform apply failed with this error, what's wrong: <paste the error>`
- `walk me through how the MONGODB_URI env var gets from terraform into the running pod`

Exit with `Ctrl+C` twice or by typing `/exit`.

### 2.4 Put your name in the exercise file

```bash
echo "Your Full Name" > app/wizexercise.txt
cat app/wizexercise.txt
```

Use your real name — this is the file the exercise asks you to prove exists
inside the running container. Both pipelines hard-fail if the placeholder is
still there.

### 2.5 Fill in the other placeholders

Search the repo for `REPLACE_WITH` (in VSCode: `Cmd+Shift+F`). Two left:

| File | What to put |
|---|---|
| `terraform/locals.tf` | your name in the `Owner` tag |
| `docs/RISK-ACCEPTANCE.md` | your name and today's date at the bottom |

`.github/CODEOWNERS` is already set to `@rgardner21`.

### 2.6 Generate the SSH key for the MongoDB VM

```bash
ssh-keygen -t ed25519 -f ~/.ssh/wizex -C wizex
```

Press Enter twice to skip the passphrase (this is a throwaway key for a
throwaway VM). This creates two files: `~/.ssh/wizex` (private — never share,
never commit) and `~/.ssh/wizex.pub` (public — safe to paste anywhere).

**Check:**

```bash
cat ~/.ssh/wizex.pub          # starts with ssh-ed25519 AAAA...
cat app/wizexercise.txt       # your name, not the placeholder
```

---

## Phase 3 — Put it on GitHub

### 3.1 Log in to GitHub from the terminal

```bash
gh auth login
```

Choose: GitHub.com → HTTPS → yes, authenticate Git → Login with a web browser.
Copy the one-time code it shows, press Enter, paste the code in the browser.

### 3.2 Public or private?

This decides which security features you get for free.

**Public** (what I'd suggest): Code scanning, secret scanning, and push
protection all work on the free tier. The pipelines run exactly as designed. The
repo contains no credentials and no account identifiers — `.gitignore` already
excludes `terraform.tfvars`, `backend.hcl`, and all state files, which are the
only places secrets ever live. Deliberately-vulnerable IaC in a public repo is
normal for this exercise, and reviewers can see your work.

**Private**: nothing leaks, but the `upload-sarif` steps in the workflows fail
with a 403 unless you're on GitHub Advanced Security. If you go private, open
each workflow and add `continue-on-error: true` under every
`github/codeql-action/upload-sarif` step, and delete `.github/workflows/codeql.yml`.

### 3.3 Create the repo and push

```bash
git init -b main
git add .
git commit -m "Wiz exercise: intentionally vulnerable AWS environment"

gh repo create wiz-exercise --public --source=. --remote=origin --push
```

Swap `--public` for `--private` if you chose that.

This lands at `github.com/rgardner21/wiz-exercise`, which is already filled in
as `github_repository` in `terraform.tfvars.example`. If you name the repo
something else, change that value in Phase 5 to match — the OIDC trust policy
is scoped to the exact repo path, and a mismatch is the single most common
reason the pipelines fail to authenticate later.

### 3.4 Don't enable branch protection yet

Branch protection would block the direct pushes you're about to make while
getting things working. You'll turn it on in Phase 9, once the pipelines pass.

**Check:** `gh repo view --web` opens your repo in the browser and the files are
all there.

---

## Phase 4 — Create the Terraform state bucket

Terraform records what it built in a "state file". Keeping that in S3 rather
than on your laptop means the CI/CD pipelines can read it too. This bucket is
created by hand, once, because Terraform can't store its own state in a bucket
it hasn't created yet.

Bucket names are globally unique across all of AWS, so we'll suffix with your
account number:

```bash
export TFSTATE_BUCKET=wizex-tfstate-<YOUR_ACCOUNT_ID>
export TFLOCK_TABLE=wizex-tfstate-locks

aws s3api create-bucket --bucket "$TFSTATE_BUCKET" --region us-east-1

aws s3api put-bucket-versioning --bucket "$TFSTATE_BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-public-access-block --bucket "$TFSTATE_BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

aws dynamodb create-table --table-name "$TFLOCK_TABLE" \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

The DynamoDB table is a lock, so two people (or you and a pipeline) can't apply
at the same time and corrupt the state.

Note that this bucket is locked down hard, unlike the backup bucket the exercise
asks you to expose. That contrast is worth mentioning in your walkthrough.

**Check:**

```bash
aws s3 ls | grep wizex-tfstate
aws dynamodb describe-table --table-name "$TFLOCK_TABLE" --query 'Table.TableStatus'
```

---

## Phase 5 — Configure Terraform

```bash
cd terraform
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
```

Neither file is committed — `.gitignore` covers both.

Edit `backend.hcl` in VSCode:

```hcl
bucket         = "wizex-tfstate-<YOUR_ACCOUNT_ID>"
key            = "wiz-exercise/terraform.tfstate"
region         = "us-east-1"
dynamodb_table = "wizex-tfstate-locks"
encrypt        = true
```

Edit `terraform.tfvars`:

```hcl
region      = "us-east-1"
project     = "wizex"
alert_email = "you@example.com"

github_repository = "rgardner21/wiz-exercise"

ssh_public_key = "ssh-ed25519 AAAAC3Nza... wizex"

# The exercise asks for 0.0.0.0/0. See the note below.
ssh_ingress_cidr = "0.0.0.0/0"
```

For `ssh_public_key`, paste the entire single line from `cat ~/.ssh/wizex.pub`.

**On `ssh_ingress_cidr`:** `0.0.0.0/0` is what the brief asks for, and it's what
produces the finding. It also means the box gets scanned by bots within minutes
of booting. My suggestion: build with your own IP while you're working, then
open it to the world right before you record the walkthrough. Get your IP with
`curl -s ifconfig.me` and use `<that-ip>/32`. You keep the "SSH reachable from
outside the VPC" finding either way, and changing it later is a 30-second
`terraform apply`.

Now initialize:

```bash
terraform init -backend-config=backend.hcl
```

This downloads the AWS, Kubernetes, and Helm providers and the VPC/EKS modules.
Takes a minute or two.

**Check:** ends with "Terraform has been successfully initialized!"

---

## Phase 6 — Build the infrastructure

This runs in two passes on purpose. The Kubernetes and Helm providers need to
connect to a cluster that doesn't exist yet, so pass one builds the networking
and the cluster, and pass two builds everything that talks to it. Trying to do
it in one shot produces a confusing "Provider configuration is unknown" error.

### 6.1 Pass one — network and cluster (~20 minutes)

```bash
terraform apply -target=module.vpc -target=module.eks
```

Terraform prints a plan and asks for confirmation. Read it — this is a good
moment to see what you're about to build. Type `yes` and press Enter.

Go make coffee. EKS control planes take 10–15 minutes on their own.

Ignore the yellow "Resource targeting is in effect" warning. It's telling you
this is a partial apply, which is exactly what you want here.

### 6.2 Pass two — everything else (~5 minutes)

```bash
terraform apply
```

Review, type `yes`. This creates the MongoDB VM, the public backup bucket,
CloudTrail, GuardDuty, AWS Config, the alarms, the ECR registry, the GitHub
OIDC roles, and the Kubernetes namespace, secret, and cluster-admin binding.

### 6.3 Confirm the alert email

Check your inbox for "AWS Notification - Subscription Confirmation" and click
the link. Without this you get no detective-control alerts, which is half the
demo.

### 6.4 Look at what you built

```bash
terraform output
```

Save this output somewhere — you'll refer to it constantly. The useful ones:

| Output | What it's for |
|---|---|
| `mongodb_public_ip` | SSH target |
| `mongodb_backup_bucket` | the intentionally public bucket |
| `mongodb_backup_bucket_public_url` | open this in a logged-out browser |
| `ecr_repository_url` | where you push the container image |
| `eks_cluster_name` | for `kubectl` config |
| `github_actions_*_role_arn` | for the GitHub setup in Phase 9 |

**Check:** `terraform apply` ends with "Apply complete!" and no errors.

---

## Phase 7 — Verify the MongoDB VM

The VM runs a startup script that installs an outdated MongoDB, creates users,
turns on authentication, and schedules the backup. Give it 3–5 minutes after
Terraform finishes, then check.

```bash
export VM_IP=$(terraform output -raw mongodb_public_ip)
ssh -i ~/.ssh/wizex ubuntu@$VM_IP
```

Type `yes` at the host-key prompt. Once you're in:

```bash
# Did the startup script finish?
tail -30 /var/log/wiz-bootstrap.log

# The two outdated versions the exercise asks for
lsb_release -a          # Ubuntu 20.04.x LTS  (April 2020)
mongod --version        # db version v4.4.x   (end of life Feb 2024)

# Is the database up and requiring auth?
systemctl status mongod --no-pager
grep -A2 security /etc/mongod.conf

# Did the first backup run?
tail -20 /var/log/mongo-backup.log
cat /etc/cron.d/mongo-backup
```

While you're on the box, this is the cleanest demo of the preventative control:

```bash
# IMDSv1 — refused, because the instance requires IMDSv2
curl -s -m 3 http://169.254.169.254/latest/meta-data/ ; echo "(blocked)"

# IMDSv2 — works, and reveals the over-permissive role
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/iam/security-credentials/
```

That prints `wizex-mongo-vm-role` — the one carrying `AdministratorAccess`.

Type `exit` to get back to your Mac. Then confirm the backup landed:

```bash
export BUCKET=$(terraform output -raw mongodb_backup_bucket)
aws s3 ls s3://$BUCKET/backups/wizdemo/
```

If it's empty, force one:

```bash
ssh -i ~/.ssh/wizex ubuntu@$VM_IP 'sudo /usr/local/bin/mongo-backup.sh'
```

**Check:** `mongod --version` shows 4.4.x, and there's at least one `.gz` file
in the bucket.

---

## Phase 8 — Build and deploy the application

### 8.1 Point kubectl at the cluster

```bash
cd ~/projects/wiz-exercise/terraform
aws eks update-kubeconfig --region us-east-1 --name $(terraform output -raw eks_cluster_name)
kubectl get nodes
```

You should see two nodes in `Ready` state. They have no external IP — they're in
the private subnets, which is one of the requirements.

This works because `RanchHand1` created the cluster and the Terraform sets
`enable_cluster_creator_admin_permissions = true`. If you ever switch AWS
profiles, `kubectl` will start returning "Unauthorized".

### 8.2 Log Docker in to your registry

```bash
cd ~/projects/wiz-exercise
export ECR_URL=$(terraform -chdir=terraform output -raw ecr_repository_url)
echo $ECR_URL

aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin "${ECR_URL%%/*}"
```

The `${ECR_URL%%/*}` strips everything after the first slash, leaving just the
registry host, which is what `docker login` wants.

### 8.3 Build for the right architecture and push

**This is the step where the M4 bites.** The `--platform linux/amd64` flag is
not optional — without it you build arm64 and the pod crash-loops:

```bash
docker buildx build \
  --platform linux/amd64 \
  -t "$ECR_URL:v1" \
  --push \
  app/
```

First build takes a few minutes — longer than you'd expect for an app this
small, because your M4 is emulating amd64. Later builds reuse cached layers and
are much quicker.

If it fails with `exec format error` during a `RUN` step, or with "multiple
platforms feature is currently not enabled", go back to Phase 0.4 and register
the emulator.

### 8.4 Prove wizexercise.txt is in the image

Before it ever reaches Kubernetes:

```bash
docker run --rm --platform linux/amd64 --entrypoint sh "$ECR_URL:v1" \
  -c 'ls -l /app/wizexercise.txt && cat /app/wizexercise.txt'
```

While you're here, confirm you pushed the right architecture — 30 seconds now
saves a confusing crash-loop in two minutes:

```bash
docker image inspect "$ECR_URL:v1" --format '{{.Architecture}}'   # must say amd64
```

Screenshot the `cat` output. It's evidence item one: the file is baked into an image layer,
not mounted at runtime.

### 8.5 Deploy to Kubernetes

```bash
cd k8s
kubectl kustomize . | sed "s|PLACEHOLDER_IMAGE:latest|$ECR_URL:v1|g" | kubectl apply -f -
kubectl -n wiz-todo rollout status deployment/wiz-todo --timeout=5m
cd ..
```

The namespace, the MongoDB connection secret, the service account, and its
cluster-admin binding already exist — Terraform made them in Phase 6. This step
adds the Deployment, Service, and Ingress.

### 8.6 Watch the pods come up

```bash
kubectl -n wiz-todo get pods -w
```

Wait for `2/2 Running`. `Ctrl+C` to stop watching.

If they're crash-looping, jump to the troubleshooting appendix — the two likely
causes are the architecture flag and the database connection.

### 8.7 Get the load balancer address

```bash
kubectl -n wiz-todo get ingress wiz-todo
```

The `ADDRESS` column takes 2–3 minutes to populate while AWS provisions the ALB,
and another 2–3 minutes after that before it actually serves traffic. Patience.

```bash
export ALB=$(kubectl -n wiz-todo get ingress wiz-todo \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "http://$ALB"
open "http://$ALB"
```

You should get the todo app. The status panel at the top shows the pod name, the
MongoDB version it's talking to (4.4.x), and the contents of `wizexercise.txt`.

Add a todo. If it saves and survives a refresh, the container is genuinely
reading and writing to the MongoDB VM through the environment variable.

**Check:** all of these succeed.

```bash
curl -s "http://$ALB/wizexercise.txt"
curl -s "http://$ALB/api/status" | jq

POD=$(kubectl -n wiz-todo get pods -l app.kubernetes.io/name=wiz-todo \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n wiz-todo exec "$POD" -- cat /app/wizexercise.txt
kubectl -n wiz-todo exec "$POD" -- printenv MONGODB_URI
```

That last command is evidence item two: the file inside the running container,
and the database credential arriving as a Kubernetes environment variable.

---

## Phase 9 — Wire up the CI/CD pipelines

Everything works by hand now. This phase makes it work from GitHub.

### 9.1 Collect the values

```bash
cd terraform
terraform output github_actions_plan_role_arn
terraform output github_actions_apply_role_arn
terraform output github_actions_app_role_arn
terraform output ecr_repository_url
terraform output eks_cluster_name
cd ..
```

### 9.2 Set the repository variables

Variables are non-secret configuration. Fastest via the CLI:

```bash
gh variable set AWS_REGION --body "us-east-1"
gh variable set AWS_PLAN_ROLE_ARN  --body "$(terraform -chdir=terraform output -raw github_actions_plan_role_arn)"
gh variable set AWS_APPLY_ROLE_ARN --body "$(terraform -chdir=terraform output -raw github_actions_apply_role_arn)"
gh variable set AWS_APP_ROLE_ARN   --body "$(terraform -chdir=terraform output -raw github_actions_app_role_arn)"
gh variable set EKS_CLUSTER_NAME   --body "$(terraform -chdir=terraform output -raw eks_cluster_name)"
gh variable set TF_STATE_BUCKET    --body "wizex-tfstate-<YOUR_ACCOUNT_ID>"
gh variable set TF_LOCK_TABLE      --body "wizex-tfstate-locks"
gh variable set ECR_REPOSITORY     --body "wizex/wiz-todo"
```

`ECR_REPOSITORY` is the repository **name only** — `wizex/wiz-todo` — not the
full URL. The workflow builds the full path from the registry host it gets at
login time.

### 9.3 Set the secrets

```bash
gh secret set MONGO_SSH_PUBLIC_KEY --body "$(cat ~/.ssh/wizex.pub)"
gh secret set ALERT_EMAIL --body "you@example.com"
```

No AWS access keys here, and that's the point. The workflows authenticate by
exchanging a short-lived GitHub OIDC token for temporary AWS credentials. The
trust policy on the apply roles only accepts tokens from your repo, on the
`main` branch or the `production` environment. There is no long-lived credential
to steal.

### 9.4 Create the production environment gate

This has to be done in the browser: **Settings** → **Environments** → **New
environment** → name it `production` → **Configure environment**:

- Tick **Required reviewers**, add yourself
- Under **Deployment branches**, choose **Selected branches**, add `main`

Now nothing reaches AWS without you clicking approve.

### 9.5 Turn on branch protection

**Settings** → **Branches** → **Add branch protection rule**:

- Branch name pattern: `main`
- Require a pull request before merging, 1 approval
- Require review from Code Owners
- Require status checks to pass, and select: `Static analysis`,
  `Terraform plan`, `Build and scan image`
- Require conversation resolution before merging
- Block force pushes and deletions

The full recommended list is in `docs/REPO-SECURITY.md`.

> If you're the only person on the repo, "require 1 approval" means you can't
> merge your own PRs. Either add a collaborator, or leave "Do not allow
> bypassing" unticked so you can admin-merge. Mention which you chose in your
> walkthrough — it's a real trade-off, not a mistake.

### 9.6 Turn on the scanning features

**Settings** → **Code security and analysis**, enable:

- Secret scanning
- Secret scanning push protection
- Dependabot alerts
- Dependabot security updates

### 9.7 Test both pipelines with a real PR

```bash
git checkout -b test-pipelines
# make a trivial change - a comment in app/server.js works
git commit -am "Test the pipelines"
git push -u origin test-pipelines
gh pr create --fill
```

Watch it run: `gh pr checks --watch`, or open the Actions tab.

On the PR you should see: Gitleaks, Checkov, Trivy, Terraform plan posted as a
comment, the image build, the `wizexercise.txt` verification, and the Trivy
image scan. No AWS changes — a PR only gets the read-only role.

Merge it, and the `main` branch run will pause for your approval on the
`production` environment. Approve it, and watch the deploy job push to ECR, roll
out to EKS, and re-verify `wizexercise.txt` inside the running pod. The job
summary captures that output — screenshot it.

**Check:** green checks on the PR, and a successful deploy on `main` with the
file contents visible in the job summary.

---

## Phase 10 — Collect your evidence

Work through `docs/VALIDATION.md`, which has the exact command and expected
output for every requirement. The demo sequence that tells the best story:

1. **The app works.** Open the ALB URL, add a todo, point out the status panel
   showing MongoDB 4.4 and your name from `wizexercise.txt`.
2. **The file is really in the container.**
   `kubectl -n wiz-todo exec $POD -- cat /app/wizexercise.txt`, plus the
   Dockerfile line that put it there, plus the pipeline job summary.
3. **The workload is cluster-admin.**
   `kubectl auth can-i '*' '*' --all-namespaces --as=system:serviceaccount:wiz-todo:wiz-todo`
   returns `yes`. An internet-facing pod that can read every secret in the
   cluster.
4. **The backups are public.** This is the strongest moment. In a logged-out
   browser, open `terraform output mongodb_backup_bucket_public_url`. Then from
   the terminal, with `--no-sign-request` to prove no credential is involved:

   ```bash
   aws s3 ls s3://$BUCKET/backups/wizdemo/ --no-sign-request
   ```

   Download a dump and show it restores. That's the whole database, to anyone,
   with no AWS account.
5. **The VM is over-privileged.** SSH in, show IMDSv1 blocked and IMDSv2
   revealing the `AdministratorAccess` role.
6. **Everything was recorded.** CloudTrail has all of it. AWS Config shows the
   NON_COMPLIANT rules. GuardDuty has findings. Your inbox has alarm emails.

   ```bash
   aws configservice describe-compliance-by-config-rule \
     --query 'ComplianceByConfigRules[?Compliance.ComplianceType==`NON_COMPLIANT`].ConfigRuleName'
   ```

   Give Config 15–30 minutes after deployment before expecting evaluations.

7. **The controls that held.** `aws ec2 get-ebs-encryption-by-default` returns
   true, IMDSv2 blocked the credential theft path, the audit log bucket can't be
   made public, and the database refused connections from anywhere except the
   EKS nodes.

---

## Phase 11 — Tear it down

Do this the same day you finish recording. Full detail in `docs/TEARDOWN.md`,
but the order matters:

```bash
# 1. Kubernetes first, so the controller deletes the load balancer.
#    Skip this and the VPC destroy hangs for 20 minutes on orphaned network interfaces.
kubectl -n wiz-todo delete ingress wiz-todo
kubectl -n wiz-todo delete deployment,service wiz-todo --ignore-not-found
sleep 90

# 2. Empty the backup bucket (it's versioned)
aws s3 rm "s3://$(terraform -chdir=terraform output -raw mongodb_backup_bucket)" --recursive

# 3. Destroy
cd terraform
terraform destroy
```

Then confirm nothing survived:

```bash
aws ec2 describe-instances --filters "Name=tag:Project,Values=wizex" \
  --query 'Reservations[].Instances[?State.Name!=`terminated`].InstanceId'
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
aws s3 ls | grep wizex
```

The state bucket and lock table survive on purpose — you made those by hand.
Delete them manually when you're completely done.

Last: delete the `RanchHand1` access key (IAM → Users → RanchHand1 → Security
credentials → Delete), and check Cost Explorer tomorrow to confirm spend has
flatlined.

---

## Troubleshooting

**`terraform apply` fails with "Provider configuration is unknown"**
You skipped the two-pass apply. Run
`terraform apply -target=module.vpc -target=module.eks` first, then the plain
`terraform apply`.

**Node group fails, or Terraform hangs ~20 min then errors on the node group**
Almost always the vCPU quota from Phase 1.8. Check it, request an increase,
re-run `terraform apply`.

**Pods stuck in `CrashLoopBackOff`, logs show `exec format error`**
You built an arm64 image on the M4 and pushed it to amd64 nodes. Confirm it:

```bash
docker image inspect "$ECR_URL:v1" --format '{{.Architecture}}'
```

If that says `arm64`, rebuild with `--platform linux/amd64`, push under a **new
tag** (`:v2` — reusing `:v1` means Kubernetes may keep the cached bad image),
and redeploy:

```bash
docker buildx build --platform linux/amd64 -t "$ECR_URL:v2" --push app/
kubectl -n wiz-todo set image deployment/wiz-todo wiz-todo="$ECR_URL:v2"
kubectl -n wiz-todo rollout status deployment/wiz-todo
```

**Pods running but the page shows "database: disconnected"**
Check the pod logs: `kubectl -n wiz-todo logs $POD`. Common causes: the VM's
startup script hasn't finished (wait, then check `/var/log/wiz-bootstrap.log`),
or MongoDB didn't install. SSH in and run `systemctl status mongod`.

**MongoDB failed to install on the VM**
MongoDB has moved older repositories around over time, and 4.4 is well past end
of life. Check `/var/log/wiz-bootstrap.log` for the apt error. If the repo is
gone, switch `mongo_version` in `terraform.tfvars` to `"5.0"` (end of life
October 2024 — still comfortably over a year outdated, still satisfies the
requirement) and `terraform apply`. The instance rebuilds automatically.

**Ingress `ADDRESS` column stays empty**
Check the load balancer controller:
`kubectl -n kube-system logs -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50`.
Usually it's still starting up. Give it 5 minutes.

**`kubectl` says "error: You must be logged in to the server (Unauthorized)"**
Your AWS profile changed. `export AWS_PROFILE=ranchhand` and re-run
`aws eks update-kubeconfig`.

**GitHub Actions: "Not authorized to perform sts:AssumeRoleWithWebIdentity"**
The `github_repository` in `terraform.tfvars` doesn't match your actual repo, or
you're running the job from a branch other than `main`. Fix the variable and
`terraform apply`.

**Actions step fails with "Resource not accessible by integration" on upload-sarif**
Private repo on the free tier. See Phase 3.2.

**Checkov fails the build on something new**
Working as designed — the skip list only covers the intentional findings. Either
fix what you added, or add the check ID to the list in `.github/workflows/iac.yml`
*and* document why in `docs/RISK-ACCEPTANCE.md`.

**Stuck on anything else**
In the repo directory, run `claude` and paste the full error. It can read the
file that's failing, which is faster than reasoning about it from a snippet.
