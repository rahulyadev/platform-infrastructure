terraform {
  backend "local" {
    path = ".state/bootstrap-account.tfstate"
  }
}
