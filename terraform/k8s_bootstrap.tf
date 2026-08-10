###############################################################################
# Kubernetes objects Terraform owns.
#
# The MongoDB connection string is generated here (it contains the instance's
# private IP and the randomly generated app password) and handed to the
# Deployment as an environment variable sourced from this Secret.
###############################################################################

resource "kubernetes_namespace_v1" "app" {
  metadata {
    name = "wiz-todo"
    labels = {
      "app.kubernetes.io/part-of" = local.name
    }
  }

  depends_on = [module.eks]
}

resource "kubernetes_secret_v1" "mongo" {
  metadata {
    name      = "mongo-connection"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }

  data = {
    MONGODB_URI = local.mongodb_uri
    MONGODB_DB  = "wizdemo"
  }

  type = "Opaque"
}

resource "kubernetes_service_account_v1" "app" {
  metadata {
    name      = "wiz-todo"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
}

###############################################################################
# INTENTIONAL MISCONFIGURATION (exercise requirement):
# the application service account is bound to cluster-admin. A compromise of
# the todo container is therefore a compromise of the whole cluster.
###############################################################################
resource "kubernetes_cluster_role_binding_v1" "app_cluster_admin" {
  metadata {
    name = "wiz-todo-cluster-admin"
    labels = {
      "exercise.wiz/intentional-finding" = "cluster-admin-binding"
    }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.app.metadata[0].name
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
}
