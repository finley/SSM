# Simple State Manager
**SSM** (Simple State Manager) is a tool that can be used to ensure
consistent configuration state across a large number of machines.  

SSM includes the following features, among others:

* Designed to use a simple, easy to read configuration file
* Config files may be local or accessed via http or ftp
* Config files can reference other config files that are included as "bundles"
* Ensure that installed packages match the defined configuration
* Manage the state of specific files on any Linux or Unix like OS
* Priorities for files and packages
* Designed to perform well at scale
* No daemon required on client or server


### Installation

Simple State Manager packages are available here:

    http://systemimager.org/download


### Package Management

SSM allows you to specify a list of packages that should be installed on
your managed system(s).  

Here's an example portion from a configuration
file:

        [global]
        pkg_manager = yum
        
        [packages]
        bind.x86_64
        binutils.x86_64
        bzip2-libs.x86_64
        bzip2.x86_64
        ca-certificates.noarch
        # etc...


SSM will ask your package manager to install any packages that aren't
yet on the system, and remove any that aren't in the configuration.

If no package management is desired, that's fine too:

        [global]
        pkg_manager = none


Debian packages are handled through `apt-get` and `dpkg`.  RPM packages
are handled with `yum` and `rpm`.  Support for other package managers
can be added fairly easily.


### File Management

SSM allows you to specify a desired state for files it manages.  

The desired state includes a variety of characterstics that are appropriate
based on the type of file.  Here is a list of some of the common file types
supported:

* regular
* directory
* softlink
* hardlink
* block
* character
* fifo

Here's an entry from a config file with a definition for a file of type "**regular**":

        [file]
        name   = /etc/hosts
        type   = regular
        md5sum = 27abe7c7e2423eddec0839a2d0633e37
        owner  = root
        group  = root
        mode   = 0644

When run, SSM will make sure that this file exists, that it's ownership
and permissions match the definition, and that the md5sum of it's
contents match.

If anything is out of whack, it will only fix what needs fixing, but
will prompt you first (unless you tell it not to).  If the md5sum
doesn't match, it will retrieve the proper version of the file from your
SSM repository and put it in place.

Additional SSM specific file types are also available, including the
"**generated**" file type.  A "generated" file type is similar to a
"regular" file, but the md5sum of the contents must match the output of
the "***generator***".  No md5sum is specified here, as the generator is run
locally each time the file is checked to identify the target md5sum.

        [file]
        name        = /tmp/monkey_nest/eggs
        type        = generated
        generator   = echo "monkey eggs"
        owner       = root
        group       = root
        mode        = 0664

The generator is executed verbatim, with the resultant output forming
the desired target file contents.  Testing a generator is easy, as you
can simply "scrape-n-paste" it onto your command line to see what you
get.

Here's an excellent example.  Try scraping and pasting the generator
line below to see what you get (it's OK, it's safe):

        [file]
        name       = /etc/sysconfig/network-scripts/ifcfg-eth2
        type       = generated
        generator  = HOSTNAME=$(hostname -s); IP=$(getent hosts $HOSTNAME | awk '{print $1}'); echo DEVICE=eth2; echo NM_CONTROLLED=no; echo ONBOOT=yes; echo IPADDR=$IP; echo NETMASK=255.255.255.0; echo BOOTPROTO=static; echo PEERDNS=no 
        owner      = root
        group      = root
        mode       = 0644

File definitions also support **dependencies**, **prescripts**, and **postscripts**.

Dependencies can be files, directories, and/or packages.  Simply add a
"**depends**" entry to a file definition.  In this case, our
`nightly-fs-check` cron job requires that the `lvm2` package is
installed, and that the `/usr/local/bin/snapshot` script is in place.
SSM won't auto-install `lvm2` or the `snapshot` script, but will simply
skip over this definition and let you know what happened.

        [file]
        name       = /etc/cron.d/nightly-fs-check
        type       = regular
        md5sum     = c3c530836bf259b8e66c95f8428ba858
        owner      = root
        group      = root
        mode       = 0644
        depends    = lvm2 /usr/local/bin/snapshot
        postscript = chkconfig crond on ; service crond restart
        comment    = crond should already be on, but just in case...

The postscript is executed verbatim (just like a generator), and is only
run if any other action is taken on the file, and after that action has
succeeded.  A prescript is the same as a postscript, but is executed prior
to taking any necessary action.  **Comment** entries are ignored by SSM but can
be useful for humans.


### Bundles

"**Bundles**" are just a reference to another config file whose contents get
included.  Bundles are a handy way to add capabilities to certain systems
or to provide a series of default settings for all of your systems.  

For example, you might have a "**bundle.common**" that includes your sitewide `/etc/hosts` file, ldap client configuration, and kerberos client settings.  All system types could include this bundle allowing system-wide changes in just one place.

And you might have a "**bundle.webserver**" that included the additional packages and configuration files necessary for a system to function as a webserver.

So, for machines you use to serve up static content, you could have a
configuration file called "**static_content.conf**" that looks like this:

        $ cat static_content.conf
        [global]
        pkg_manager = yum
        
        [bundles]
        bundle.common
        bundle.webserver
        
        [packages] 
        abrt-addon-ccpp.x86_64
        # etc...

And for your application server nodes, a file that looks like this:

        $ cat app_servers.conf
        [global]
        pkg_manager = yum
        
        [bundles]
        bundle.common
        bundle.caching_dns_server
        http://domain.com/bundle.app_server
        
        [packages] 
        abrt-addon-ccpp.x86_64
        # etc...

Bundles are assumed to be at the same base URL as the main config file, but can be specified as living elsewhere.

It is also possible to specify **priorities** for both files and packages for added flexibility. 

For example, if `/etc/hosts` is provided in bundle.common, it may be applicable to almost all node types at your site, but you may require a different entry for one specialty node or node type.  This entry will be used instead of the one in bundle.common, which has the default priority of zero (0).

        [file]
        name       = /etc/hosts
        type       = regular
        md5sum     = c7946y37c5596deecf586bff5ed3e2b3
        owner      = root
        group      = root
        mode       = 0644
        priority   = 99


As far as packages are concerned, you might want the stock syslog package (sysklogd) on all nodes except for your central log servers.  So in your central log servers config file, you might have a config chunk that looks like this:

        [packages]
        syslog-ng
        klogd           unwanted,priority=1
        sysklogd        unwanted,priority=1

Even though sysklogd and klogd are included for all of your other Ubuntu machines through bundle.ubuntu-quantal, this stanza says that those two packages are unwanted and should not exist on your central log servers, but that syslog-ng should certainly be installed.


Note: Conf files and bundles can be named anything you like.  Including "conf" and "bundle" in the file names is just convention and not required.


### Your SSM Repository
An SSM repository exists as a directory heirarchy that has configuration and bundle files at it's root.  A directory off the repository root is created for each regular file being managed, where a copy of each version of that file exists, named according to it's md5sum.

So, if I have three different versions of an /etc/hosts file used by different nodes in my environment, that part of my repo would look something like this:

        $ find ./etc/hosts
        ./etc/hosts
        ./etc/hosts/3fb21a815384e89972d91ee0fa6bff39
        ./etc/hosts/104ba405f283d948ada518ca49fb4681
        ./etc/hosts/2c0ef10231a2b7070cd4ebf535b772d2

This model accomplishes the following:

* It ensures that unique files of the same target name don't conflict with each other in the repository.  If a file added from a node by an admin happens to have the same md5sum, it must therefore be the same file, which is OK.
* If a node determines that it's local copy of a file is a mismatch, and must download the proper version, it implicitly knows the URL to the file (no database lookup required).
* If an admin wants to look at the contents of a file directly in the repository, they can simply look at the definition and append the md5sum to the name of the file, and open it right up.

If running interactively, and SSM determines there's an md5sum mismatch, you are given the option of seeing a diff between the two versions.  You can then choose to use the version from the repo, or to add the version on your node to the repo.

If you choose to add the local file, it will be placed in the repo (according to the repo_url in the global_setting), and the stanza referring to that file will be updated in whichever configuration file it was defined for this node.

SSM repositories may be kept under revision control.  This is highly recommended, but not required, and has no impact on SSM operation.  At one point we tried integrating a dependency on either subversion or git, but determined that it was unnecessary, and added additional complexity and dependencies which could be limiting in certain environments.


### Additional Documentation
A one-of-everything example configuration file is included in the [README](https://github.com/finley/SSM/blob/master/README).

## Project Status
SSM should be considered stable from an operational perspective.  It's fundamental design is focused on being "safe" for production environments.  

At the same time, additional features may be added, but backwards compatibility will be maintained for existing settings, and it's behavior will remain predictable.

## History
SSM was created in the spring of 2006 when a set of highly visible production servers was eaten alive by a configuration manager software that took unwanted actions.  

It was a beautiful Easter Sunday, with light snow in the air, and I had taken my family to visit relatives in another city.  The kids were hunting for Easter eggs, and I spent the rest of the visit correcting the situation and reviving this key production Internet site.

On the drive home that evening, discussions with my Wife led her to say, "Why don't you just write your own?"  Two weeks later, SSM went into production use on it's first systems.

*-Brian Finley (initial author)*


## License
http://www.gnu.org/licenses/gpl-2.0-standalone.html

