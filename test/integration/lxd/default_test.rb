# Inspec test for recipe lxd_sling::default

# The Inspec reference, with examples and extensive documentation, can be
# found at http://inspec.io/docs/reference/resources/

require 'yaml'

describe port(8443) do
  it { should be_listening }
end

describe bridge('lxdbr0') do
  it { should exist }
end

describe 'default profile' do
  it 'has eth0 attached to lxdbr0' do
    expect(YAML.load(command('lxc profile show default').stdout)['devices']['eth0']['parent']).to eq 'lxdbr0'
  end
end
