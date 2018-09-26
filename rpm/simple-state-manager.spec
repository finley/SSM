Name:         simple-state-manager
Summary:      Manage the state of specific files and packages on a system.
Version:      0.7.12
Release:      1
BuildArch:    noarch
Group:        System Environment/Applications
Requires:     perl-libwww-perl, perl-MailTools, Unix-Mknod, wget, bu
Obsoletes:    ssm < 0.4.54
License:      GPLv2
URL:          http://download.systemimager.org/pub/ssm/
Source:       http://download.systemimager.org/pub/ssm/%{name}-%{version}.tar.bz2
BuildRoot:    %{_tmppath}/%{name}-%{version}-build
# buildrequires:    rpm-build, tar, make, rsync
#
# Filter out requirements for Debian specific perl libraries on RPM
# based distros. In this case, we want to filter out the following:
#
#   perl(AptPkg::Cache)
#   perl(AptPkg::Config)
#   perl(AptPkg::System)
#
# For more info, see:
#   http://fedoraproject.org/wiki/Packaging:AutoProvidesAndRequiresFiltering#Filtering_provides_and_requires_after_scanning
# 
# cat lib/SimpleStateManager/Dpkg.pm | /usr/lib/rpm/find-requires 
%global __requires_exclude perl\\(VMS|perl\\(AptPkg::


%description
Simple State Manager (ssm) allows you to define a desired state for
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
%setup -n %{name}-%{version}
ln -s rpm/find-requires-filter.sh


%build
make

%install
[ "$RPM_BUILD_ROOT" != "/" ] && [ -d $RPM_BUILD_ROOT ] && rm -rf $RPM_BUILD_ROOT
mkdir -p $RPM_BUILD_ROOT
make install DESTDIR=$RPM_BUILD_ROOT
mv $RPM_BUILD_ROOT/%{_prefix}/share/doc/%{name} $RPM_BUILD_ROOT/%{_prefix}/share/doc/%{name}-%{version}
perl -pi -e "s|share/doc/%{name}|share/doc/%{name}-%{version}|" $RPM_BUILD_ROOT/etc/ssm/defaults

%clean
[ "$RPM_BUILD_ROOT" != "/" ] && [ -d $RPM_BUILD_ROOT ] && rm -rf $RPM_BUILD_ROOT

%files
%defattr(-,root,root)
%config(noreplace) /etc/ssm/defaults
%config(noreplace) /etc/ssm/localhost
%{_prefix}/lib/*
%{_prefix}/sbin/*
%{_prefix}/share/*


# Get date command:   
#
#   sh echo -n "* " ; date +'%a %b %d %Y - brian@thefinleys.com'
#
%changelog -n %{name}
* Sun May 11 2014 - brian@thefinleys.com
- improve side-by-side diff verbiage
- /etc/ssm/client.conf deprecated and renamed to /etc/ssm/defaults
- change all references to definition_file to config_file
- Include starter_config_file.conf based on
  safe_to_run_example_config_file.conf, but all commented out.
- rename state_definition_config_file.conf ->
  safe_to_run_example_config_file.conf
- rename state_definition_config_file.conf ->
  safe_to_run_example_config_file.conf
- add bundle example in example file
- reflect new library location
- do side-by-side diff instead of unified
- Change package name from ssm to simple-state-manager
- Clean up ssm droppings (/tmp/*system-state-manager*tmp* files) left by
  do_generated_file()
- don't try to pull from repo for diff if generated file
- change exit code to be 0 on successful run, rather than report number
  of outstanding changes.
- Change 'answer_no' variable to simply 'no' (let your yes be yes, and
  your no be no)
- Improve do_you_want_me_to() to automatically provide relevant prompts
  based on the $arguments variable (ie.: 'yn')
- Further genericize invocation of action subroutines (from take_action)
  by variablizing tmp files when implied.
- Further standardize output.  Common output strings emitted by
  'take_action()' now, instead of by calling function.
- Rename variable 'just_fix_uid_gid_and_mode' to match the function that
  we actually invoke: 'set_ownership_and_permissions'
- Improve the 'take_action()' function
- Improve the 'install_file()' function
- Improve example ifcfg-eth2 file
- ensure proper outstanding element counts for unsatisfied deps and soft
  links
- rename sub _add_file_to_repo to add_file_to_repo
- rename sub _backup to backup
- line up certain output to make easier to read
- don't incorrectly warn that targets don't exist for relative symlinks
- new function -> take_action() that allows interactive looping on
  actions that partially fail, such as for a diff or install on a file
  that doesn't exist. (Marc Roskow suggestion)
- Clear and easy explanation of examples directory
- improve clarity of description of actions and options (Marc Roskow
  request)
- Shift 'FIXING:' entries over to make obvious as part of above change.
- Only have one blank line after "Shall I do this?"
* Mon Mar 24 2014 - brian@thefinleys.com
- ssm (0.4.53-1) stable; urgency=low
- don't double-ask shall i do this for soft links 
* Mon Mar 24 2014 - brian@thefinleys.com
- ssm (0.4.52-1) stable; urgency=low
- Using new deb building procedure.
- Using new rpm building procedure.
- Fixed default links to example file.
* Sat Mar 22 2014 - brian@thefinleys.com
- Added "--summary" option.
- Drastically improve method for determining status of outstanding changes
- Don't use bare system directories to specify file locations for RPM creation (fedora20 don't likey)
* Fri Mar 21 2014 - brian@thefinleys.com
- normalize error reporting on debug
- add 'warn' option to get_file().  in other words, don't fail if SSM
  tries to download a file that ain't in the repo, but warn the user.
- don't pause for one second if a hard link target doesn't exist
- File add support improved and moved into the main ssm command.
- no longer exit w/1 with no pkg_manager warning, and move the please_specify_a_package_manager subrouting to a less odd location
- File add support improved and moved into the main ssm command.
- Improved help output
- moved the good bits back into examples
- copyright date
- minor output verbiage change
- verify absolute path of file for user presentation as well as repo update.
- undef sync_state if --af
- Don't require root to build RPM
- Copy RPMs to ./tmp dir and list
- Have '--af' override '--sync' rather than fail.
- Handle "ssm --af file" without user specified fully qualified path.
* Mon Feb 24 2014 - brian@thefinleys.com
- Fix testing of command line argument that resulted in the following error message: "Can't use an undefined value as an ARRAY reference at /usr/sbin/ssm line 146."
* Sat Feb 22 2014 - brian@thefinleys.com
- Fix minor bug with --yes option introduced in 0.4.47 testing release.
* Tue Feb 18 2014 - brian@thefinleys.com
- v0.4.47 testing
- Added the --add-file FILE option.  Allows adding files to definition via the ssm command line.
- Handle manpage creation better.
- Improve verbiage on help output.
* Sun Feb 09 2014 - brian@thefinleys.com
- v0.4.46
* Tue Dec 18 2012 - brian@thefinleys.com
- v0.4.45
- Tweak to do_you_want_me_to()
- Renaming of things to match name
* Mon Dec 17 2012 - brian@thefinleys.com
- v0.4.44
- Further improve do_you_want_me_to() for simpler user interaction.
- Re-arranged README file(s).
* Thu Dec 13 2012 - brian@thefinleys.com
- v0.4.43
- Improve do_you_want_me_to() to only present relative options based on
  the activity in question (Ie.: pkg sync vs. file sync).
- Improve yum dependency resolution to process STDERR as well as STDOUT
  from yum commands.
- Simplify options and modify help verbiage.
* Thu Dec 13 2012 - brian@thefinleys.com
- v0.4.42
- Fix regex to match and upgrade ssm if appropriate.
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
* Mon Oct 22 2012 - brian@thefinleys.com
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
* Tue Dec 01 2009 - brian@thefinleys.com
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
- SimpleStateManager.pm: Fix bug found by Gene Rackow where diff_file()
  didn't clean up tmp_file.
- Add support for 'aptitude': Aptitude.pm
- Remove info/examples on package versions
- Dpkg.pm: do apt-get update even on --no
* Thu Dec 18 2008 - brian@thefinleys.com
- ssm_web-report: improve coloration
- Yum.pm: use ssm.noarch instead of ssm for upgrade_ssm() function
- SimpleStateManager.pm: Test variables from def files for existence
  before applying regex tests to them
- SimpleStateManager.pm: read_definition_file() now returns $ERROR_LEVEL
  instead of undef
- ssm_web-report: fix bug in critical_packages regex
- ssm_web-report: improve layout; add page timestamp
* Thu Dec 04 2008 - brian@thefinleys.com
- Minor package change -- don't include ssm_web-report binary.  It
  causes rpm to require a package that is unsatisfiable on CentOS or Red
  Hat.
* Wed Dec 03 2008 - brian@thefinleys.com
- SimpleStateManager.pm: change format of date stamp
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
- SimpleStateManager.pm: add email_log_file()
- SimpleStateManager.pm: close logfile before mailing
- Ensure uniqueness of entries in package deps lists
- SimpleStateManager.pm: display packages to upgrade/remove/install with
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
* Tue Oct 28 2008 - brian@thefinleys.com
- initial package
