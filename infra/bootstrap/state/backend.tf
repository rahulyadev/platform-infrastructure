terraform {
  backend "local" {
    path = ".state/bootstrap-state.tfstate"
  }
}
