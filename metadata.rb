name 'lxd_nexus'
maintainer 'Sean Zachariasen'
maintainer_email 'thewyzard@hotmail.com'
license 'Apache'
description 'Installs/Configures LXD'
version '0.2.0'
chef_version '>= 12.1' if respond_to?(:chef_version)

# The `issues_url` points to the location where issues for this cookbook are
# tracked.  A `View Issues` link will be displayed on this cookbook's page when
# uploaded to a Supermarket.
#
issues_url 'https://github.com/nexussw/lxd_nexus/issues'

# The `source_url` points to the development repository for this cookbook.  A
# `View Source` link will be displayed on this cookbook's page when uploaded to
# a Supermarket.
#
source_url 'https://github.com/nexussw/lxd_nexus'

depends 'lxd'
