# Risk acceptance register

Every suppressed scanner finding, why it is suppressed, and what compensates for it.
This is the document a reviewer should ask for when they see a `skip_check` list.

**Scope:** a short-lived, isolated AWS account containing no real data, built to
demonstrate cloud security detection. Not production, not connected to anything, torn
down after the walkthrough.

| Finding | Requirement it satisfies | Residual risk | Compensating control |
|---|---|---|---|
| S3 bucket allows public read | "Object storage must allow public read and public listing" | Anyone can download database dumps | No real data; 30-day lifecycle expiry; CloudTrail S3 data events; anonymous-access alarm; Config rule flags it |
| S3 bucket allows public listing | same | Contents enumerable | as above |
| Public access block disabled on the backup bucket | same | Nothing stops a future public policy | Scoped to this one bucket; enforced on the CloudTrail and Config buckets |
| Security group allows 0.0.0.0/0 on port 22 | "SSH must be exposed to the public internet" | Brute force and 0-day against sshd | Key-only auth; isolated account; GuardDuty brute-force detection; `INCOMING_SSH_DISABLED` Config rule flags it; narrowable to a `/32` via `ssh_ingress_cidr` |
| Instance profile has `AdministratorAccess` | "VM should be granted overly permissive CSP permissions" | VM compromise equals account compromise | IMDSv2 required with hop limit 1; CloudTrail on all API calls; isolated account with a budget alarm |
| Outdated OS (Ubuntu 20.04) | "1+ year outdated version of Linux" | Unpatched kernel and userland CVEs | Short-lived; no real data; network exposure limited to 22 and 27017 |
| Outdated MongoDB (4.4, EOL) | "1+ year outdated database version" | Unpatched database CVEs | Authentication enabled; 27017 reachable only from the EKS node security group |
| ServiceAccount bound to `cluster-admin` | "Container application must be assigned a cluster-wide kubernetes admin role" | Container compromise equals cluster compromise | Container runs non-root with a read-only root filesystem and all capabilities dropped; image scanned pre-push; EKS audit logging on |
| No WAF on the ALB | not required by the exercise | Application-layer attacks | Application handles only untrusted todo strings; no real data |
| No TLS on the ALB listener | not required by the exercise | Traffic in the clear | No credentials or real data traverse it; add ACM and a `certificate-arn` annotation if you want it |
| EKS public API endpoint enabled | needed for hosted-runner `kubectl` | API server reachable from the internet | IAM-authenticated; namespace-scoped access entry for the pipeline role; set `cluster_endpoint_public_access_cidrs` or use a self-hosted runner to close it |

## Accepted by

- Name: Rich Gardner
- Date: 08/26
- Review: at teardown, or 7 days from deployment, whichever comes first
