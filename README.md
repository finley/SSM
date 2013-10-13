#   Simple State Manager

SSM (Simple State Manager) is a tool that can be used to ensure consistent state across a large number of machines.  

SSM includes the following features, among others:

* Designed to use a simple, easy to read configuration file
* Config files support "bundles"
**A bundle is just a reference to another config file that gets included
* Config files may be located on the managed system, or on a central web or ftp server.
* Supports priorities
** A node specific file may have a higher priority than one in a common bundle
and packages (pkg/apt and rpm/yum based OSes) 
* Handles Debian or RPM packages on OSes that use apt-get, aptitude, or yum package managers
* Handles files on any Linux or Unix like OS
** Just specify "pkg_manager = none"
* Handles the following file types:
** regular
** directory
** softlink
** hardlink
** block
** character
** fifo

##Project Status
SSM should be considered stable from an operational perspective.  It's fundamental design is focused on being "safe" for production environments.  

At the same time, additional features may be added, but backwards compatibility will be maintained for existing settings, and it's behavior will remain predictable.

##History
SSM was created in the spring of 2006 when a set of highly visible production servers were eaten alive by a configuration manager software that took unwanted actions.  

It was a beautiful Easter Sunday, with light snow in the air, and I had taken my family to visit relatives in another city.  The kids were hunting for Easter eggs, and I spent the rest of the visit correcting the situation and reviving this key production Internet site.

On the drive home that evening, discussions with my Wife led her to say, "Why don't you just write your own?"  Two weeks later, SSM went into production use on it's first systems.

-Brian Finley (initial author)


##License
http://www.gnu.org/licenses/gpl-2.0-standalone.html

