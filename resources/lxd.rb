require 'pry'

property :server_path, String, name_property: true # , default: '/var/lib/lxd'
property :branch, Symbol, default: :lts, equal_to: [:feature, :lts]
property :users, [Array, String]
property :auto_install, [true, false], default: true
property :auto_upgrade, [true, false], default: true

# Config properties
property :network_address, String
property :network_port, Integer, default: 8443
property :storage_pool, String, default: 'default'
property :storage_backend, String, equal_to: %w(dir lvm zfs btrfs)
property :storage_create_device, String
property :storage_create_loop, String
property :storage_config, Hash
property :trust_password, [String], sensitive: true

provides :lxd
default_action :init

# the server_path property is included, but we're not supporting multiple installations of lxd
# afaic just nest if you want to do some form of seperation (Issues and PR's welcome if you have a use case)
# but the server_path property is there because it combines to form into some systemd service names
#   just in case I need them later
#   and this allows the user to override that value in cases where 'they' did the multi-install and are just pointing us to it
#     on that note, we'll go ahead and supply the `LXD_DIR=#{new_resource.server_path}` environment variable in our system calls
#       bear in mind that nothing upstream supports this (yet)

# lts branch has no means to reconfigure storage other than via `lxd init`, so we have to do it here
# the other options are there because they 'can' be included in an `lxd init` call, or they may be configured later
# configure via post-init resources where possible
#   to allow for configuring a running system
#   `lxd init` cannot be called if any containers or images (or other things?) exist

# we'll only call `lxd init` on the lts branch if storage properties are specified or we did the install
# we'll only call `lxd init` on the feature branch if we did the install
# otherwise we'll build the config command by command, unless i find more cases where we HAVE to call `lxd init`
#   to allow for max flexibility in configuring a running system

action :upgrade do
  do_install
  edit_resource!(:package, 'lxd') do
    action :upgrade
  end
end

action :install do
  do_install
end

action :init do
  unless installed?(new_resource.branch)
    if installed?(:feature) && (new_resource.branch == :lts)
      warn 'The LTS release of LXD was requested, but a newer version is already installed...  Continuing.'
    else
      raise "Cannot install the #{new_resource.branch} branch of LXD on this version of this platform (#{node['lsb']['codename']})" unless can_install?(new_resource.branch)
      raise "The #{new_resource.branch} branch of LXD is not available for configuration.  Is it installed?" unless should_install?(new_resource.branch)
    end
  end
  (new_resource.auto_upgrade ? action_upgrade : action_install) if new_resource.auto_install # always install regardless of necessity in hopes of picking up security updates
end

action_class do
  def do_install
    raise "Cannot install the #{new_resource.branch} branch of LXD on this version of this platform (#{node['lsb']['codename']})" unless can_install?(new_resource.branch)

    include_recipe 'lxd::lxd_from_package'

    edit_resource!(:package, 'lxd') do
      default_release 'trusty-backports'
    end if (node['lsb']['codename'] == 'trusty') && (new_resource.branch == :lts)

    use_repo = (new_resource.branch == :feature)
    edit_resource!(:apt_repository, 'lxd') do
      only_if { use_repo }
    end
  end

  def lxd_version
    return node['packages']['lxd']['version'] if node['packages'].key? 'lxd'
    `lxc --version`
  end

  def installed?(branch)
    major, minor, = lxd_version.split('.', 3)
    return false if major.to_i < 2
    case branch
    when :lts then minor.to_i == 0
    when :feature then minor.to_i > 0
    end
  rescue
    return false
  end

  def can_install?(_branch)
    node['platform'] == 'ubuntu'
    # return false unless node['platform'] == 'ubuntu'
    # case branch
    # when :lts then node['platform_version'].split('.')[0].to_i >= 14
    # when :feature then node['platform_version'].split('.')[0].to_i >= 16
    # end
  end

  def should_install?(branch)
    new_resource.auto_install && !installed?(branch) && can_install?(branch)
  end
end
