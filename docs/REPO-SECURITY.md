# VCS and pipeline security controls

## Repository settings to enable

Settings you click, which cannot live in the repo itself. Do these before the first push
to `main`.

**Branch protection on `main`** (Settings → Branches → Add rule):

- Require a pull request before merging, 1+ approval
- Require review from Code Owners (`.github/CODEOWNERS`)
- Dismiss stale approvals when new commits are pushed
- Require status checks to pass: `Static analysis`, `Terraform plan`,
  `Build and scan image`, `Analyze JavaScript`
- Require branches to be up to date before merging
- Require conversation resolution before merging
- Require signed commits
- Require linear history
- Do not allow bypassing the above (applies to admins too)
- Block force pushes and branch deletion

**Code security and analysis** (Settings → Code security):

- Secret scanning: **on**
- Secret scanning push protection: **on** — blocks a credential at `git push`,
  before it ever reaches the remote
- Dependabot alerts and security updates: **on**
- Dependabot version updates: configured in `.github/dependabot.yml`
- Private vulnerability reporting: **on**

**Actions hardening** (Settings → Actions → General):

- Allow only actions from GitHub and verified creators, or pin an allow-list
- Workflow permissions: **read-only by default**; jobs escalate explicitly
- Require approval for all outside collaborators' workflow runs

**Environments** (Settings → Environments → `production`):

- Required reviewers before any AWS-touching job runs
- Restrict deployments to the `main` branch
- Environment secrets scoped here, not repository-wide

## Controls implemented in the pipelines

| Control | Tool | Where | Blocking |
|---|---|---|---|
| Secret detection in history and diffs | Gitleaks | both pipelines | yes |
| IaC misconfiguration scan | Checkov | `iac.yml` | yes, minus a documented skip list |
| IaC misconfiguration scan, second opinion | Trivy config | `iac.yml` | reported to code scanning |
| Terraform formatting and validation | `terraform fmt`/`validate` | `iac.yml` | yes |
| Plan review before apply | plan posted as a PR comment | `iac.yml` | human gate |
| Dockerfile misconfiguration scan | Trivy config | `app.yml` | yes |
| Container vulnerability scan | Trivy image, CRITICAL+HIGH | `app.yml` | yes, pre-push |
| Registry-side scan on push | ECR scan-on-push | `eks.tf` | reported |
| SBOM generation | Syft (anchore/sbom-action) | `app.yml` | artifact |
| Kubernetes manifest scan | Trivy config | `app.yml` | reported |
| Source code analysis | CodeQL, security-extended | `codeql.yml` | yes |
| Dependency updates | Dependabot | `.github/dependabot.yml` | PRs |
| No long-lived cloud credentials | GitHub OIDC → STS | `github_oidc.tf` | — |
| Least-privilege pipeline identities | 3 roles: read-only plan, apply, app-deploy | `github_oidc.tf` | — |
| Branch-scoped privilege | apply roles only assumable from `refs/heads/main` or the `production` environment | `github_oidc.tf` | — |
| Namespace-scoped cluster access | EKS access entry, `AmazonEKSEditPolicy` on `wiz-todo` only | `github_oidc.tf` | — |
| Immutable deploys | image referenced by digest, not tag | `app.yml` | — |
| Manual approval before AWS changes | `environment: production` | both pipelines | yes |

## Why the scanners are configured this way

This repository intentionally contains insecure infrastructure, so a scanner set to
"fail on everything" would either block every build or get switched off entirely — the
worst of both worlds.

Instead: Checkov fails the build on **any** finding except a fixed, enumerated skip list
that maps one-to-one to the exercise requirements (`RISK-ACCEPTANCE.md`). Introduce a new
misconfiguration outside that list and the pipeline stops you. That keeps the gate
meaningful while still letting the deliberate findings through.

The container image is held to the ordinary standard: no CRITICAL or HIGH fixable
vulnerabilities, no exceptions. The intentional weaknesses in this exercise live in the
cloud configuration, not the image.
