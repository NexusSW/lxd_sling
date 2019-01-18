
require 'yaml'

coercions = {
  sym: ->(val) { val.to_sym },
  int: ->(val) { val.to_i },
  bool: ->(val) { val.is_a?(String) ? (val.downcase == 'true' ? true : false) : val }, # rubocop:disable Style/NestedTernaryOperator
}

property :device_name, String, name_property: true
property :server_path, String, identity: true # default: '/var/lib/lxd',

property :location, [:profile, :container], required: true, identity: true
property :location_name, String, required: true, identity: true
property :type, [:none, :nic, :disk, :unix_char, :unix_block, :usb, :gpu, :infiniband], required: true, coerce: coercions[:sym]

# :nic settings
property :nictype, [:bridged, :macvlan, :p2p, :physical, :sriov], coerce: coercions[:sym]
property :limits_ingress, [String, nil]
property :limits_egress, [String, nil]
property :limits_max, [String, nil]
property :hostname, [String, nil]
property :hwaddr, [String, nil]
property :mtu, [Integer, nil], coerce: coercions[:int]
property :parent, [String, nil]
property :vlan, [Integer, nil], coerce: coercions[:int]
property :ipv4_address, [String, nil]
property :ipv6_address, [String, nil]
property :security_mac_filtering, [true, false, nil], coerce: coercions[:bool]

# :infiniband settings
# re-uses above nictype, hwaddr, parent, mtu

# :disk settings
property :limits_read, [String, nil]
property :limits_write, [String, nil]
# re-use :limits_max
property :path, [String, nil]
property :source, [String, nil]
property :optional, [true, false, nil], coerce: coercions[:bool]
property :readonly, [true, false, nil], coerce: coercions[:bool]
property :size, [String, nil]
property :recursive, [true, false, nil], coerce: coercions[:bool]
property :pool, [String, nil]

# :unix_char and :unix_block settings
# re-use source & path
property :major, [Integer, nil], coerce: coercions[:int]
property :minor, [Integer, nil], coerce: coercions[:int]
property :uid, [Integer, nil], coerce: coercions[:int]
property :gid, [Integer, nil], coerce: coercions[:int]
property :mode, [Integer, nil], coerce: coercions[:int]

# :usb settigns
# re-use uid, gid, mode
property :vendorid, [String, nil]
property :productid, [String, nil]
property :required, [true, false, nil], coerce: coercions[:bool]

# :gpu settings
# re-use uid, gid, mode, vendorid, productid
property :id, [String, nil]
property :pci, [String, nil]

include Chef::Recipe::LXD::Mixin

resource_name :lxd_device

class Chef::Recipe::LXD
  def device_cmd(resource, subcommand)
    scope = (resource.location == :profile) ? 'profile' : 'config'
    "lxc #{scope} device #{subcommand} #{resource.location_name}"
  end
end

load_current_value do
  devices = YAML.load(lxd.exec!(lxd.device_cmd(self, 'show')))
  return unless devices.key? device_name
  devices[device_name].each do |key, val|
    send key.tr('.', '_'), val
  end
end

action :create do
  return action_modify if exists?
  validate_device
  cmd = lxd.device_cmd new_resource, 'add'
  cmd += " #{new_resource.device_name} #{translate_type(new_resource.type)}"
  new_resource.class.state_properties.each do |prop|
    next if prop.identity? || prop.name_property?
    next if EXCLUDE_AUTO_PROPS.include? prop.name
    next unless new_resource.property_is_set? prop.name
    val = new_resource.send prop.name
    next unless val
    cmd += " #{translate_key(prop.name)}='#{val}'"
  end
  converge_by "create device (#{new_resource.device_name}) in #{new_resource.location} '#{new_resource.location_name}'" do
    lxd.exec! cmd
  end
end

action :modify do
  validate_device
  setcmd = lxd.device_cmd new_resource, 'set'
  unsetcmd = lxd.device_cmd new_resource, 'unset'
  setcmd += " #{new_resource.device_name} "
  unsetcmd += " #{new_resource.device_name} "
  new_resource.class.state_properties.each do |prop|
    next if prop.identity? || prop.name_property?
    next if EXCLUDE_AUTO_PROPS.include? prop.name
    next unless new_resource.property_is_set? prop.name
    val = new_resource.send(prop.name).to_s
    converge_if_changed prop.name do
      cmd = (val && !val.empty?) ? (setcmd + "#{translate_key(prop.name)} '#{val}'") : (unsetcmd + translate_key(prop.name))
      lxd.exec! cmd
    end
  end
end

action :delete do
  converge_by "delete device (#{new_resource.device_name}) from #{new_resource.location} '#{new_resource.location_name}'" do
    lxd.exec! lxd.device_cmd(new_resource, 'remove') + " #{new_resource.device_name}"
  end if exists?
end

action_class do
  include Chef::Recipe::LXD::ActionMixin

  KEY_OVERRIDES = {
    security_mac_filtering: 'security.mac_filtering',
  }.freeze
  EXCLUDE_AUTO_PROPS = [:type].freeze

  def exists?
    YAML.load(lxd.exec!(lxd.device_cmd(new_resource, 'show'))).key? new_resource.device_name
  end

  def translate_type(type)
    type.to_s.tr '_', '-'
  end

  def translate_key(keyname)
    return KEY_OVERRIDES[keyname] if KEY_OVERRIDES.key? keyname
    keyname.to_s.tr '_', '.'
  end

  REQUIRED_PROPS = {
    none: [],
    nic: [:nictype, :parent],
    infiniband: [:nictype, :parent],
    disk: [:path], # , :source], # TODO: research the 'requiredesness' of 'source'...  not needed for the rootfs device
    unix_char: [],
    unix_block: [],
    usb: [:vendorid],
    gpu: [],
  }.freeze
  VALID_PROPS = {
    none: [],
    nic: [:nictype, :parent, :limits_egress, :limits_ingress, :limits_max, :hostname, :hwaddr, :mtu, :vlan, :ipv4_address, :ipv6_address, :security_mac_filtering],
    infiniband: [:nictype, :parent, :hwaddr, :mtu],
    disk: [:path, :source, :limits_read, :limits_write, :limits_max, :path, :source, :optional, :readonly, :size, :recursive, :pool],
    unix_char: [:source, :path, :major, :minor, :uid, :gid, :mode, :required],
    unix_block: [:source, :path, :major, :minor, :uid, :gid, :mode, :required],
    usb: [:vendorid, :uid, :gid, :mode, :productid, :required],
    gpu: [:uid, :gid, :mode, :vendorid, :productid, :id, :pci],
  }.freeze
  def validate_device
    REQUIRED_PROPS[new_resource.type].each do |propname|
      raise "#{propname} is required for device type #{new_resource.type}" unless new_resource.property_is_set? propname
    end
    new_resource.class.state_properties.each do |prop|
      next if prop.identity? || prop.name_property?
      next if EXCLUDE_AUTO_PROPS.include? prop.name
      next unless new_resource.property_is_set? prop.name
      raise "#{prop.name} is not valid for device type #{new_resource.type}" unless VALID_PROPS[new_resource.type].include? prop.name
    end
  end
end
