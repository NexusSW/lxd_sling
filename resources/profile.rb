
require 'yaml'

property :profile_name, String, name_property: true
property :server_path, String, identity: true

include Chef::Recipe::LXD::ContainerProperties
include Chef::Recipe::LXD::Mixin

resource_name :lxd_profile

load_current_value do
  res = lxd.exec "lxc profile show #{profile_name}"
  return if res.error?
  load_properties YAML.load(res.stdout)['config']
end

action :create do
  converge_by "create profile (#{new_resource.profile_name})" do
    lxd.exec! "lxc profile create #{new_resource.profile_name}"
  end if lxd.exec("lxc profile show #{new_resource.profile_name}").error?

  action_modify
end

action :modify do
  modify_properties(:profile, new_resource.profile_name)
end

action :delete do
  converge_by "delete profile (#{new_resource.profile_name})" do
    lxd.exec! "lxc profile delete #{new_resource.profile_name}"
  end unless lxd.exec("lxc profile show #{new_resource.profile_name}").error?
end

action_class do
  include Chef::Recipe::LXD::ActionMixin
  include Chef::Recipe::LXD::ContainerProperties::ActionHelpers
end
