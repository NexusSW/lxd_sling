# Inspec test for recipe lxd_sling::default

# The Inspec reference, with examples and extensive documentation, can be
# found at http://inspec.io/docs/reference/resources/

describe port(8443), :skip do
  it { should be_listening }
end
