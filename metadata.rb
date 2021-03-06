
name 'lxd_sling'
maintainer 'Sean Zachariasen'
maintainer_email 'thewyzard@hotmail.com'
license 'Apache-2.0'
description 'Installs/Configures LXD'
version '0.4.1'
chef_version '>= 13' if respond_to?(:chef_version)

# The `issues_url` points to the location where issues for this cookbook are
# tracked.  A `View Issues` link will be displayed on this cookbook's page when
# uploaded to a Supermarket.
#
issues_url 'https://github.com/nexussw/lxd_sling/issues'

# The `source_url` points to the development repository for this cookbook.  A
# `View Source` link will be displayed on this cookbook's page when uploaded to
# a Supermarket.
#
source_url 'https://github.com/nexussw/lxd_sling'

# %w( aix amazon centos fedora freebsd debian oracle mac_os_x redhat suse opensuse opensuseleap ubuntu windows zlinux ).each do |os|
#   supports os
# end
supports 'ubuntu', '>= 14.04'
