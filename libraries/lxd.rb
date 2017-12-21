require 'yaml'
require 'openssl'
require 'chef/mixin/shell_out'

class Chef::Recipe::LXD
  include Chef::Mixin::ShellOut

  def initialize(node, lxd_dir)
    @lxd_dir = lxd_dir
    @node = node
  end

  attr_reader :lxd_dir, :node

  def info
    YAML.load exec! 'lxc info'
  end

  def exec!(cmd)
    res = exec(cmd)
    res.error!
    res.stdout
  end

  def exec(cmd)
    shell_out "env LXD_DIR=#{lxd_dir} #{cmd}"
  end

  def exec_sensitive!(cmd)
    exec! cmd
  rescue
    raise 'Command line and output suppressed due to their sensitive nature'
  end

  def version
    return node['packages']['lxd']['version'] if node['packages'].key? 'lxd'
    exec!('lxc --version').strip
  end

  def installed?(branch = nil)
    major, minor, = version.split('.', 3)
    return false if major.to_i < 2
    return true unless branch

    case branch
    when :lts then minor.to_i == 0
    when :feature then minor.to_i > 0
    end
  rescue Mixlib::ShellOut::ShellCommandFailed
    return false
  end

  class ::String
    def to_hex
      unpack('C*').collect { |c| c.to_s(16).rjust(2, '0') }.join
    end

    def self.from_hex(str)
      oldstr = str.dup
      newstr = []
      loop do
        break if oldstr.empty?
        newstr << oldstr.slice!(0, 2).to_i(16)
      end
      newstr.pack('C*')
    end
  end

  def password_hash(password, salt = nil)
    iter = 21453
    digest = OpenSSL::Digest::SHA512.new
    keylen = digest.digest_length
    salt ||= OpenSSL::Random.random_bytes(keylen)
    OpenSSL::PKCS5.pbkdf2_hmac(password, salt, iter, keylen, digest).to_hex + salt.to_hex
  end

  def state_filename
    File.join Chef::Config[:file_cache_path], 'lxd-state.yml'
  end

  def load_state_file
    return YAML.load_file(state_filename) if File.exist? state_filename
    {}
  end

  def save_state_file(state)
    File.write state_filename, state.to_yaml
  end

  def test_password(password)
    hash = load_password_hash
    salt = String.from_hex(hash[128..-1]) if hash
    return false unless salt
    hash == password_hash(password, salt)
  end

  def save_password_hash(hash)
    state = load_state_file
    state[lxd_dir] ||= {}
    state[lxd_dir]['trust_password'] = hash
    save_state_file state
  end

  def load_password_hash
    state = load_state_file
    state[lxd_dir]['trust_password'] if state.key? lxd_dir
  end
end
