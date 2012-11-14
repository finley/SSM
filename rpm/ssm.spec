Name:         ssm
Summary:      Manage the state of specific files and packages on a system.
Version:      0.4.41
Release:      1
BuildArch:    noarch
Group:        System Environment/Applications
Requires:     perl-libwww-perl, perl-MailTools, Unix-Mknod, wget
License:      GPL
URL:          http://download.systemimager.org/pub/ssm/
Source:       http://download.systemimager.org/pub/ssm/ssm-%{version}.tar.bz2
BuildRoot:    %{_tmppath}/%{name}-%{version}-build

%description
System State Manager (ssm) allows you to define a desired state for
one or more machines.  This state can include:
* a complete list of packages to be installed (optional)
* version information for some or all packages (optional)
* files that should be in place, and appropriate attributes (optional)
  * regular files (content via md5sum)
  * character, block, and fifo files
  * permissions and ownership
  * soft links and hard links
  * unwanted files and directories (that should be removed)
.
If an defined element of a system is not in the desired state, the
ssm client can fix it, always prompting you before taking action.
Prompting can be suppressed with a --yes option.
.  
State information for a machine is kept in a state definition file,
which can be stored in a location that the ssm client can access via
http:, https:, ftp:, or on the local filesystem.  State definition
files are simple to create, and are easy to read and understand.
.
http://download.systemimager.org/pub/ssm/


%prep
%setup -n ssm-%{version}


%build
make

%install
[ "$RPM_BUILD_ROOT" != "/" ] && [ -d $RPM_BUILD_ROOT ] && rm -rf $RPM_BUILD_ROOT
mkdir -p $RPM_BUILD_ROOT
make install DESTDIR=$RPM_BUILD_ROOT
mv $RPM_BUILD_ROOT/%{_prefix}/share/doc/ssm $RPM_BUILD_ROOT/%{_prefix}/share/doc/ssm-%{version}
rm -f $RPM_BUILD_ROOT/%{_prefix}/sbin/ssm_web-report    # This requires deps unsatisfiable -BEF-

%clean
[ "$RPM_BUILD_ROOT" != "/" ] && [ -d $RPM_BUILD_ROOT ] && rm -rf $RPM_BUILD_ROOT

%files
%defattr(-,root,root)
%config(noreplace) /etc/ssm/client.conf
%{_prefix}/lib/ssm/SystemStateManager.pm
%{_prefix}/lib/ssm/SystemStateManager/
%{_prefix}/sbin/
%{_prefix}/share/doc/ssm-%{version}/README.state_definition_file_details
%{_prefix}/share/doc/ssm-%{version}/examples/README
%{_prefix}/share/doc/ssm-%{version}/examples/one-of-each.conf
%{_prefix}/share/doc/ssm-%{version}/examples/tmp/one-regular-file.txt/27abe7c7e2423eddec0839a2d0633e37
%{_prefix}/share/doc/ssm-%{version}/ChangeLog
%{_prefix}/share/doc/ssm-%{version}/COPYING
%{_prefix}/share/doc/ssm-%{version}/CREDITS


# Get date command:   
#
#   sh echo -n "* " ; date +'%a %b %d %Y - brian@thefinleys.com'
#
%changelog -n ssm
* Wed Nov 14 2012 - brian@thefinleys.com
- v0.4.41
- Add support for ssh:// for upstream repos
* Wed Nov 07 2012 - brian@thefinleys.com
- v0.4.40
- Dump support for git and svn -- no real need, and much complication.
  Allow revision control to be handled by the upstream repository, if
  desired.  And if not -- eh, no big.  Just make regular backups, eh?
* Wed Nov 07 2012 - brian@thefinleys.com
- v0.4.39
- Allow for a non revision control managed upstream repo
* Mon Nov 05 2012 - brian@thefinleys.com
- v0.4.38
- Update entry in bundlfile when (a)
- Make sure files added to repo have accessible perms
* Mon Oct 29 2012 - brian@thefinleys.com
- Auto push changes to git repos of type "file://"
* Wed Oct 22 2012 - brian@thefinleys.com
- Add git support.
* Wed Oct 10 2012 - brian@thefinleys.com
- Prep for move to new repo.
* Mon Sep 20 2010 - brian@thefinleys.com
- Add ability to specify permissions on log file via state definition
  file.
- Performance improvement: in check_depends(), only get pkg_list if
  there's a pkg in the dep list
* Wed Sep 01 2010 - brian@thefinleys.com
- minimize output when --only-this-file
- Modify behavior of chown+chmod file type: create file if non-existent
* Sun Aug 29 2010 - brian@thefinleys.com
- Add Lehman's chown+chmod feature request.
* Wed Jul 28 2010 - brian@thefinleys.com
- Fix harmless bug where remove_running_kernel wasn't _officially_
  defaulted to 'no'
* Wed Jul 28 2010 - brian@thefinleys.com
- Add --analyze-config option
- Include bundle name when error out on conflicting files
- Add print_pad() subroutine to improve analyze output
- Add multisort() function to sort array based on fields within each
  line
- Handle don't remove running kernel package
- include @pkgs_to_be_removed_deps as well as @pkgs_to_be_removed when
  reporting $OUTSTANDING_PACKAGES_TO_REMOVE
* Fri May 21 2010 - brian@thefinleys.com
- Change order of package operations from: 1) Remove  2) Upgrade 3)
  Install to: 1) Install 2) Upgrade 3) Remove
- Break out package remove, upgrade, install, and reinstall into
  subroutines
- change order of comment and name in check-in output
* Mon Dec 01 2009 - brian@thefinleys.com
- Add directory+contents-unwanted file type.  Create directory and
  maintain permissions and ownership on the directory, just like a
  simple "type = directory".  Plus, any contents of this directory that
  are not defined (elsewhere in the configuration) will be marked as
  unwanted.
- Turn double slashes into single slashes so that tests for conflicting
  host names work properly.
- Turn directories specified with an ending slash into no ending slash
  to ensure conflicting directory names are treated properly.
* Mon Nov 16 2009 - brian@thefinleys.com
- Add a couple of debug entries.
- In the _add_file() function, Allow SVN to just cache the password --
  things break otherwise, but unlink the cache file after the SVN
  operation section.  Only unlinks the cache file for the ANL SVN
  server.
* Mon Nov 16 2009 - brian@thefinleys.com
- Added diff_ownership_and_permissions() function.
- When "Need to fix ownership and permissions" is displayed, also show
  the existing and target permissions for the file.
- When doing a "diff", also diff_ownership_and_permissions().
- Fix a couple of places where svn was being called without the
  --no-auth-cache option.  All svn calls should now be made using the
   $svn variable. SVN v1.6 will allow for secure on-disk caching of the
   password.  At that point, we can consider removal of this option.
- Added show_diff_comments() function.
  * Only do for relevant file types (!generated)
- Added a "c" for "comments" option to [N/y/d/a].  It now looks like
  [N/y/d/c/a] for regular files.
- add one little bit of debug output
- keep 49 log files, instead of 7
* Thu Sep 24 2009 - brian@thefinleys.com
- remove get_pkgs_ssm_says_to_upgrade() function -- no longer necessary
- fix a bug in parsing package lists that was introduced by the package
  priority code.
- fix datestamp in ssm reporting (was reporting one month behind)
* Tue Sep 22 2009 - brian@thefinleys.com
- Handle package priorities.
- include a #depends example in created config snippets for added files
- Fix bug where a package modifies a file, but SSM doesn't loop back to
  check the file again.  
- Incorporate 'changes_made' as well as 'error_level' and report on
  both.
- Fix bug where --only-files or --only-file failed to find a satisfied
  dependency on a package.
- Added 'generated' file type
- Example file: Added 'generated' file type example
- diff_file():  Added ability to pass two files to this subroutine
* Mon May 18 2009 - brian@thefinleys.com
- ssm: Add --only-files and --only-packages features.
- ssm: added --only-this-file option
- ssm_web-report: auto-refresh generated html page
* Wed Apr 01 2009 - brian@thefinleys.com
- SystemStateManager.pm: Fix bug found by Gene Rackow where diff_file()
  didn't clean up tmp_file.
- Add support for 'aptitude': Aptitude.pm
- Remove info/examples on package versions
- Dpkg.pm: do apt-get update even on --no
* Thu Dec 18 2008 - brian@thefinleys.com
- ssm_web-report: improve coloration
- Yum.pm: use ssm.noarch instead of ssm for upgrade_ssm() function
- SystemStateManager.pm: Test variables from def files for existence
  before applying regex tests to them
- SystemStateManager.pm: read_definition_file() now returns $ERROR_LEVEL
  instead of undef
- ssm_web-report: fix bug in critical_packages regex
- ssm_web-report: improve layout; add page timestamp
* Thu Dec 04 2008 - brian@thefinleys.com
- Minor package change -- don't include ssm_web-report binary.  It
  causes rpm to require a package that is unsatisfiable on CentOS or Red
  Hat.
* Wed Dec 03 2008 - brian@thefinleys.com
- SystemStateManager.pm: change format of date stamp
- ssm_web-report: s/Unclean/Dirty
- ssm_web-report: Take command line options.
- ssm_web-report: Allow read from specified INBOX, not just STDIN.
- ssm_web-report: Create index.html and $host.txt files as mode 644.
- ssm_web-report: Add titles for count sections.
- use pure perl 'date'; improve date format for web reporting
* Mon Dec 01 2008 - brian@thefinleys.com
- new release. 0.4.20
- ssm, ssm_web-report:  Add additional count info to logs and to web
  report.
* Tue Nov 18 2008 - brian@thefinleys.com
- new release. 0.4.19
- SystemStateManager.pm: add email_log_file()
- SystemStateManager.pm: close logfile before mailing
- Ensure uniqueness of entries in package deps lists
- SystemStateManager.pm: display packages to upgrade/remove/install with
  --no
* Fri Nov 07 2008 - brian@thefinleys.com
- new release. 0.4.18
- ssm: Don't loop if --no
- YUM: do workaround to handle stoopid rpm inconsistency ->
  gpg-pubkey.(none) non-package
- YUM: fix modify get_pkgs_currently_installed to address yum fixed
  length output issue -- was truncating certain long package names
* Wed Oct 29 2008 - brian@thefinleys.com
- new release. 0.4.17
* Sun Oct 28 2008 - brian@thefinleys.com
- initial package
