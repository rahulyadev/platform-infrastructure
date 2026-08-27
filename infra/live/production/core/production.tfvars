base_domain          = "rahuly.in"
aws_region           = "ap-south-1"
availability_zone    = "ap-south-1a"
vpc_cidr             = "10.42.0.0/16"
public_subnet_cidr   = "10.42.10.0/24"
instance_type        = "t4g.medium"
root_volume_size_gib = 30

enable_identity_cognito_core                      = false
enable_identity_auth_certificate                  = false
enable_identity_auth_certificate_validation       = false
identity_auth_certificate_validation_record_fqdns = []
enable_identity_google_federation                 = false
identity_google_credentials_secret_arn            = null
enable_identity_auth_domain                       = false
enable_identity_reference_bff_client              = false
identity_reference_bff_application_origins        = []
enable_identity_client_secret_custody             = false
