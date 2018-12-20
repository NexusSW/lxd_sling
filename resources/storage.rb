# To learn more about Custom Resources, see https://docs.chef.io/custom_resources.html
require 'yaml'

property :pool_name, String, name_property: true
property :server_path, String, identity: true # default: '/var/lib/lxd',
property :backend, Symbol, equal_to: [:dir, :btrfs], required: true, default: :dir, coerce: ->(val) { val.to_sym }
property :size, String
property :source, String # , required: true

resource_name :lxd_storage

load_current_value do
  lxd = Chef::Recipe::LXD.new node, server_path
  raise 'The installed version of LXD is too old to support storage pools.' unless lxd.info['api_extensions'].include? 'storage'
  res = lxd.exec "lxc storage show #{pool_name}"
  return if res.error?
  config = YAML.load res.stdout
  backend config['driver']
  source config['config']['volatile.initial_source']
  size config['config']['size']
end

action :create do
  return action_modify if pool_exists?
  converge_if_changed do
    cmd = "lxc storage create #{new_resource.pool_name} #{new_resource.backend}"
    [:size, :source].each do |k|
      cmd << " #{k}=#{new_resource.send k}"
    end
    lxd.exec! cmd
  end
end

action :modify do
  raise 'You cannot change the backend of an existing storage pool.  Drop and recreate the pool if that is intended.' unless current_resource.backend == new_resource.backend

  [:size, :source].each do |k|
    converge_if_changed k do
      lxd.exec! "lxc storage set #{new_resource.pool_name} #{k} #{new_resource.send k}"
    end
  end
end

action :delete do
  return unless pool_exists?
  converge_by "Deleting LXD storage pool (#{new_resource.pool_name})" do
    lxd.exec! "lxc storage delete #{pool_name}"
  end
end

action_class do
  def lxd
    @lxd ||= Chef::Recipe::LXD.new node, new_resource.server_path
  end

  def pool_config
    return @config if @config
    res = lxd.exec "lxc storage show #{new_resource.pool_name}"
    return nil if res.error?
    @config = YAML.load res.stdout
  end

  def pool_exists?
    pool_config ? true : false
  end
end
