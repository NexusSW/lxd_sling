# To learn more about Custom Resources, see https://docs.chef.io/custom_resources.html
require 'yaml'

coercions = {
  sym: ->(val) { val.to_sym },
  int: ->(val) { val.to_i },
  bool: ->(val) { val.is_a?(String) ? (val.downcase == 'true') : val },
}

property :pool_name, String, name_property: true
property :server_path, String, identity: true # default: '/var/lib/lxd',
property :backend, Symbol, equal_to: [:dir, :btrfs, :ceph], required: true, default: :dir, coerce: coercions[:sym]
property :size, String
property :source, String # , required: true
property :ceph_cluster_name, String, default: 'ceph'
property :ceph_osd_force_reuse, [true, false], default: false, coerce: coercions[:bool]
property :ceph_osd_pg_num, Integer, default: 32, coerce: coercions[:int]
property :ceph_osd_pool_name, String # , required: true
property :ceph_rbd_clone_copy, [true, false], default: true, coerce: coercions[:bool]
property :ceph_user_name, String # , required: true

resource_name :lxd_storage

load_current_value do
  lxd = Chef::Recipe::LXD.new node, server_path
  raise 'The installed version of LXD is too old to support storage pools.' unless lxd.info['api_extensions'].include? 'storage'
  res = lxd.exec "lxc storage show #{pool_name}"
  return if res.error?
  config = YAML.load res.stdout
  backend config['driver']
  if backend == :ceph
    ceph_cluster_name config['config'][KEY_OVERRIDES['ceph_cluster_name']]
    ceph_osd_force_reuse config['config'][KEY_OVERRIDES['ceph_osd_force_reuse']]
    ceph_osd_pg_num config['config'][KEY_OVERRIDES['ceph_osd_pg_num']]
    ceph_osd_pool_name config['config'][KEY_OVERRIDES['ceph_osd_pool_name']]
    ceph_rbd_clone_copy config['config'][KEY_OVERRIDES['ceph_rbd_clone_copy']]
    ceph_user_name config['config'][KEY_OVERRIDES['ceph_user_name']]
  else
    source config['config']['volatile.initial_source']
    size config['config']['size']
  end
end

action :create do
  return action_modify if pool_exists?
  if new_resource.backend == :ceph
    raise 'The installed version of LXD is too old to support a ceph storage pool.' unless lxd.info['api_extensions'].include? 'storage_driver_ceph'
  end

  validate_device
  converge_by "Create #{new_resource.backend} storage pool (#{new_resource.pool_name})" do
    cmd = "lxc storage create #{new_resource.pool_name} #{new_resource.backend}"
    VALID_PROPS[new_resource.backend].each do |k|
      next unless property_is_set? k
      cmd << " #{translate_key(k)}=#{new_resource.send k}"
    end
    lxd.exec! cmd
  end
end

action :modify do
  raise 'You cannot change the backend of an existing storage pool.  Drop and recreate the pool if that is intended.' unless current_resource.backend == new_resource.backend
  if new_resource.backend == :ceph
    raise 'The installed version of LXD is too old to support a ceph storage pool.' unless lxd.info['api_extensions'].include? 'storage_driver_ceph'
  end

  validate_device
  VALID_PROPS[new_resource.backend].each do |k|
    converge_if_changed k do
      lxd.exec! "lxc storage set #{new_resource.pool_name} #{translate_key(k)} #{new_resource.send k}"
    end
  end
end

action :delete do
  return unless pool_exists?
  converge_by "Deleting LXD storage pool (#{new_resource.pool_name})" do
    lxd.exec! "lxc storage delete #{pool_name}"
  end
end

KEY_OVERRIDES = {
  ceph_cluster_name: 'ceph.cluster_name',
  ceph_osd_force_reuse: 'ceph.osd.force_reuse',
  ceph_osd_pg_num: 'ceph.osd.pg_num',
  ceph_osd_pool_name: 'ceph.osd.pool_name',
  ceph_rbd_clone_copy: 'ceph.rbd.clone_copy',
  ceph_user_name: 'ceph.user.name',
}.freeze

action_class do
  REQUIRED_PROPS = {
    ceph: [:ceph_osd_pool_name, :ceph_user_name],
    dir: [],
    btrfs: [],
  }.freeze
  EXCLUDE_AUTO_PROPS = [:backend].freeze
  VALID_PROPS = {
    ceph: [:ceph_osd_pool_name, :ceph_user_name, :ceph_rbd_clone_copy, :ceph_osd_pg_num, :ceph_osd_force_reuse, :ceph_cluster_name],
    dir: [:size, :source],
    btrfs: [:size, :source],
  }.freeze

  def validate_device
    REQUIRED_PROPS[new_resource.backend].each do |propname|
      raise "#{propname} is required for storage type #{new_resource.type}" unless new_resource.property_is_set? propname
    end
    new_resource.class.state_properties.each do |prop|
      next if prop.identity? || prop.name_property?
      next if EXCLUDE_AUTO_PROPS.include? prop.name
      next unless new_resource.property_is_set? prop.name
      raise "#{prop.name} is not valid for storage type #{new_resource.backend}" unless VALID_PROPS[new_resource.backend].include? prop.name
    end
  end

  def translate_key(keyname)
    return KEY_OVERRIDES[keyname] if KEY_OVERRIDES.key? keyname
    keyname.to_s.tr '_', '.'
  end

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
