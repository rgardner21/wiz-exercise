# Teardown

Do this as soon as the walkthrough is captured. The bucket and the SSH exposure are
genuinely dangerous while they exist.

```bash
# 1. Remove the Kubernetes resources first, so the ALB controller deletes the
#    load balancer and its security groups. Skipping this strands ENIs and the
#    VPC destroy will hang.
kubectl -n wiz-todo delete ingress wiz-todo
kubectl -n wiz-todo delete -k k8s/ --ignore-not-found
sleep 60   # let the controller finish deleting the ALB

# 2. Empty the buckets. force_destroy is set, but versioned objects are faster
#    to clear directly.
for B in $(terraform -chdir=terraform output -raw mongodb_backup_bucket); do
  aws s3 rm "s3://$B" --recursive
done

# 3. Destroy.
terraform -chdir=terraform destroy \
  -var="github_repository=rgardner21/wiz-exercise" \
  -var="ssh_public_key=$(cat ~/.ssh/wizex.pub)"
```

## After destroy, verify nothing survived

```bash
aws ec2 describe-instances --filters "Name=tag:Project,Values=wizex" \
  --query 'Reservations[].Instances[?State.Name!=`terminated`].InstanceId'
aws s3 ls | grep wizex
aws iam list-roles --query 'Roles[?starts_with(RoleName, `wizex`)].RoleName'
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
```

Things Terraform will not remove, by design or by quirk:

- The remote state bucket and DynamoDB lock table (created out of band).
- CloudWatch log groups, if retention has not expired. Delete them by hand if you care
  about the few cents.
- GuardDuty findings history, retained after the detector is deleted.

Finally: rotate or delete the SSH key you used, and check Cost Explorer the next day to
confirm spend has flatlined.
