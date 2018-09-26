#  
#   Copyright (C) 2006-2018 Brian Elliott Finley
#
#    vi: set filetype=perl tw=0 number:
#
# 2008.09.12 Brian Elliott Finley
#   * ssm_print function added -- print output to screen and logfile
#   * use the rotate_log_file function
# 2008.11.18 Brian Elliott Finley
#   * add email_log_file()
# 2009.09.22 Brian Elliott Finley
#   * Add priority capability to packages
#       * check for and store package options
#       * compare priorities
#       * add 'unwanted' option for packages
# 2012.10.28 Brian Elliott Finley
#   * Add support for git repositories
#   * Actually put the config chunk in place for git repositories
# 2012.11.05 Brian Elliott Finley
#   - Make sure files added to repo have accessible perms
# 2012.11.07 Brian Elliott Finley
#   - Allow for a non revision control managed upstream repo
#   - Dump support for git and svn -- no real need, and much complication.
#     Allow revision control to be handled by the upstream repository, if
#     desired.  And if not -- eh, no big.  Just make regular backups, eh?
# 2012.11.07 Brian Elliott Finley
#   - Add support for ssh:// for upstream repos
# 2014.03.11 Brian Elliott Finley
#   - Future changes logged via git log


package SimpleStateManager;

use Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(   
                version
                user_is_root
                get_current_state
                read_config_file
                sync_state
                ssm_print 
                run_cmd
                choose_tmp_file
                email_log_file
                add_new_files
                add_new_packages
                rename_file
                export_config
            );

use strict;

# Filesystem related
use File::Copy;
#                 Use 'make_path' as preferred to 'mkpath' or 'mkdir -p'
use File::Path qw(make_path remove_tree);
use File::Basename;
use Unix::Mknod qw(:all);
use File::stat qw(:FIELDS);
#
# The POSIX library (with qw(mkfifo)) is exporting the S_IS* functions, so we
# need to limit which functions Fcntl exports by explicitly listing the ones
# we need. -BEF-
use POSIX qw(mkfifo);
use Fcntl qw( :mode );
use Digest::MD5;
use Cwd 'abs_path';

# Network related
use LWP::Simple;
use Mail::Send;

# SimpleStateManager related
use SimpleStateManager::Filesystem;


################################################################################
#
#   This package provides the following functions:
#
#       % egrep '^sub ' lib/SimpleStateManager.pm | perl -p -e 's/^sub /#   /; s/\s+{\s+$//;' | sort
#
#   add_bundlefile_stanza_to_bundlefile
#   add_file_to_repo
#   add_file_to_repo_type_nonRegular
#   add_file_to_repo_type_regular
#   add_new_files
#   add_new_packages
#   add_package_stanza_to_bundlefile
#   add_packages_to_repo
#   assign_state_to_thingy
#   autoremove_packages_interactive
#   backup
#   check_depends
#   check_depends_interactive
#   choose_tmp_file
#   choose_valid_bundlefile
#   chown_and_chmod_interactive
#   close_log_file
#   compare_package_options
#   contents_unwanted_interactive
#   copy_file_to_upstream_repo
#   declare_file_actions
#   declare_OK_or_Not_OK
#   diff_file
#   diff_ownership_and_permissions
#   directory_interactive
#   do_you_want_me_to
#   email_log_file
#   execute_postscript
#   execute_prescript
#   export_config
#   fully_qualified_file_name
#   generated_file_interactive
#   _get_arch
#   get_current_time_as_timestamp
#   get_file
#   get_file_type
#   get_gid
#   get_hostname
#   get_major
#   get_md5sum
#   get_minor
#   get_mode
#   get_pad
#   get_pkgs_to_be_installed
#   get_uid
#   group_to_gid
#   hardlink_interactive
#   ignore_file_interactive
#   _include_bundle
#   _initialize_log_file
#   _initialize_variables
#   install_directory
#   install_file
#   install_hardlink
#   install_packages_interactive
#   install_softlink
#   install_special_file
#   list_bundlefiles
#   load_pkg_manager_functions
#   md5sum_match
#   multisort
#   please_specify_a_valid_pkg_manager
#   print_pad
#   read_config_file
#   regular_file_interactive
#   remove_file
#   remove_packages_interactive
#   rename_file
#   report_conflicting_definitions()
#   report_improper_file_definition
#   report_improper_service_definition
#   rotate_log_file
#   run_cmd
#   set_ownership_and_permissions
#   show_debug_output_for_filespec
#   softlink_interactive
#   special_file_interactive
#   _specify_an_upload_url
#   ssm_print
#   ssm_print_always
#   sync_state
#   take_file_action
#   take_pkg_action
#   touch
#   turn_groupnames_into_gids
#   turn_service_into_file_entry
#   turn_usernames_into_uids
#   uid_gid_and_mode_match
#   unwanted_file_interactive
#   update_bundle_file_comment_out_entry
#   update_or_add_file_stanza_to_bundlefile
#   update_package_repository_info_interactive
#   upgrade_packages_interactive
#   user_is_root
#   user_to_uid
#   verify_packages_exist
#   version
#   _which
#
################################################################################

################################################################################
#
#   Variables and What Not
#
my $STATE_DIR = "/var/lib/simple-state-manager";
my $PKG_REPO_UPDATE_TIMESTAMP_FILE = "$STATE_DIR/PKG_REPO_UPDATE_TIMESTAMP_FILE";
#
# Hashes for holding file and service information
my %CONF;  
    #
    # Holds entire state definition data structure.  Here's the layout.  
    # Not all element types (etype) will have all attributes.
    #
    # $CONF = {
    #   $etype = {  # etype/element type can be: file, variable, service
    #     'name' => $name,
    #       # duh
    #
    #     'type' => $type,
    #       # regular, block, character, fifo, softlink, hardlink,
    #       # unwanted, directory+contents-unwanted, ignored, or generated.
    #
    #     'mode' => $mode,
    #     'owner' => $owner,
    #     'group' => $group,
    #     'md5sum' => $md5sum,
    #     'major' => $major,
    #     'minor' => $minor,
    #     'target' => $target,
    #       # target file or directory for a link
    #
    #     'prescript' => $prescript,
    #       # script or command to be run before installing a file
    #
    #     'postscript' => $postscript,
    #       # script or command to be run after installing a file
    #
    #     'depends' => $depends,
    #       # package and, or file dependencies
    #
    #     'details' => $details,
    #       # runlevel information for services
    #
    #     'generator' => $generator,
    #       # script or command to run to generate a generated file
    #
    #     'bundlefile' => $bundlefile,
    #       # name of bundlefile where each file or package is defined
    # }
    #
              

my (
    %BUNDLEFILE,  # name of bundlefile where each file or package is defined

    %BUNDLEFILE_LIST,   # simple list of bundle files
);

my $OUTSTANDING_PACKAGES_TO_INSTALL   = 0;
my $OUTSTANDING_PACKAGES_TO_REMOVE    = 0;
my $OUTSTANDING_PACKAGES_TO_UPGRADE   = 0;

my $ERROR_LEVEL  = 0;
my $CHANGES_MADE = 0;
our $LOGFILE;
my $repo_access_verified = 0;
my %valid_pkg_managers = (
                            'dpkg'     => 'Dpkg',
                            'aptitude' => 'Dpkg',
                            'apt-get'  => 'Dpkg',
                            'apt'      => 'Dpkg',
                            'yum'      => 'Yum',
                            'zypper'   => 'Zypper',
                            'none'     => 'None',
                         ); # pkgmgr   =>  SSM Module to use

#
################################################################################

################################################################################
#
#   Subroutines
#
# ssm_print_always "thing to print";
sub ssm_print_always {

    my $content = shift;

    print STDOUT   $content;
    print $LOGFILE $content;

    return 1;
}

# ssm_print "thing to print";
sub ssm_print {

    if( $::PASS_NUMBER == 1 ) {
        return 1 unless($::o{debug}); 
    }

    my $content = shift;
    
    print STDOUT   $content;
    print $LOGFILE $content;

    return 1;
}

sub _initialize_variables {

    (   %::PKGS_FROM_STATE_DEFINITION,
        %::VARS_FROM_STATE_DEFINITION,
        %CONF,
        %BUNDLEFILE,
        %BUNDLEFILE_LIST,
    ) = ();
    
    $ERROR_LEVEL = 0;

    return 1;
}


#
# Usage:  my $timestamp = get_current_time_as_timestamp();
#
sub get_current_time_as_timestamp {

    my ($sec,$min,$hour,$day,$month,$year,$wday,$yday,$isdst) = localtime(time);

    $year   += 1900;
    $month  = sprintf("%02d", $month + 1);
    $day    = sprintf("%02d", $day);
    $hour   = sprintf("%02d", $hour);
    $min    = sprintf("%02d", $min);
    $sec    = sprintf("%02d", $sec);

    # Result is => 2014-06-04 13:11:55
    return "$year-$month-$day $hour:$min:$sec";
}


sub _initialize_log_file {

    my $log_dir  = "/var/log/ssm";
    my $log_file = $log_dir . "/" . basename($0);

    if( ! -d $log_dir ) {

        my $tmp_file;

        if( -f $log_dir ) {

            my $name = $log_dir;
            $tmp_file = choose_tmp_file();

            copy("$name","$tmp_file") or die "Couldn't copy $name to $tmp_file\n";
            unlink $name;
        }

        my $dir = $log_dir;
        eval { make_path("$dir", { verbose => 0, mode => 0775, }) };
        if($@) { 
            print "Couldn’t create ssm log dir $dir\n";
            exit 1;
        }

        if( $tmp_file ) {
            move("$tmp_file","$log_file") or die "Couldn't move $tmp_file to $log_file\n";
        }
    }

    my $starting_lognumber = 1;
    my $ending_lognumber = 49;
    rotate_log_file($log_file, $starting_lognumber, $ending_lognumber);

    umask 0027;
    open(LOGFILE,">$log_file") or die("Couldn't open $log_file for writing!");
    $LOGFILE = *LOGFILE;

    my $timestamp = get_current_time_as_timestamp();
    print LOGFILE "TIMESTAMP: $timestamp\n";

    #
    # Can't write output to log file until we've initilized it... -BEF-
    #
    if( $::o{debug} ) { ssm_print "_initialize_log_file()\n"; }

    return 1;
}


sub read_config_file {

    _initialize_variables();

    _initialize_log_file();

    #
    # This entry must be below the initializations above so that the symbol
    # reference to the log file is defined before we try to print to it, eh.
    # ;-) -BEF-
    #
    if( $::o{debug} ) { ssm_print "read_config_file()\n"; }

    my @analyze;

    if( ! defined($::o{config_file}) ) {
        
        my $file = '/etc/ssm/defaults';

        if( -e '/etc/ssm/client.conf' ) {

            $file = '/etc/ssm/client.conf';

            ssm_print_always qq(\n);
            ssm_print_always qq(/etc/ssm/client.conf is deprecated in favor of /etc/ssm/defaults.  Please run\n);
            ssm_print_always qq/this command to rename it and make this message go away. ;-)\n/;
            ssm_print_always qq(\n);
            ssm_print_always qq(    mv /etc/ssm/client.conf /etc/ssm/defaults\n);
            ssm_print_always qq(\n);
            ssm_print_always qq(Thanks!  --TheMgmt\n);
            ssm_print_always qq(\n);

            sleep 3;

            # Quick check to see if it was just done...
            if( ! -e '/etc/ssm/client.conf' ) { $file = '/etc/ssm/defaults'; }
        }

        open(FILE,"<$file") or die("Couldn't open $file for reading. $!\n");
            while(<FILE>) {
                if(m/^config_file\s+(.*)(\s|#|$)/) {
                    $::o{config_file} = $1;
                }
                elsif(m/^definition_file\s+(.*)(\s|#|$)/) {
                    # support deprecated definition_file name
                    $::o{config_file} = $1;
                }
            }
        close(FILE);
    }

    if( ! defined($::o{config_file}) ) {
        # still not defined?

        &main::usage();
        ssm_print_always qq(\n);
        ssm_print_always qq(ERROR:\n);
        ssm_print_always qq(\n);
        ssm_print_always qq(    Please specify a config file.  This can be done on the command line,\n);
        ssm_print_always qq(    or by adding an entry to /etc/ssm/defaults.\n);
        ssm_print_always qq(\n);
        ssm_print_always qq(           Try: "--config URL"\n);
        ssm_print_always qq(\n);
        exit 1;
    }

    if( $::o{config_file} =~ m,/$, ) {
        # URI ends with a slash.  Is a dir.  Append hostname
        $::o{config_file} .= get_hostname();
    }

    if( $::o{config_file} !~ m|:/| ) {
        #
        # Hmm.  No URL prefix indicated.  Guessing that it is a file:// style URL
        #
        if( $::o{config_file} !~ m|^/| ) {
            #
            # Must be a _relative_ file name.  We can handle that too.
            #
            my $cwd     = getcwd();
            $::o{config_file} = "file://$cwd/$::o{config_file}";

        } else {
            $::o{config_file} = "file://$::o{config_file}";
        }
    }

    ssm_print "\nConfiguration File: $::o{config_file}\n" unless($::o{only_this_file});

    my $tmp_file = get_file($::o{config_file}, 'error');

    #
    # We assume base_url should be the same as the main configuration file url, sans
    # the filename itself. This will be overridden if specified in a [global]
    # section. -BEF-
    #
    $::o{base_url}  = dirname( $::o{config_file} );

    #
    # And let's let the bundlefile name simply be the file (no URL).
    #
    my $bundlefile      = $::o{config_file};
    $bundlefile         =~ s|^$::o{base_url}/+||;

    # For --analyze-config purposes, prefix the input data from the
    # main configuration file with it's own name as a BundleFile. -BEF-
    my @input = "BundleFile: $bundlefile\n";
    push @input, "\n";

    open(FILE,"<$tmp_file") or die "Couldn't open $tmp_file for reading: $!";
        push @input, (<FILE>);
    close(FILE);
    unlink $tmp_file;
    
    my $stanza_terminator = '^(\s+|$)';
    my $comment = '^#';

    #
    # Add a blank line at the end, so that we don't get an error when 
    # matching for a $stanza_terminator against an undef value.
    # Otherwise, it's harmless. -BEF-
    push(@input, "");
    while(@input) {
        $_ = shift @input;

        # 
        # BundleFile: section
        #
        if( m/^BundleFile:\s+(.*)/ ) {
            $bundlefile = $1;
            chomp $bundlefile;

            $_ = shift @input;
        }

        # 
        # [global] section
        #
        elsif( m/^\[global\]/ ) {

            $_ = shift @input;
            until( m/$stanza_terminator/ ) {
                #
                # Allow "key = value" or "key=value" type definitions.
                s/\s*=\s*/ /o;

                foreach my $option_name ( "pkg_manager", 
                                          "pkg_manager_autoremove", 
                                          "upload_url", 
                                          "email_log_to", 
                                          "log_file_perms", 
                                          "remove_running_kernel", 
                                          "upgrade_ssm_before_sync", 
                                          "pkg_repo_update", 
                                          "pkg_repo_update_window", 
                                          "pkg_manager_update_window",  # deprecated 2017.04.05 -BEF-
                                          "base_url", 
                                          "git_url", 
                                          "svn_url", 

                                          # Deprecated versions using URI
                                          "base_uri", 
                                        ) {

                    if( m/^$option_name\s+(.*)(\s|#|$)/ ) { 

                        $::o{$option_name} = lc($1); 

                        $BUNDLEFILE{$option_name} = $bundlefile if(defined $bundlefile);
                        #   It's possible that a global value was passed as an
                        #   argument, outside of a bundlefile
                    }
                }

                $_ = shift @input;
            }

            #
            # Standardize on URL, but support deprecated URI
            #
            if($::o{base_uri} and ! $::o{base_url}) {
                $::o{base_url} = $::o{base_uri};
            }


            ######################################################################## 
            #
            #   BEGIN Let's set some defaults, eh?
            #
            # If base_url is using the file:// style URL, then we can assume that
            # upload_url should be the same, unless explicitly specified. -BEF-
            #
            if(! $::o{upload_url}) {
                $::o{upload_url} = $::o{base_url};
            }

            # default to 'auto'
            if(! $::o{pkg_repo_update}) {
                $::o{pkg_repo_update} = 'auto';
            }

            # pkg_manager_update_window deprecated 2017.04.05 -BEF-
            if(! $::o{pkg_repo_update_window} and $::o{pkg_manager_update_window}) {
                $::o{pkg_repo_update_window} = $::o{pkg_manager_update_window}; 
            }

            # default to '12' hours
            if(! $::o{pkg_repo_update_window}) {
                $::o{pkg_repo_update_window} = 12;
            }

            #
            # Make sure we have a package manager defined
            #
            if( ! defined $::o{pkg_manager} ) {
                $::o{pkg_manager} = 'none';
            }

            if( ! defined $::o{remove_running_kernel} ) { 
                # Default to "no"
                $::o{remove_running_kernel} = 'no';
            }

            #
            #   END Let's set some defaults, eh?
            #
            ######################################################################## 
 
            #
            # Make sure it's one we support
            #
            unless( $valid_pkg_managers{$::o{pkg_manager}} ) {
                please_specify_a_valid_pkg_manager();
            }
        } 

        # 
        # [bundles] section
        #
        elsif( m/^\[bundles\]/ ) {

            $_ = shift @input;
            until( m/$stanza_terminator/ ) {

                if( m/$comment/ ) {
                    # do nothing
                }

                #
                # Match only the first entry on the line.  This allows for
                # comments after an entry. -BEF-
                #
                elsif( m/^([\S]+)/ ) {
                    push( @input, _include_bundle($1) );
                }

                $_ = shift @input;
            }
        }

        # 
        # [packages] section
        #
        elsif( m/^\[packages\]/ ) {

            $_ = shift @input;
            until( m/$stanza_terminator/ ) {

                my ($pkg, $options);
                if( m/$comment/ ) {
                    # do nothing
                } else {
                    ($pkg, $options) = split;
                    if(! defined $::PKGS_FROM_STATE_DEFINITION{$pkg}) {
                        $::PKGS_FROM_STATE_DEFINITION{$pkg} = $options;
                    } else {
                        $::PKGS_FROM_STATE_DEFINITION{$pkg} = compare_package_options($pkg, $options);
                        ssm_print ">> Winning options:  $pkg $::PKGS_FROM_STATE_DEFINITION{$pkg}\n\n" if($::o{debug});
                    }

                    if($::o{debug}) { 
                        ssm_print "[packages]: $pkg";
                        ssm_print ", $options" if($options);
                        ssm_print "\n";
                    }

                    #
                    # For --analyze-config option. -BEF-
                    my $priority = 0;
                    if((defined $options) and ($options =~ m/\bpriority=([-+]?\d+)/i)) {
                        $priority = $1;
                    }
                    push @analyze, qq($priority $pkg $bundlefile);
                }

                $_ = shift @input;
            }
        }

        # 
        # [service] sections
        #
        elsif( m/^\[service\]/ ) {

            my $etype = 'service';

            my( $name, 
                $details,
                $depends,
                );

            $_ = shift @input;
            until( m/$stanza_terminator/ ) {
                
                #
                # Collect all the values
                chomp;

                #
                # Allow "key = value" or "key=value" type definitions.
                s/\s*=\s*/ /o;

                my ($key, $value) = split('\s+', $_, 2);

                if($key eq 'name') { 
                    $name = $value; 

                } elsif($key eq 'details') { 
                    # We don't remove spaces here, as they're part of the value
                    $details = $value;

                } elsif(($key eq 'depends') or ($key eq 'deps')) { 
                    # We don't remove spaces here, as they're part of the value
                    $depends = $value;

                }

                $_ = shift @input;
            }

            $name = normalized_file_name( $name ); 

            if( (defined $name) and (defined $CONF{$etype}{$name}{details}) ) {
                ssm_print_always "\n";
                ssm_print_always "ERROR: Multiple (conflicting) definitions for:\n";
                ssm_print_always "\n";
                ssm_print_always "  [service]\n";
                ssm_print_always "  name = $name\n";
                ssm_print_always "  ...\n";
                ssm_print_always "\n";
                ssm_print_always "  Exiting now without modifying the service. Please examine your\n";
                ssm_print_always "  configuration and eliminate all but one of the definitions\n";
                ssm_print_always "  for this service.\n";
                ssm_print_always "\n";

                $ERROR_LEVEL++;
                if($::o{debug}) { ssm_print_always "ERROR_LEVEL: $ERROR_LEVEL\n"; }

                # We go ahead and exit here to be super conservative.
                ssm_print_always "\n";
                exit $ERROR_LEVEL;
            }

            #
            # Assign the values to hashes
            #
            if( defined $name ) {
                $CONF{$etype}{$name}{details} = $details if(defined $details);
                $CONF{$etype}{$name}{depends} = $depends if(defined $depends);
            }

            my ($retval, @unsatisfied) = check_depends($name, $etype);
            if($retval eq 0) {

                ssm_print "Not OK:  Service $name -> Unmet Dependencies\n";
                foreach (@unsatisfied) {
                    ssm_print "           - $_\n";
                }

                assign_state_to_thingy($name, 'b0rken');

                $ERROR_LEVEL++; if($::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }

            } else {

                if(defined $CONF{$etype}{$name}{details}) {
                    turn_service_into_file_entry($name);
                } else {
                    report_improper_service_definition($name);
                }
            }
        }

        # 
        # [file] sections
        #
        elsif( m/^\[file\]/ ) {

            my $etype = 'file';

            my( $name, 
                $type,
                $mode,
                $owner,
                $group,
                $md5sum,
                $major,
                $minor,
                $target,
                $prescript,
                $postscript,
                $depends,
                $priority,
                $generator,
                );

            $_ = shift @input;
            until( m/$stanza_terminator/ ) {
                
                #
                # Collect all the values
                chomp;

                #
                # Allow "key = value" or "key=value" type definitions.
                s/\s*=\s*/ /o;

                my ($key, $value) = split('\s+', $_, 2);

                # Remove any trailing space at the end of value.
                # Trailing space messes up filenames, links, etc.
                if( defined($value) ) {
                    $value =~ s/\s+$//o;
                } else {
                    $ERROR_LEVEL++;
                    ssm_print "Config Error.  Next 10 lines in the configuration:\n";
                    #
                    # Print 10 lines below
                    # in the array @input to give reference to the point 
                    # of incorrect config chunk. -BEF-
                    #
                    my $count = 0;
                    until( $count == 10 ) {
                        $_ = shift @input;
                        chomp;
                        ssm_print "  $_\n";
                        $count++;
                    }
                    ssm_print "\n";
                }

                if($key eq 'name') { 
                    $name = $value; 

                    #if($::o{debug}) { ssm_print "name before: $name\n"; }
                    $name = normalized_file_name( $name ); 
                    #if($::o{debug}) { ssm_print "name after:  $name\n"; }

                } elsif($key eq 'type')       { 
                    $value =~ s/\s.*//;
                    $type = $value;

                } elsif($key eq 'mode') { 
                    $value =~ s/\s.*//;
                    $mode = $value;

                } elsif($key eq 'owner') {
                    $value =~ s/\s.*//;
                    $owner = $value;

                } elsif($key eq 'group') {
                    $value =~ s/\s.*//;
                    $group = $value;

                } elsif($key eq 'md5sum') {
                    $value =~ s/\s.*//;
                    $md5sum = $value;

                } elsif($key eq 'major') {
                    $value =~ s/\s.*//;
                    $major = $value;

                } elsif($key eq 'minor') {
                    $value =~ s/\s.*//;
                    $minor = $value;

                } elsif($key eq 'target') {
                    $target = $value;

                } elsif($key eq 'prescript') {
                    $prescript = $value;

                } elsif($key eq 'postscript') { 
                    $postscript = $value;

                } elsif(($key eq 'depends') or ($key eq 'deps')) { 
                    $depends = $value;

                } elsif($key eq 'priority') { 
                    if( $value =~ /^[-\+]?\d+$/ ) {
                        $priority = $value;
                    } else {
                        # Easter egg or bug -- you decide...  You can
                        # use a value like "two" which is translated to
                        # "3" (character count). ;-)  heh, heh, heh... -BEF-
                        $priority = length $value;
                    }

                } elsif($key eq 'generator') { 

                    # Match HERE documents, but ignore unquoted leading or trailing spaces. -BEF-
                    if( $value =~ m/^\s*<<\s*(.*)\s*$/ ) {

                        #
                        # Ok, cool!  We got ourselves a multi-line generator on our hands...
                        #
                        my $here_target = $1;

                        # read in the rest of the document.
                        $generator = "";
                        $_ = shift @input;
                        until( m/^$here_target$/ ) {
                            $generator .= $_;
                            $_ = shift @input;
                        }

                    } else {
                       $generator = $value;
                    }
                }

                $_ = shift @input;
            }

            # If no priority is set for this file, or the priority field is blank, use the default of zero.
            if(! defined $priority) {
                $priority = 0;
            }

            push @analyze, qq($priority $name $bundlefile);

            # If existing priority is higher than this file's priority
            if( (defined $CONF{$etype}{$name}{priority}) and ($CONF{$etype}{$name}{priority} > $priority) ) {
                # do nothing;

            # If existing priority is equal to this file's priority
            } elsif( (defined $CONF{$etype}{$name}{priority}) and ($CONF{$etype}{$name}{priority} == $priority) ) {
                # error out;
                ssm_print_always "\n";
                ssm_print_always "ERROR: Multiple (conflicting) definitions for:\n";
                ssm_print_always "\n";
                ssm_print_always "  [file]\n";
                ssm_print_always "  name     = $name\n";
                ssm_print_always "  priority = $priority\n";
                ssm_print_always "  ...\n";
                ssm_print_always "\n";
                ssm_print_always "  This instance of this file was found in $bundlefile\n";
                ssm_print_always "\n";
                ssm_print_always "  Exiting now without modifying the file. Please examine your\n";
                ssm_print_always "  configuration and eliminate all but one of the definitions\n";
                ssm_print_always "  for this file, or change the priority of one of the definitions.\n";
                ssm_print_always "\n";

                $ERROR_LEVEL++;
                if($::o{debug}) { ssm_print_always "ERROR_LEVEL: $ERROR_LEVEL\n"; }

                # We go ahead and exit here to be super conservative.
                ssm_print_always "\n";
                exit $ERROR_LEVEL;

            # If either:
            #   a) this file name has no existing priority
            #   b) this file's priority is higher than the existing priority
            } else {
                #
                # Assign the values to hashes
                #
                if( defined $name ) {
                    $CONF{$etype}{$name}{type}       = $type       if(defined $type);
                    $CONF{$etype}{$name}{mode}       = $mode       if(defined $mode);
                    $CONF{$etype}{$name}{owner}      = $owner      if(defined $owner);
                    $CONF{$etype}{$name}{group}      = $group      if(defined $group);
                    $CONF{$etype}{$name}{md5sum}     = $md5sum     if(defined $md5sum);
                    $CONF{$etype}{$name}{major}      = $major      if(defined $major);
                    $CONF{$etype}{$name}{minor}      = $minor      if(defined $minor);
                    $CONF{$etype}{$name}{target}     = $target     if(defined $target);
                    $CONF{$etype}{$name}{prescript}  = $prescript  if(defined $prescript);
                    $CONF{$etype}{$name}{postscript} = $postscript if(defined $postscript);
                    $CONF{$etype}{$name}{depends}    = $depends    if(defined $depends);
                    $CONF{$etype}{$name}{priority}   = $priority   if(defined $priority);
                    $CONF{$etype}{$name}{generator}  = $generator  if(defined $generator);
                    $BUNDLEFILE{$name} = $bundlefile if(defined $bundlefile);

                    # And we start with a status of unknown, later to be
                    # determined as broken or fixed as appropriate.
                    assign_state_to_thingy($name, 'unknown') unless(defined $::outstanding{$name}); 
                }
            }

            unless(defined $CONF{$etype}{$name}{type}) {
                return report_improper_file_definition($name);
            }
        }

        # 
        # [variable] sections
        #
        elsif( m/^\[variable\]/ ) {

            my $etype = 'variable'; # Entry type

            my( $name, 
                $type,
                $mode,
                $owner,
                $group,
                $md5sum,
                $major,
                $minor,
                $target,
                $prescript,
                $postscript,
                $depends,
                $priority,
                $generator,
                );

            $_ = shift @input;
            until( m/$stanza_terminator/ ) {
                
                #
                # Collect all the values
                chomp;

                #
                # Allow "key = value" or "key=value" type definitions.
                s/\s*=\s*/ /o;

                my ($key, $value) = split('\s+', $_, 2);

                # Remove any trailing space at the end of value.
                # Trailing space messes up filenames, links, etc.
                if( defined($value) ) {
                    $value =~ s/\s+$//o;
                } else {
                    $ERROR_LEVEL++;
                    ssm_print "Config Error.  Next 10 lines in the configuration:\n";
                    #
                    # Print 10 lines below
                    # in the array @input to give reference to the point 
                    # of incorrect config chunk. -BEF-
                    #
                    my $count = 0;
                    until( $count == 10 ) {
                        $_ = shift @input;
                        chomp;
                        ssm_print "  $_\n";
                        $count++;
                    }
                    ssm_print "\n";
                }

                if($key eq 'name') { 
                    $name = $value; 

                } elsif(($key eq 'depends') or ($key eq 'deps')) { 
                    $depends = $value;

                } elsif($key eq 'priority') { 

                    if( $value =~ /^[-\+]?\d+$/ ) {
                        $priority = $value;

                    } else {
                        # Easter egg or bug -- you decide...  You can
                        # use a value like "two" which is translated to
                        # "3" (character count). ;-)  heh, heh, heh... -BEF-
                        $priority = length $value;
                    }

                } elsif($key eq 'generator') { 

                    # Match HERE documents, but ignore unquoted leading or trailing spaces. -BEF-
                    if( $value =~ m/^\s*<<\s*(.*)\s*$/ ) {

                        #
                        # Ok, cool!  We got ourselves a multi-line generator on our hands...
                        #
                        my $here_target = $1;

                        # read in the rest of the document.
                        $generator = "";
                        $_ = shift @input;
                        until( m/^$here_target$/ ) {
                            $generator .= $_;
                            $_ = shift @input;
                        }

                    } else {
                       $generator = $value;
                    }
                }

                $_ = shift @input;
            }

            # If no priority is set, or the priority field is blank, use the default of zero.
            if(! defined $priority) {
                $priority = 0;
            }

            push @analyze, qq($priority \$$name $bundlefile);

            # If existing priority is higher than this priority
            if( (defined $CONF{$etype}{$name}{priority}) and ($CONF{$etype}{$name}{priority} > $priority) ) {
                # If existing priority is higher, do nothing here.

            } elsif( (defined $CONF{$etype}{$name}{priority}) and ($CONF{$etype}{$name}{priority} == $priority) ) {
                #
                # If existing priority is equal to this file's priority
                #
                report_conflicting_definitions($etype, $name, $priority, $bundlefile);

            } else {
                #
                # Assign the values to hashes
                #
                if( defined $name ) {
                    $CONF{$etype}{$name}{type}       = $type       if(defined $type);
                    $CONF{$etype}{$name}{mode}       = $mode       if(defined $mode);
                    $CONF{$etype}{$name}{owner}      = $owner      if(defined $owner);
                    $CONF{$etype}{$name}{group}      = $group      if(defined $group);
                    $CONF{$etype}{$name}{md5sum}     = $md5sum     if(defined $md5sum);
                    $CONF{$etype}{$name}{major}      = $major      if(defined $major);
                    $CONF{$etype}{$name}{minor}      = $minor      if(defined $minor);
                    $CONF{$etype}{$name}{target}     = $target     if(defined $target);
                    $CONF{$etype}{$name}{prescript}  = $prescript  if(defined $prescript);
                    $CONF{$etype}{$name}{postscript} = $postscript if(defined $postscript);
                    $CONF{$etype}{$name}{depends}    = $depends    if(defined $depends);
                    $CONF{$etype}{$name}{priority}   = $priority   if(defined $priority);
                    $CONF{$etype}{$name}{generator}  = $generator  if(defined $generator);

                    $BUNDLEFILE{$name} = $bundlefile if(defined $bundlefile);

                    # And we start with a status of unknown, later to be
                    # determined as broken or fixed as appropriate.
                    assign_state_to_thingy($name, 'unknown') unless(defined $::outstanding{$name}); 
                }
                else {
                    return report_improper_file_definition($name);
                }
            }

            # Take the generator and write it into an executable file and capture the output value
            my $generator_script = choose_tmp_file();
            open(FILE,">$generator_script") or die("Couldn't open $generator_script for writing.");
            print FILE $CONF{$etype}{$name}{generator};
            close(FILE);
            chmod oct(700), $generator_script;
            
            # Execute generator and capture results
            if( $::o{debug} ) { print ">>>  The Expressionist(tm): $generator_script\n"; }
            
            my $value;
            open(INPUT,"$generator_script|") or die("Couldn't run $generator_script $!");
            while(<INPUT>) {
                $value .= $_;
            }
            close(INPUT);
            unlink $generator_script;
            
            chomp $value;
            $CONF{$etype}{$name}{value} = $value;
            
            if($::o{debug}) { 
                ssm_print_always "[variables]: $name => $CONF{$etype}{$name}{value}\n";
            }
        }
    }  

    #
    # Do variable substitutions
    #
    foreach my $variable (keys %{$CONF{variable}}) {
        #
        #   Process [variable] substitutions in file _names_
        #
        my $etype = 'file';
        foreach my $name (keys %{$CONF{$etype}}) {
            my $original_name = $name;
            if( $name =~ s/\$\{$variable\}/$CONF{variable}{$variable}{value}/g ) {

                # Effectively renaming the hash entry from $original_name to $name
                $CONF{$etype}{$name} = delete $CONF{$etype}{$original_name};

                # Preserve the original element name -- might need it for
                # certain operations, such as interactively commenting it out
                $CONF{$etype}{$name}{original_name} = $original_name;

                # Add a lookup entry to find the new_name based on the original_name;
                $CONF{new_name}{$original_name} = $name;
            }
        }

        foreach my $name (keys %{$CONF{$etype}}) {
            if($CONF{$etype}{$name}{generator}) {
                $CONF{$etype}{$name}{generator}     =~ s/\$\{$variable\}/$CONF{variable}{$variable}{value}/g;
            }
            if($CONF{$etype}{$name}{depends}) {
                $CONF{$etype}{$name}{depends}       =~ s/\$\{$variable\}/$CONF{variable}{$variable}{value}/g;
            }
            if($CONF{$etype}{$name}{postscript}) {
                $CONF{$etype}{$name}{postscript}    =~ s/\$\{$variable\}/$CONF{variable}{$variable}{value}/g;
            }
            if($CONF{$etype}{$name}{prescript}) {
                $CONF{$etype}{$name}{prescript}     =~ s/\$\{$variable\}/$CONF{variable}{$variable}{value}/g;
            }
        }
    }


    if( $::o{analyze_config} ) {

        @analyze = sort multisort @analyze;

        # Prepend Titles after sorting
        unshift @analyze, "-------- ------- ------";
        unshift @analyze, "Priority Element Bundle";

        # Find longest first element for padding purposes
        my $max_a_length = 0;
        my $max_b_length = 0;
        foreach(@analyze) {
            my ($a, $b, $c) = split;

            my $a_length = length($a);
            if( $a_length > $max_a_length) { $max_a_length = $a_length; }

            my $b_length = length($b);
            if( $b_length > $max_b_length) { $max_b_length = $b_length; }
        }

        # Print padded output.
        print "\n";
        foreach (@analyze) {
            my ($a, $b, $c) = split;

            print "$a"; 
            print_pad( $max_a_length - length($a) + 2 );

            print "$b";
            print_pad( $max_b_length - length($b) + 2 );

            print "$c\n";
        }
        print "\n";
        exit 0;
    }

    turn_usernames_into_uids();
    turn_groupnames_into_gids();

    return $ERROR_LEVEL;
}


sub please_specify_a_valid_pkg_manager {

    if( $::o{debug} ) { ssm_print "please_specify_a_valid_pkg_manager()\n"; }

    ssm_print qq(WARNING: A valid pkg_manager is not defined in the configuration.\n);
    ssm_print qq(WARNING: Assuming "pkg_manager = none".\n);
    ssm_print qq(WARNING: See /usr/share/doc/simple-state-manager/examples/safe_to_run_example_config_file.conf\n);
    $::o{pkg_manager} = 'none';

    return 1;
}


# Return a pad of spaces of N length
# get_pad(N);
sub get_pad {

    my $length = shift;

    my $pad = "";
    my $i = 0;
    until($i == $length) {
        $pad .= " ";
        $i++;
    }

    return $pad;
}

# Print a pad of spaces of N length
# print_pad(N);
sub print_pad {

    my $length = shift;

    my $i = 0;
    until($i == $length) {
        print " ";
        $i++;
    }

    return 1;
}

sub turn_usernames_into_uids {

    my $etype = 'file';

    foreach my $name (keys %{$CONF{$etype}}) {
        if(defined $CONF{$etype}{$name}{owner}) {
            $CONF{$etype}{$name}{owner} = user_to_uid($CONF{$etype}{$name}{owner});
        }
    }
    return 1;
}


sub turn_groupnames_into_gids {

    my $etype = 'file';

    foreach my $name (keys %{$CONF{$etype}}) {
        if(defined $CONF{$etype}{$name}{group}) {
            $CONF{$etype}{$name}{group} = group_to_gid($CONF{$etype}{$name}{group});
        }
    }
    return 1;
}


sub user_to_uid {

    my $user = shift;

    if($user =~ m/^\d+$/) {
        # it's already all-numeric; as in, a uid was specified in the definition
        return $user;
    } else {
        return (getpwnam $user)[2];
    }
}


sub group_to_gid {

    my $group = shift;

    if($group =~ m/^\d+$/) {
        # it's already all-numeric; as in, a gid was specified in the definition
        return $group;
    } else {
        return (getgrnam $group)[2];
    }
}


sub load_pkg_manager_functions {

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    if( ! $::o{pkg_manager} ) {
        $::o{pkg_manager} = 'none';
    }
    
    if( $::o{pkg_manager} eq "dpkg" 
     or $::o{pkg_manager} eq "aptitude"
     or $::o{pkg_manager} eq "apt-get") {
        ssm_print "$debug_prefix require SimpleStateManager::Dpkg;\n" if($::o{debug});
        require SimpleStateManager::Dpkg;
        SimpleStateManager::Dpkg->import();
    }
    elsif( $::o{pkg_manager} eq "yum" ) {
        ssm_print "$debug_prefix require SimpleStateManager::Yum;\n" if($::o{debug});
        require SimpleStateManager::Yum;
        SimpleStateManager::Yum->import();
    }
    elsif( $::o{pkg_manager} eq "zypper" ) {
        ssm_print "$debug_prefix require SimpleStateManager::Zypper;\n" if($::o{debug});
        require SimpleStateManager::Zypper;
        SimpleStateManager::Zypper->import();
    }
    elsif( $::o{pkg_manager} eq "none" ) {
        ssm_print "$debug_prefix require SimpleStateManager::None;\n" if($::o{debug});
        require SimpleStateManager::None;
        SimpleStateManager::None->import();
    }

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }

    return 1;
}


sub sync_state {

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    $CHANGES_MADE = 0;

    load_pkg_manager_functions();

    unless($::o{only_files}) {
        if( defined $::o{upgrade_ssm_before_sync} and $::o{upgrade_ssm_before_sync} eq "yes" ) {
            upgrade_ssm() unless($::o{no});
        }
    }

    #
    # Files
    my %only_this_file_hash;
    if( $::o{only_this_file} ) {

        my %specified_files_that_arent_defined;

        foreach my $name ( @{$::o{only_this_file}} ) {

            my $fq_file = fully_qualified_file_name($name);
            if(defined $fq_file) {
                $name = $fq_file;
            }

            if($CONF{file}{$name}) {    # make sure it exists in the definition
                $only_this_file_hash{$name} = 1;
            } else {
                $specified_files_that_arent_defined{$name} = 1;
            }
        }

        if(%specified_files_that_arent_defined) {

            ssm_print_always "\n";
            ssm_print_always "ERROR:  The following files were specified with --only-this-file, but do\n";
            ssm_print_always "        not exist in the definition:\n";
            ssm_print_always "\n";
            foreach my $name (sort keys %specified_files_that_arent_defined) {
                ssm_print_always "          $name\n";
            }
            ssm_print_always "\n";

            exit 1;
        }
    }

    my $etype = 'file';
    foreach my $name (sort keys %{$CONF{$etype}}) {

        next if( $::o{only_this_file} and !defined($only_this_file_hash{$name}) );

        last if($::o{only_packages});

        if( ($CONF{$etype}{$name}{type} eq 'ignore') or ($CONF{$etype}{$name}{type} eq 'ignored') ) {
            ignore_file_interactive($name);
        }
        elsif( $CONF{$etype}{$name}{type} eq 'softlink' ) {
            softlink_interactive($name);
        }
        elsif( $CONF{$etype}{$name}{type} eq 'hardlink' ) {
            hardlink_interactive($name);
        }
        elsif(     $CONF{$etype}{$name}{type} eq 'block' 
                or $CONF{$etype}{$name}{type} eq 'character'
                or $CONF{$etype}{$name}{type} eq 'fifo'      ) {
            special_file_interactive($name);
        }
        elsif( $CONF{$etype}{$name}{type} eq 'chown+chmod' ) {
            chown_and_chmod_interactive($name);
        }
        elsif( $CONF{$etype}{$name}{type} eq 'regular' ) {
            regular_file_interactive($name);
        }
        elsif( $CONF{$etype}{$name}{type} eq 'directory' ) {
            directory_interactive($name);
        }
        elsif( $CONF{$etype}{$name}{type} eq 'unwanted' ) {
            unwanted_file_interactive($name);
        }
        elsif( $CONF{$etype}{$name}{type} eq 'directory+contents-unwanted' ) {
            contents_unwanted_interactive($name);
        }
        elsif( $CONF{$etype}{$name}{type} eq 'generated' ) {
            generated_file_interactive($name);
        }
        else {
            return report_improper_file_definition($name);
        }
    }

    ####################################################################
    #
    # BEGIN Package related activities
    #
    # Only do pkg stuff after initial examination pass
    if( $::PASS_NUMBER > 1 ) {

        # Get integer value that represents the number of packages defined.
        if( (scalar (keys %::PKGS_FROM_STATE_DEFINITION)) == 0) {

            #
            # No need to be noisy.  If no packages have been defined, that's
            # OK, even if a package manager has been specified.  So I'm
            # commenting this out. -BEF-
            #
            #ssm_print "INFO:    Packages -> No [packages] defined in the configuration.\n";
            return ($ERROR_LEVEL, $CHANGES_MADE);
        }
        elsif( $::o{pkg_manager} eq 'none' ) {
            ssm_print "WARNING: Packages -> [packages] defined, but 'pkg_manager = none'.\n";
            return ($ERROR_LEVEL, $CHANGES_MADE);
        } 
        elsif( $::o{only_this_file} ) {
            # Don't print anything to keep output minimalist in this case.
            return ($ERROR_LEVEL, $CHANGES_MADE);
        }
        elsif( $::o{only_files} ) {
            ssm_print "INFO:    Option --only-files specified.  Skipping any [packages] sections.\n"; 
            return ($ERROR_LEVEL, $CHANGES_MADE);
        } 

        ssm_print "INFO:    Package manager -> $::o{pkg_manager}\n";

        update_package_repository_info_interactive();

        autoremove_packages_interactive() if($::o{pkg_manager_autoremove} and $::o{pkg_manager_autoremove} eq 'yes');
        upgrade_packages_interactive();
        install_packages_interactive();
        remove_packages_interactive();
    }
    #
    # END Package related activities
    #
    ####################################################################
    
    # Remove checked out SSM DB, if it exists.
    my $ou_path = "/tmp/ssm_db.repo.$$";
    remove_file("$ou_path");

#    ssm_print "\n";
#    ssm_print "Changes made:              $CHANGES_MADE\n";
#    ssm_print "Outstanding changes:\n";
#    ssm_print "-------------------------------\n";
#    ssm_print "- Packages to install:     $OUTSTANDING_PACKAGES_TO_INSTALL\n";
#    ssm_print "- Packages to upgrade:     $OUTSTANDING_PACKAGES_TO_UPGRADE\n";
#    ssm_print "- Packages to remove:      $OUTSTANDING_PACKAGES_TO_REMOVE\n";
#    ssm_print "Ask Marc for his opinion here...\n";
#    ssm_print "  how about simply saying:\n";
#    ssm_print "    Outstanding file changes:  Yes (or no)\n";
#    ssm_print "    Outstanding package changes:  Yes (or no)\n";
#    ssm_print "  or simply saying _nothing_...  We say it for each item as we go anyway.\n";
#    ssm_print "- File related:            $ERROR_LEVEL\n";
#    ssm_print "\n";

    $ERROR_LEVEL += $OUTSTANDING_PACKAGES_TO_INSTALL;
    $ERROR_LEVEL += $OUTSTANDING_PACKAGES_TO_REMOVE;
    $ERROR_LEVEL += $OUTSTANDING_PACKAGES_TO_UPGRADE;

    if( $::o{debug} ) { 
        ssm_print "lib/SimpleStateManager.pm:sync_state() returning:\n";
        ssm_print "  \$ERROR_LEVEL:  $ERROR_LEVEL\n";
        ssm_print "  \$CHANGES_MADE: $CHANGES_MADE\n";
        ssm_print "\n";
    }

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }

    sleep 1;
    return ($ERROR_LEVEL, $CHANGES_MADE);
}


sub check_depends_interactive {

    my $name = shift;
    my $etype = shift;

    my ($retval, @unsatisfied) = check_depends($name, $etype);

    return 1 unless($retval eq 2);

    declare_OK_or_Not_OK($name, 0);
    
    unless( $::o{summary} ) {
        ssm_print "\n";
        ssm_print "           Unmet Dependencies:\n";
        foreach (@unsatisfied) {
            ssm_print "           - $_\n";
        }
    }
    
    assign_state_to_thingy($name, 'unmet_deps');
    
    $ERROR_LEVEL++;
    if($::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }
    
    my $action = 'null';
    take_file_action( $name, $action, 'ni#' ) unless($::o{yes});
        # There is no "yes" action to take, so just skip if --yes.
    
    return undef;
}


sub close_log_file {

    if( $::o{debug} ) { ssm_print "close_log_file()\n"; }

    close($LOGFILE) or die("Couldn't close $LOGFILE");

    my $log_file = "/var/log/" . basename($0);
    if( $::o{log_file_perms} ) {
        chmod oct($::o{log_file_perms}), $log_file;
    }

    return 1;
}

sub email_log_file {

    if( $::o{debug} ) { ssm_print "email_log_file()\n"; }

    close_log_file();

    unless($::o{email_log_to}) {
        return 1;
    }
    
    my $msg;
    my $fh;
    my $log_file = "/var/log/" . basename($0);
    my $name = $log_file;
    my $subject = "SSM: " . get_hostname();

    $msg = Mail::Send->new;
    $msg = Mail::Send->new(Subject => $subject, To => $::o{email_log_to} );
    $fh = $msg->open;
    open(FILE,"<$name") or die("Couldn't open $name for reading!");
        while(<FILE>) {
            print $fh $_;
        }
    close(FILE);
    $fh->close;         # complete the message and send it

    return 1;
}


#
# returns an array:  "pkg=version" or just "pkg"
#   - packages not currently installed
#   - packages from configuration include version numbers if appropriate
#
sub get_pkgs_to_be_installed {

    if( $::o{debug} ) { ssm_print "get_pkgs_to_be_installed()\n"; }

    my %pkgs_currently_installed = get_pkgs_currently_installed();

    #
    # If it's in the state definition, but not installed, install it.
    #
    my %pkgs_to_be_installed;
    foreach my $pkg (keys %::PKGS_FROM_STATE_DEFINITION) {

        if(( ! $pkgs_currently_installed{$pkg} ) and ( $::PKGS_FROM_STATE_DEFINITION{$pkg} !~ m/\b(unwanted|remove|delete|erase)\b/i )) {
            $pkgs_to_be_installed{$pkg} = $::PKGS_FROM_STATE_DEFINITION{$pkg};
        }
    }

    return (keys %pkgs_to_be_installed);
}


sub version {

    if( $::o{debug} ) { print "version()\n"; }

    # Can't use ssm_print in here -- not initialiased yet. -BEF-
    my $PROGNAME = basename($0);
    my $VERSION = '___VERSION___';
    print <<EOF;
$PROGNAME (part of Simple State Manager) v$VERSION
    
EOF
}


#
# Usage: my $arch = get_arch();
#
sub _get_arch {

    if( $::o{debug} ) { ssm_print "_get_arch()\n"; }

    use POSIX;

	my $arch = (uname())[4];
	$arch =~ s/i.86/i386/;

	return $arch;
}


#
# Usage:  
#       run_cmd("my shell command");
#       run_cmd("my shell command", 1 );
#       run_cmd("my shell command", 1, 1 );
#       run_cmd("my shell command", undef, 1);
#       run_cmd("my shell command", , 1);
#       run_cmd("my shell command", , );
#
#       Do not use a "zero" (0) to indicate off, use a blank or "undef" (undef).
#
#       First argument:  the "command" to run.
#           Required.
#
#       Second argument:  '1' to print a newline after the command.
#           Defaults to "undef".
#
#       Third argument:  '1' to do this command _even_ if --no is specified.
#           Defaults to "undef".
#
sub run_cmd {

    my $cmd               = shift;
    my $add_newline       = shift;
    my $even_if_no        = shift;
    
    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    if( ! $::o{no} or defined($even_if_no) ) { 
        ssm_print "$debug_prefix $cmd\n" if( $::o{debug} );
        open(INPUT,"$cmd|") or die("FAILED: $cmd\n $!");
        while(<INPUT>) {
            ssm_print $_;
        }
        close(INPUT);
    }
    
    ssm_print "\n" if( defined $add_newline );

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }
    
    return 1;
}


#
# Usage:  my $answer = do_you_want_me_to($prompts);
#          where $prompts is one or more of 'ynda#i'
#
sub do_you_want_me_to {

    my $prompts = shift;
    my $msg = shift;

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    if(! defined $prompts) {
        $prompts = 'yn';
    }

    if(! defined $msg) {
        $msg = "         Shall I do this? [N";
        foreach my $prompt ( split(//,$prompts) ) {

            next if( $prompt =~ m/N/i );             # If we were passed an N or n, skip it -- we auto-include one
            $prompt = lc($prompt);      # Make each option lowercase

            if($::o{debug}) { ssm_print "do_you_want_me_to(): $prompt\n"; }
            $msg .= "/$prompt";
        }
        $msg .= "/?]: ";
    }

    my $i_had_to_explain_something = undef;
    my $explanation = "\n";

    if($prompts =~ m/n/ and ! defined $::o{answer_implications_explained}{n}) {
        $explanation .= qq/           N -> No, don't do anything.  [The default]\n/;
        $::o{answer_implications_explained}{n} = 'yes';
        $i_had_to_explain_something = 1;
        }
    if($prompts =~ m/y/ and ! defined $::o{answer_implications_explained}{y}) {
        $explanation .= qq/           y -> Yes, execute all of the "Need to" actions above.\n/;
        $::o{answer_implications_explained}{y} = 'yes';
        $i_had_to_explain_something = 1;
        }
    if($prompts =~ m/d/ and ! defined $::o{answer_implications_explained}{d}) {
        $explanation .= qq/           d -> Show me the differences between the repo version and the\n/;
        $explanation .= qq/                local version, then ask me again.\n/;
        $::o{answer_implications_explained}{d} = 'yes';
        $i_had_to_explain_something = 1;
        }
    if($prompts =~ m/a/ and ! defined $::o{answer_implications_explained}{a}) {
        $explanation .= qq/           a -> Add the local version of this file to your repo and\n/;
        $explanation .= qq/                update the configuration to use it.\n/;
        $::o{answer_implications_explained}{a} = 'yes';
        $i_had_to_explain_something = 1;
        }
    if($prompts =~ m/#/ and ! defined $::o{answer_implications_explained}{'#'}) {
        $explanation .= qq/           # -> Comment out this entry in the configuration, but\n/;
        $explanation .= qq/                preserve any files it references in the repo.\n/;
        $::o{answer_implications_explained}{'#'} = 'yes';
        $i_had_to_explain_something = 1;
        }
    if($prompts =~ m/i/ and ! defined $::o{answer_implications_explained}{'i'}) {
        $explanation .= qq/           i -> Set this file as type "ignored" in the configuration.\n/;
        $::o{answer_implications_explained}{'i'} = 'yes';
        $i_had_to_explain_something = 1;
        }


    if(! defined $::o{answer_implications_explained}{help}) {
        $explanation .= qq/           ? -> Show help info for each of these options.\n/;
        $::o{answer_implications_explained}{help} = 'yes';
        $i_had_to_explain_something = 1;
        }

    $explanation .= qq/\n/;

    if( $i_had_to_explain_something ) {
        $msg = $explanation . $msg;
    } else {
        $msg = "\n" . $msg;
    }

    ssm_print $msg if(defined $msg);

    $_ = <STDIN>;
    until($_) {
        # Sometimes we manage to get here with no value in $_, so catch that
        # case and avoid a harmless error message for the user. -BEF-
        sleep 1;
        $_ = <STDIN>;
    }

    $_ =~ s/['"]//g;

    # Make sure the response matches one of the valid prompt options presented...
    # Either any one of the given prompts, the ?, or if the user just hit <Enter>.
    unless( $_ =~ m/(^[${prompts}\?]$|^$)/i ) {
        return 'undef';
    }

    if( $::o{yes} ) { 
        return 'y';

    } elsif( $main::o{no} ) { 
        return 'n';

    } elsif( m/^n$/i or m/^$/ ) {
        # either a no or an empty response (user just hit <Enter>)
        return 'n';

    } elsif( m/^y$/i ) {
        return 'y';

    } elsif( m/^d$/i ) {
        return 'd';

    } elsif( m/^a$/i ) {
        return 'a';

    } elsif( m/^#$/i ) {
        return '#';

    } elsif( m/^i$/i ) {
        return 'i';

    } elsif( m/^\?$/i ) {
        $::o{answer_implications_explained} = undef;
        return '?';

    }

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }
}


sub ignore_file_interactive {
     
    #
    # Simply ignore the entry.  Allows you to have a higher priority for
    # ignoring a file in one bundle, vs. another bundle that might call for the
    # same file's removal....
    #

    my $name = shift;
    my $etype = 'file';

    # validate input
    unless( 
            defined($name)        and ($name        =~ m#^/#)
        and defined($CONF{$etype}{$name}{type}) and ($CONF{$etype}{$name}{type} =~ m#\S#)
    ) {
        return report_improper_file_definition($name);
    }

    assign_state_to_thingy($name, 'fixed');
    declare_OK_or_Not_OK($name, 1);

    return 1;
}


sub softlink_interactive {
    # 
    # Accept either relative or absolute target, and implement as user
    # specifies.
    #

    my $name = shift;
    my $etype = 'file';

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    #
    # validate input
    unless( 
            defined($name)          and ($name          =~ m#^/#)
        and defined($CONF{$etype}{$name}{target})
        and defined($CONF{$etype}{$name}{type})   and ($CONF{$etype}{$name}{type}   =~ m#\S#)
    ) {
        return report_improper_file_definition($name);
    }

    #
    # Singularize double slashes in target names for beautification purposes
    $CONF{$etype}{$name}{target} =~ s#/+#/#g;

    #
    # In case it's a relative path name, move to the directory where the link
    # will live before testing for target existence. -BEF-
    #
    my    $cwd     = getcwd();
    my    $dirname = dirname( $name );
    chdir $dirname;
    if( ! -e $CONF{$etype}{$name}{target} ) {
        ssm_print "WARNING: Soft link $name -> $CONF{$etype}{$name}{target} (target doesn't exist).\n";
        $ERROR_LEVEL++;  if($::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }
    }
    chdir $cwd;

    my $current_target = readlink($name);

    #
    # Possibilities are:
    #   - $name exists and $current_target is right
    #       - leave it alone
    #
    #   - $name doesn't exist
    #       - create link
    #
    #   - $name exists, $current_target is wrong
    #       - rm $name 
    #       - create link
    #
    #   - $name exists, $current_target is undef (Ie: $name is not a softlink)
    #       - rm $name 
    #       - create link
    #
    unless( (defined $current_target) and ($current_target eq $CONF{$etype}{$name}{target}) ) {

        assign_state_to_thingy($name, 'b0rken');

        ssm_print "Not OK:  Soft link $name -> $CONF{$etype}{$name}{target}\n";

        unless( $::o{summary} ) {

            my $action = 'install_softlink';

            declare_file_actions($name, "create soft link $name");

            #
            # Decide what to do about it -- if anything
            #
            take_file_action( $name, $action, 'yni#' );
        }

    } else {

        assign_state_to_thingy($name, 'fixed');
        ssm_print "OK:      Soft link $name -> $CONF{$etype}{$name}{target}\n";
    }

    return 1;
}


sub install_hardlink {

    #
    #   Contemplation:  Should we accept and use owner, group, and mode info
    #   for hardlinks?
    #
    #   If perms and ownership are changed on a hardlink, they are changed for
    #   the file itself, and this is reflected by all names (links) for the
    #   file.
    #

    my $name     = shift;
    my $etype = 'file';

    if($::o{debug}) { ssm_print "install_hardlink($name)\n"; }

    ssm_print "         FIXING:  Hard link $name -> $CONF{$etype}{$name}{target}\n";

    my $calling_function = (caller(1))[3];
    execute_prescript($name) if( $calling_function eq 'SimpleStateManager::take_file_action' );

    # If path doesn't exist, create it here
    my $dir  = dirname($name);
    if(-e $dir and ! -d $dir) { remove_file($dir); }
    eval { make_path($dir) };
    if($@) { ssm_print "Couldn’t create $dir: $@"; }

    remove_file($name);
    link($CONF{$etype}{$name}{target}, $name) or die "Couldn't link($CONF{$etype}{$name}{target}, $name) $!";
    execute_postscript($name) if( $calling_function eq 'SimpleStateManager::take_file_action' );
    
    return 1;

}


sub install_softlink {

    my $name     = shift;
    my $etype = 'file';

    if($::o{debug}) { ssm_print "install_softlink($name)\n"; }

    ssm_print "         FIXING:  Soft link $name -> $CONF{$etype}{$name}{target}\n";

    my $calling_function = (caller(1))[3];
    execute_prescript($name) if( $calling_function eq 'SimpleStateManager::take_file_action' );

    # If path doesn't exist, create it here
    my $dir  = dirname($name);
    if(-e $dir and ! -d $dir) { remove_file($dir); }
    eval { make_path($dir) };
    if($@) { ssm_print "Couldn’t create $dir: $@"; }

    remove_file($name);
    symlink($CONF{$etype}{$name}{target}, $name) or die "Couldn't symlink($CONF{$etype}{$name}{target}, $name) $!";
    execute_postscript($name) if( $calling_function eq 'SimpleStateManager::take_file_action' );
    
    return 1;
}


sub install_special_file {

    my $name = shift;
    my $etype = 'file';

    if($::o{debug}) { ssm_print "install_special_file($name)\n"; }

    ssm_print qq(         FIXING:  Creating ) . ucfirst($CONF{$etype}{$name}{type}) . qq( file $name\n);

    my $calling_function = (caller(1))[3];
    execute_prescript($name) if( $calling_function eq 'SimpleStateManager::take_file_action' );

    # If path doesn't exist, create it here
    my $dir  = dirname($name);
    if(-e $dir and ! -d $dir) { remove_file($dir); }
    eval { make_path($dir) };
    if($@) { ssm_print "Couldn’t create $dir: $@"; }

    remove_file($name);

    if($CONF{$etype}{$name}{type} eq 'fifo') {
        umask 0000;
        mkfifo($name, oct($CONF{$etype}{$name}{mode})) or die "Couldn't mkfifo($name, $CONF{$etype}{$name}{mode})$!";
    }
    elsif($CONF{$etype}{$name}{type} eq 'character') {
        #
        # Thanks to Jim Pirzyk, author of Unix::Mknod, for getting back to
        # me with a documentation fix that allows me to use his code here.
        # -BEF- 2006.05.08
        #
        my $mode = oct($CONF{$etype}{$name}{mode});
        mknod( $name, S_IFCHR|$mode, makedev($CONF{$etype}{$name}{major}, $CONF{$etype}{$name}{minor}) );
    }
    elsif($CONF{$etype}{$name}{type} eq 'block') {
        my $mode = oct($CONF{$etype}{$name}{mode});
        mknod( $name, S_IFBLK|$mode, makedev($CONF{$etype}{$name}{major}, $CONF{$etype}{$name}{minor}) );
    }

    set_ownership_and_permissions($name);
    execute_postscript($name) if( $calling_function eq 'SimpleStateManager::take_file_action' );

    return 1;
}


sub special_file_interactive {

    my $name   = shift;
    my $etype = 'file';

    # validate input
    if( 
           !defined($name)          or ($name !~ m/\S/)
        or !defined($CONF{$etype}{$name}{type})   or ($CONF{$etype}{$name}{type} !~ m/\S/)
        or !defined($CONF{$etype}{$name}{mode})   or ($CONF{$etype}{$name}{mode} !~ m/^\d+$/)
        or !defined($CONF{$etype}{$name}{owner})  or ($CONF{$etype}{$name}{owner} !~ m/\S/)
        or !defined($CONF{$etype}{$name}{group})  or ($CONF{$etype}{$name}{group} !~ m/\S/)
        or (
                (($CONF{$etype}{$name}{type} eq 'character') or ($CONF{$etype}{$name}{type} eq 'block')) 
                and 
                (
                       !defined($CONF{$etype}{$name}{major}) or ($CONF{$etype}{$name}{major} !~ m/^\d+$/)
                    or !defined($CONF{$etype}{$name}{minor}) or ($CONF{$etype}{$name}{minor} !~ m/^\d+$/)
                )
           )
    ) {
        return report_improper_file_definition($name);
    }

    # Does it need fixing?
    my $needs_fixing = undef;
    if( ! -e $name ) {
        $needs_fixing = 1;
    } 
    else {

        my $st = lstat($name);

        if( ! uid_gid_and_mode_match($name) ) {
            $needs_fixing = 1;
        } 
        elsif( ($CONF{$etype}{$name}{type} eq 'fifo') and (! S_ISFIFO($st_mode)) ) {
            $needs_fixing = 1;
        }
        elsif( ($CONF{$etype}{$name}{type} eq 'block') and (! S_ISBLK($st_mode)) ) {
            $needs_fixing = 1;
        }
        elsif( ($CONF{$etype}{$name}{type} eq 'character') and (! S_ISCHR($st_mode)) ) {
            $needs_fixing = 1;
        }
        elsif( ($CONF{$etype}{$name}{type} eq 'character') or ($CONF{$etype}{$name}{type} eq 'block') ) {
            if( $CONF{$etype}{$name}{major} ne major($st->rdev) ) {
                $needs_fixing = 1;
            }
            elsif ($CONF{$etype}{$name}{minor} ne minor($st->rdev) ) {
                $needs_fixing = 1;
            }
        }
    }

    # Should we actually fix it?
    my $fix_it = undef;
    if( defined($needs_fixing) ) {

        if( ! check_depends_interactive($name, $etype) ) { return 1; }

        assign_state_to_thingy($name, 'b0rken');
        declare_OK_or_Not_OK($name, 0);

        unless( $::o{summary} ) {
            declare_file_actions($name, "create $name as a $CONF{$etype}{$name}{type} special file");
            take_file_action( $name, 'install_special_file', 'yni#' );
        }

    } else {

        assign_state_to_thingy($name, 'fixed');
        declare_OK_or_Not_OK($name, 1);
    }

    return 1;
}


# Usage:
#   diff_ownership_and_permissions($name, $number_of_desired_leading_spaces);
sub diff_ownership_and_permissions {

    my $name = shift;
    my $spaces = shift;
    my $etype = 'file';

    my $st = stat($name);

    my $mode  = sprintf "%04o", $st_mode & 07777;

    my ($i, $m, $u, $g);

    ($m, $u, $g) = ($mode, (getpwuid $st_uid)[0], (getgrgid $st_gid)[0]);
    $i = 0; until ($i eq $spaces) { $i++ ; ssm_print " "; }
    ssm_print "from:  $m - $u:$g\n";

    ($m, $u, $g) = ($CONF{$etype}{$name}{mode}, (getpwuid $CONF{$etype}{$name}{owner})[0], (getgrgid $CONF{$etype}{$name}{group})[0]);
    $i = 0; until ($i eq $spaces) { $i++ ; ssm_print " "; }
    ssm_print "to:    $m - $u:$g\n";

    return 1;
}

sub get_md5sum {

    my $name = shift;

    my $md5sum;
    open(FILE, "<$name") or die "Can’t open ’$name’ for reading: $!";
        binmode(FILE);
        $md5sum = Digest::MD5->new->addfile(*FILE)->hexdigest;
    close(FILE);

    return $md5sum;
}

sub get_gid {
    
    my $name = shift;

    my $st = stat($name);
    my $gid = (getgrgid $st_gid)[0];
    
    return $gid;
}

sub get_major {
    
    my $name = shift;

    my $st = lstat($name);
    my $major = major($st->rdev);
    
    return $major;
}

sub get_minor {
    
    my $name = shift;

    my $st = lstat($name);
    my $minor = minor($st->rdev);
    
    return $minor;
}

sub get_uid {
    
    my $name = shift;

    my $st = lstat($name);
    my $uid = (getpwuid $st_uid)[0];
    
    return $uid;
}

sub get_mode {
    
    my $name = shift;

    my $st = lstat($name);
    my $mode  = sprintf "%04o", $st_mode & 07777;

    return $mode;
}


#
# Usage:  touch($name);
#
sub touch {

    my $name = shift;

    if( ! -e $name ) {
        # Ain't there -- create an empty file.  Use append just in case...
        open(FILE,">>$name") or die("Couldn't open $name for writing");
        close(FILE);
    } 

    my $mtime = time;
    my $atime = $mtime;
    utime $atime, $mtime, $name;

    return 1;
}


sub set_ownership_and_permissions {

    my $name = shift;
    my $etype = 'file';

    ssm_print "         FIXING:  Ownership and Perms: $name\n";

    touch($name);

    chown $CONF{$etype}{$name}{owner}, $CONF{$etype}{$name}{group}, $name;
    chmod oct($CONF{$etype}{$name}{mode}), $name;

    return 1;
}


sub contents_unwanted_interactive {

    ssm_print ">> contents_unwanted_interactive()\n" if( $::o{debug} );

    my $dir   = shift;
    my $etype = 'file';

    # validate input
    if(    !defined($dir)                      or ($dir                       !~ m#^/#)
        or !defined($CONF{$etype}{$dir}{type}) or ($CONF{$etype}{$dir}{type}  !~ m/\S/)
      ) {
        return report_improper_file_definition($dir);
    }

    directory_interactive($dir);

    # state what we're doing
    # get list of files in directory
    if(-d $dir) {

        my @files;
        my $file;

        opendir(DIR,"$dir") or die "Can't open $dir for reading";
            #
            # See if each file matches a defined file
            #   * test this to be sure that:
            #       If /etc/iptables.d/stuff/monkey is defined, make sure it is
            #       not removed, even if /etc/iptables.d/stuff is not explicitly
            #       defined.  It is implicitly defined.  Ie.: match on left hand
            #       side of string if necessary.
            #
            while ($file = readdir DIR) {

                next if $file =~ /^\.\.?$/;
                my $name = "$dir/$file";
                push(@files, $name) unless (defined $CONF{$etype}{$name});
            }
        closedir(DIR);

        foreach my $name (sort @files) {
            ssm_print ">>> in_directory: $dir\n" if( $::o{debug} );
            $CONF{$etype}{$name}{type} = 'unwanted';
            unwanted_file_interactive($name);
        }
    }

    return 1;
}


sub unwanted_file_interactive {

    my $name   = shift;
    my $etype = 'file';

    # validate input
    if(    !defined($name)        or ($name        !~ m#^/#)
        or !defined($CONF{$etype}{$name}{type}) or ($CONF{$etype}{$name}{type} !~ m/\S/)
    ) {
        return report_improper_file_definition($name);
    }

    # Does it need fixing?
    my $needs_fixing = undef;
    if( -e $name or -l $name ) {
        # It exists, and must be destroyed!!!
        $needs_fixing = 1;
    } 

    #
    # Should we actually fix it?
    if(defined($needs_fixing)) {

        # don't do "check_depends_interactive" for an unwanted file...

        assign_state_to_thingy($name, 'b0rken');
        declare_OK_or_Not_OK($name, 0);

        unless( $::o{summary} ) {

            declare_file_actions($name, "remove $name");
            take_file_action( $name, 'remove_file', 'ynaid#' );
        }

    } else {

        assign_state_to_thingy($name, 'fixed');
        declare_OK_or_Not_OK($name, 1);
    }

    return 1;

}


sub chown_and_chmod_interactive {

    my $name   = shift;
    my $etype = 'file';

    #
    # validate input
    if(    !defined($name)         or ($name !~ m#^/#)
        or !defined($CONF{$etype}{$name}{type})  or ($CONF{$etype}{$name}{type} !~ m/\S/)
        or !defined($CONF{$etype}{$name}{mode})  or ($CONF{$etype}{$name}{mode} !~ m/^\d+$/)
        or !defined($CONF{$etype}{$name}{owner}) or ($CONF{$etype}{$name}{owner} !~ m/\S/)
        or !defined($CONF{$etype}{$name}{group}) or ($CONF{$etype}{$name}{group} !~ m/\S/)
    ) {
        return report_improper_file_definition($name);
    }

    #
    # Does it need fixing?
    my $needs_fixing = undef;
    if( ! -e $name ) {
        $needs_fixing = 1;
    }
    elsif( ! uid_gid_and_mode_match($name) ) {
        $needs_fixing = 1;
    } 

    #
    # Should we actually fix it?
    if( defined($needs_fixing) ) {

        if( ! check_depends_interactive($name, $etype) ) { return 1; }

        assign_state_to_thingy($name, 'b0rken');
        declare_OK_or_Not_OK($name, 0);

        unless( $::o{summary} ) {

            declare_file_actions($name);
            take_file_action( $name, 'set_ownership_and_permissions', 'yni#' );
        }

    } else {

        assign_state_to_thingy($name, 'fixed');
        declare_OK_or_Not_OK($name, 1);
    }

    return 1;
}


sub directory_interactive {

    my $name   = shift;
    my $etype = 'file';

    # validate input
    if(    !defined($name)         or ($name !~ m#^/#)
        or !defined($CONF{$etype}{$name}{type})  or ($CONF{$etype}{$name}{type} !~ m/\S/)
        or !defined($CONF{$etype}{$name}{mode})  or ($CONF{$etype}{$name}{mode} !~ m/^\d+$/)
        or !defined($CONF{$etype}{$name}{owner}) or ($CONF{$etype}{$name}{owner} !~ m/\S/)
        or !defined($CONF{$etype}{$name}{group}) or ($CONF{$etype}{$name}{group} !~ m/\S/)
    ) {
        return report_improper_file_definition($name);
    }

    # Does it need fixing?
    my $needs_fixing = undef;
    my $set_ownership_and_permissions = undef;
    if( ! -e $name ) {
        # Ain't there
        $needs_fixing = 1;
    } 
    elsif( ! -d $name ) {
        # It's not a directory
        $needs_fixing = 1;
    } 
    elsif( ! uid_gid_and_mode_match($name) ) {
        $needs_fixing = 1;
        $set_ownership_and_permissions = 1;
    } 

    # Should we actually fix it?
    if( defined($needs_fixing) ) {

        if( ! check_depends_interactive($name, $etype) ) { return 1; }

        assign_state_to_thingy($name, 'b0rken');
        declare_OK_or_Not_OK($name, 0);

        unless( $::o{summary} ) {
            
            my $action;

            if( defined($set_ownership_and_permissions) ) {

                declare_file_actions($name);
                take_file_action( $name, 'set_ownership_and_permissions', 'yni#' );

            } else {

                declare_file_actions($name, "create directory $name");
                take_file_action( $name, 'install_directory', 'yni#' );
            }
        }

    } else {
        assign_state_to_thingy($name, 'fixed');
        declare_OK_or_Not_OK($name, 1);
    }

    return 1;
}


sub generated_file_interactive {

    my $name   = shift;
    my $etype = 'file';

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    #
    # validate input
    if(    !defined($name)             or ($name             !~ m#^/#   )
        or !defined($CONF{$etype}{$name}{type})      or ($CONF{$etype}{$name}{type}      !~ m/\S/   )
        or !defined($CONF{$etype}{$name}{mode})      or ($CONF{$etype}{$name}{mode}      !~ m/^\d+$/)
        or !defined($CONF{$etype}{$name}{owner})     or ($CONF{$etype}{$name}{owner}     !~ m/\S/   )
        or !defined($CONF{$etype}{$name}{group})     or ($CONF{$etype}{$name}{group}     !~ m/\S/   )
        or !defined($CONF{$etype}{$name}{generator}) or ($CONF{$etype}{$name}{generator} !~ m/\S/   )
    ) {
        return report_improper_file_definition($name);
    }

    #
    # Take the generator and write it into an executable file
    my $generator_script = choose_tmp_file();
    open(FILE,">$generator_script") or die("Couldn't open $generator_script for writing.");
        print FILE $CONF{$etype}{$name}{generator};
    close(FILE);
    chmod oct(700), $generator_script;

    # Generate file and get it's md5sum -- now considered to be the 
    # appropriate md5sum for $name.
    $CONF{$etype}{$name}{tmpfile} = choose_tmp_file();
    open(TMP, "+>$CONF{$etype}{$name}{tmpfile}") or die "Couldn't open tmp file $!";

        if( $::o{debug} ) { print ">>>  The Generator(tm): $CONF{$etype}{$name}{generator}\n"; }

        open(INPUT,"$generator_script|") or die("Couldn't run $generator_script $!");
            print TMP (<INPUT>);
        close(INPUT);
        unlink $generator_script;

        seek(TMP, 0, 0);
        $CONF{$etype}{$name}{md5sum} = Digest::MD5->new->addfile(*TMP)->hexdigest;

    close(TMP);

    #
    # Does it need fixing?
    my $needs_fixing = undef;
    my $set_ownership_and_permissions = undef;
    if( ! -e $name ) {
        # Ain't there
        $needs_fixing = 1;
    } 
    elsif( ! -f $name ) {
        # It's not a generated file
        # for now I'm thinking a generated file _must_ be a regular
        # file -- as in, no special files. -BEF-
        $needs_fixing = 1;
    } 
    elsif( ! md5sum_match($name) ) {
        $needs_fixing = 1;
    }
    elsif( ! uid_gid_and_mode_match($name) ) {
        $needs_fixing = 1;
        $set_ownership_and_permissions = 1;
    } 

    #
    # Should we actually fix it?
    if( defined($needs_fixing) ) {

        if( ! check_depends_interactive($name, $etype) ) { return 1; }

        assign_state_to_thingy($name, 'b0rken');

        ssm_print "Not OK:  Generated file $name\n";

        unless( $::o{summary} ) {

            my $action;

            if( defined($set_ownership_and_permissions) ) {

                $action = 'set_ownership_and_permissions';
                ssm_print "\n";
                ssm_print "         Need to:\n";
                ssm_print "         - fix ownership and permissions\n";
                diff_ownership_and_permissions($name, 12);

            } else {

                $action = 'install_file';
                declare_file_actions($name, "generate file $name");
            }

            take_file_action( $name, $action, 'yndi#' );
        }

    } else {
        assign_state_to_thingy($name, 'fixed');
        if( $::o{debug} ) { print ">>> Assigning $name as 'fixed'\n"; }
        ssm_print "OK:      Generated file $name\n";
    }

    unlink $CONF{$etype}{$name}{tmpfile};

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }

    return 1;
}


sub regular_file_interactive {

    my $name   = shift;
    my $etype = 'file';

    ssm_print ">> regular_file_interactive($name)\n" if( $::o{debug} );

    #
    # validate input
    if(    !defined($name)          or ($name          !~ m#^/#   )
        or !defined($CONF{$etype}{$name}{type})   or ($CONF{$etype}{$name}{type}   !~ m/\S/   )
        or !defined($CONF{$etype}{$name}{mode})   or ($CONF{$etype}{$name}{mode}   !~ m/^\d+$/)
        or !defined($CONF{$etype}{$name}{owner})  or ($CONF{$etype}{$name}{owner}  !~ m/\S/   )
        or !defined($CONF{$etype}{$name}{group})  or ($CONF{$etype}{$name}{group}  !~ m/\S/   )
        or !defined($CONF{$etype}{$name}{md5sum}) or ($CONF{$etype}{$name}{md5sum} !~ m/\S/   )
    ) {
        return report_improper_file_definition($name);
    }

    #
    # Does it need fixing?
    my $needs_fixing = undef;
    my $set_ownership_and_permissions = undef;
    if( ! -e $name ) {
        # Ain't there
        $needs_fixing = 1;
    } 
    elsif( ! -f $name ) {
        # It's not a regular file
        $needs_fixing = 1;
    } 
    elsif( ! md5sum_match($name) ) {
        $needs_fixing = 1;
    }
    elsif( ! uid_gid_and_mode_match($name) ) {
        $needs_fixing = 1;
        $set_ownership_and_permissions = 1;
    } 

    #
    # Should we actually fix it?
    if( defined($needs_fixing) ) {

        if( ! check_depends_interactive($name, $etype) ) { return 1; }

        assign_state_to_thingy($name, 'b0rken');
        ssm_print "Not OK:  Regular file $name\n";

        unless( $::o{summary} ) {

            my $action;

            if( defined($set_ownership_and_permissions) ) {

                $action = 'set_ownership_and_permissions';
                ssm_print "\n";
                ssm_print "         Need to:\n";
                ssm_print "         - fix ownership and permissions:\n";
                diff_ownership_and_permissions($name, 12);

            } else {

                $action = 'install_file';
                declare_file_actions($name, "install file from repo $name");
            }

            #
            # Decide what to do about it -- if anything
            #
            take_file_action( $name, $action, 'yndai#' );
        }
            
    } else {
        assign_state_to_thingy($name, 'fixed');
        ssm_print "OK:      Regular file $name\n";
    }

    return 1;
}


#
#   Usage:  $return_code = take_pkg_action( $action, @packages );
#
sub take_pkg_action {

    #
    # First pass is observation only.
    #
    if( $::PASS_NUMBER == 1 ) { 

        ssm_print ">>> Skipping take_pkg_action as this is the first PASS\n\n";
        return 1; 
    }

    my $action   = shift;
    my @packages; push @packages, @_;

    my $prompts  = 'yn';
    my $return_code = 0;

    if($::o{debug}) { 
        ssm_print "take_pkg_action( $action, ";
        foreach my $pkg (@packages) {
            ssm_print "$pkg ";
        }
        ssm_print ")\n";
    }

    until( $return_code == 1 ) {

        my $answer;
        
        if($main::o{no}) {
            $answer = 'n';
        } 
        elsif($::o{yes}) {
            $answer = 'y';
        } 
        else {
            $answer = do_you_want_me_to($prompts);
        }   

        if( $answer eq 'n' ) {
            $return_code = 1;

        } elsif( $answer eq 'y' ) {

            my %actions = (
                'install_pkgs'  => \&install_pkgs,
                'upgrade_pkgs'  => \&upgrade_pkgs,
                'remove_pkgs'   => \&remove_pkgs,
                'autoremove'    => \&autoremove_pkgs,
            );

            # Keep this function short and sweet by simply passing the name of the
            # action as the subroutine to execute from the list of allowable
            # subroutine actions listed above. -BEF-
            if(defined $actions{$action}) {
                if($::o{debug}) { ssm_print "return_code = $actions{$action}(@packages);\n"; }
                $return_code = $actions{$action}(@packages);

                if($return_code eq 1) {
                    $::outstanding{$action} = 'fixed'; #XXX is it really?  verify return code
                    $CHANGES_MADE++;
                }

            } else {
                ssm_print "take_pkg_action() >> DEVELOPER PEBKAC ERROR: '$action' is not a valid action\n";
                $return_code = 7;

            }

        } else {
                if($::o{debug}) { ssm_print "take_pkg_action() >> PEBKAC ERROR: '$answer' is not a valid answer\n"; }
                $return_code = 7;
        }

    }

    ssm_print "\n";

    return $return_code;
}


#
#   Usage:  $return_code = take_file_action( $name, $action );
#   Usage:  $return_code = take_file_action( $name, $action, [$prompts,] [$msg] );
#
#       Where $prompts is one or more of 'ynda'.  Order doesn't matter:
#       - y - yes
#       - n - no
#       - d - diff
#       - a - add
#       - i - ignore
#       - # - comment out
#
sub take_file_action {

    my $timer_start; my $debug_prefix; if( $main::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    #
    # test for --yes and --no and --summary right here. Hmm...
    #
    my $name    = shift;
    my $action  = shift;
    my $prompts = shift;
    my $msg     = shift;
    my $etype = 'file';

    my $return_code = 0;

    #
    # First pass is observation only.
    #
    if( $main::PASS_NUMBER == 1 ) { 

        ssm_print ">>> Skipping action as this is the first PASS\n\n";
        $return_code = 1; 
    }

    if($main::o{debug}) { 
        ssm_print "$debug_prefix ( $name, $action"; 
        ssm_print ", $prompts"  if(defined $prompts);
        ssm_print ", $msg"      if(defined $msg);
        ssm_print " )\n"; 
    }

    until( $return_code == 1 ) {

        my $answer;
        
        if($main::o{no}) {
            $answer = 'n';
        } 
        elsif($::o{yes}) {
            $answer = 'y';
        } 
        else {

            my ($retval, @unsatisfied) = check_depends($name, $etype);
            if($retval eq 2) {

                $prompts =~ s/[^n#]//g;
                ssm_print "\n";
                ssm_print "           NOTE: 'Y' is not an option due to these Unmet Dependencies:\n";
                ssm_print "\n";
                foreach (sort @unsatisfied) {
                    chomp;
                    ssm_print "                 $_\n";
                }
            }

            $answer = do_you_want_me_to($prompts);
        }   

        if( $answer eq 'n' ) {
            $return_code = 1;

        } elsif( $answer eq 'd' ) {
            diff_file($name);
            $return_code = 2;  # we did our diff, but don't want to exit the higher level loop yet

        } elsif( $answer eq 'a' ) {
            $return_code = add_file_to_repo($name);
            assign_state_to_thingy($name, 'fixed');
            $CHANGES_MADE++;

        } elsif( $answer eq '#' ) {
            $return_code = update_bundle_file_comment_out_entry($name);
            assign_state_to_thingy($name, 'fixed');
            $CHANGES_MADE++;

        } elsif( $answer eq 'i' ) {
            $return_code = add_file_to_repo($name, "ignore");
            assign_state_to_thingy($name, 'fixed');
            $CHANGES_MADE++;

        } elsif( $answer eq 'y' ) {

            my %actions = (

                'add_file_to_repo'              => \&add_file_to_repo,
                'install_directory'             => \&install_directory,
                'install_file'                  => \&install_file,
                'install_hardlink'              => \&install_hardlink,
                'install_softlink'              => \&install_softlink,
                'install_special_file'          => \&install_special_file,
                'remove_file'                   => \&remove_file,
                'set_ownership_and_permissions' => \&set_ownership_and_permissions,
            );

            # Keep this function short and sweet by simply passing the name of the
            # action as the subroutine to execute from the list of allowable
            # subroutine actions listed above. -BEF-
            if(defined $actions{$action}) {
                if($::o{debug}) { ssm_print "return_code = $actions{$action}($name);\n"; }
                $return_code = $actions{$action}($name);

                if(defined $return_code and $return_code == 1) {
                    assign_state_to_thingy($name, 'fixed');
                    $CHANGES_MADE++;
                } else {
                    print "Failed: $action($name)\n";
                }

            } else {
                ssm_print "take_file_action() >> DEVELOPER PEBKAC ERROR 1: '$action' is not a valid action\n";
                $return_code = 7;
            }

        } else {
                if($::o{debug}) { ssm_print "take_file_action() >> PEBKAC ERROR 2: '$answer' is not a valid answer\n"; }
                $return_code = 7;
        }

    }

    ssm_print "\n";

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }

    return $return_code;
}


sub md5sum_match {

    my $name = shift;
    my $etype = 'file';

    open(FILE, "<$name") or die "Can’t open ’$name’ for reading: $!";
        binmode(FILE);
        if( Digest::MD5->new->addfile(*FILE)->hexdigest eq $CONF{$etype}{$name}{md5sum} ) {
            return 1;
        }
    close(FILE);

    return undef;
}


#
#   Usage:  if( element_exists_in_repo($name, $etype) ) { do stuff; }
#
sub element_exists_in_repo {

    my $name    = shift;
    my $etype   = shift;

    if( $CONF{$etype}{$name} ) { return 1; }

    return undef;
}


#
#   Usage:  my $md5sum = get_element_md5sum($name, $etype);
#
sub get_element_md5sum {

    my $name    = shift;
    my $etype   = shift;

    if( ! element_exists_in_repo($name, $etype) ) { return undef; }
    if( ! defined($CONF{$etype}{$name}{md5sum}) ) { return undef; }
    if( $CONF{$etype}{$name}{md5sum} eq "" )      { return undef; }

    my $md5sum = $CONF{$etype}{$name}{md5sum};

    return $md5sum;
}


#
#   Usage:  my $url = get_element_url($name, $etype);
#
sub get_element_url {

    my $name    = shift;
    my $etype   = shift;

    my $md5sum = get_element_md5sum($name, $etype);
    if(! defined $md5sum) { return undef; }

    my $url = qq($::o{base_url}/$name/$md5sum);

    return $url;
}


sub diff_file {

    my $name     = shift;
    my $tmp_file = shift;
    my $etype = 'file';

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    if( $::o{summary} ) {
        # Don't do diffs in --summary mode
        return 1;
    }

    ssm_print "\n";
    ssm_print "         DIFFING:  $name\n";

    if($::o{debug}) { ssm_print "diff_file($name)\n"; }

    my $unlink;

    if( ! defined $tmp_file ) {
        if( $CONF{$etype}{$name}{tmpfile} ) {
            # generated files will have one of these
            $tmp_file = $CONF{$etype}{$name}{tmpfile};
            $unlink = 'no';
        } 
        elsif( element_exists_in_repo($name, $etype) ) {
            my $url = get_element_url($name, $etype);
            if(defined $url) {
                $tmp_file = get_file($url, 'warn');
                $unlink = 'yes';
            }
        }

        if(! defined $tmp_file) {
            $tmp_file = get_file("file:///dev/null", 'warn');
            $unlink = 'yes';
        }
    }

    my $diff;
    my $diff_cmd;
    if( $::o{no} or $::o{yes}) {
        if($::o{diff_non_interactive}) {
            $diff_cmd = $::o{diff_non_interactive};
        } else {
            # Never use colordiff if non-interactive
            foreach( "diff") {
                $diff = _which($_);
                last if( defined($diff) );
            }
            #$diff_cmd = "$diff -y";
            $diff_cmd = "$diff -u";
        }
    } else {
        if($::o{diff_interactive}) {
            $diff_cmd = $::o{diff_interactive};
        } else {
            foreach( "colordiff", "diff") {
                $diff = _which($_);
                last if( defined($diff) );
            }
            #$diff_cmd = "$diff -y";
            $diff_cmd = "$diff -u";
        }
    }

    #
    # If directory, return with friendly message.
    # 
    if( -d "$name" ) {
        print "\n";
        print "           $name is a directory.  Skipping diff operation.\n";
        return 1;
    }
    elsif( ! -e "$name" ) {
        print "\n";
        print "           $name does not yet exist, so diffing against /dev/null.\n";
        $name = '/dev/null';
    }

    ssm_print "\n";
    ssm_print "============================================================\n";
    ssm_print "#   Local version prefix:  -\n";
    ssm_print "#   Repo version prefix:   +\n";
    ssm_print "============================================================\n";

    my $cmd = qq($diff_cmd "$name" "$tmp_file");
    run_cmd($cmd, undef, 1);

    ssm_print "============================================================\n";
    ssm_print "\n";

    #
    #   apt-get install libtext-diff-perl
    #
    # use Text::Diff;
    # 
    # 
    # my $f1 = '/etc/hosts';
    # my $f2 = '/tmp/hosts';
    # $f2 = '/lib/modules/3.13.0-35-generic/kernel/drivers/ata/pata_acpi.ko';
    # 
    # my $diff;
    # if( -T $f1 and -T $f2 ) {
    #     $diff = diff $f1, $f2, { STYLE => "Table" };
    # }
    # else {
    #     $diff = "Suppressing diff -- at least one of these two files is binary.";
    # }
    # 
    # #my $diff = diff $f1, $f2, { STYLE => "Unified" };
    # #my $diff = diff $f1, $f2, { STYLE => "Context" };
    # #my $diff = diff $f1, $f2, { STYLE => "OldStyle" };
    # 
    # print "$diff\n";

    if( $unlink eq 'yes' ) {
        unlink $tmp_file;
    }

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }

    return 1;
}

sub execute_prescript {

    my $name = shift;
    my $etype = 'file';

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    if($CONF{$etype}{$name}{prescript}) {
        my $cmd = $CONF{$etype}{$name}{prescript};
        ssm_print qq(         RUNNING: $cmd\n);
        run_cmd($cmd);
    }

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }

    return 1;
}

sub execute_postscript {

    my $name = shift;
    my $etype = 'file';

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    if($CONF{$etype}{$name}{postscript}) {
        my $cmd = $CONF{$etype}{$name}{postscript};
        ssm_print qq(         RUNNING: $cmd\n);
        run_cmd($cmd);
    }

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }

    return 1;
}


sub install_directory {

    my $name = shift;
    my $etype = 'file';

    ssm_print "         FIXING:  Creating: $name\n";

    if($::o{debug}) { ssm_print "install_directory($name)\n"; }

    my $calling_function = (caller(1))[3];
    execute_prescript($name) if( $calling_function eq 'SimpleStateManager::take_file_action' );

    if(-e $name and ! -d $name) { remove_file($name); }

    my $dir = $name;
    if(-e $dir and ! -d $dir) { remove_file($dir); }
    eval { make_path($dir) };
    if($@) { ssm_print "Couldn’t create $dir: $@"; }

    set_ownership_and_permissions($name);

    execute_postscript($name) if( $calling_function eq 'SimpleStateManager::take_file_action' );

    return 1;
}


sub install_file {

    my $name     = shift;
    my $tmp_file = shift;
    my $etype = 'file';

    if($::o{debug}) { ssm_print "install_file($name)\n"; }

    ssm_print "         FIXING:  Installing: $name\n";

    my $url;
    if( ! defined $tmp_file ) {

        #
        # Apparently we weren't passed a tmp file -- good, that's the recommended method.
        #

        # If we have a pre-defined tmp file associated with this file, then use it.
        if( defined $CONF{$etype}{$name}{tmpfile} ) {

            $tmp_file = $CONF{$etype}{$name}{tmpfile};

        } else {

            $url = qq($::o{base_url}/$name/$CONF{$etype}{$name}{md5sum});
            $tmp_file = get_file($url, 'warn');
        }
    }

    if( ! defined $tmp_file ) {
        # Hmm.  get_file must have failed
        # Just drop the user back to their choices...
        return 2;
    }

    my $calling_function = (caller(1))[3];
    execute_prescript($name) if( $calling_function eq 'SimpleStateManager::take_file_action' );
    backup($name);

    # If path doesn't exist, create it here
    my $dir  = dirname($name);
    if(-e $dir and ! -d $dir) { remove_file($dir); }
    eval { make_path($dir) };
    if($@) { ssm_print "Couldn’t create $dir: $@"; }

    remove_file($name);
    copy($tmp_file, $name) or die "Failed to copy($tmp_file, $name): $!";
    unlink $tmp_file;

    set_ownership_and_permissions($name);

    execute_postscript($name) if( $calling_function eq 'SimpleStateManager::take_file_action' );

    return 1;
}


#
# my $tmp_file = get_file($name, 'nowarn');
# my $tmp_file = get_file($name, 'warn');
# my $tmp_file = get_file($name, 'error');              # the default
# my $tmp_file = get_file($name, 'error', 'silent'); 
#
sub get_file {

    # copies $name, from wherever, to a temporary file name
    # returns that temporary file name

    my $name = shift;
    my $failure_behavior = shift;
    my $silent = shift;

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(1))[3] . ":" . (caller(1))[2] . "() " . (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    $failure_behavior = 'error' if( ! defined $failure_behavior );

    my $base_file_name = "/tmp/repo-version_of_file";
    my $tmp_file = choose_tmp_file($base_file_name);

    # remove multiple slashes anywhere but after a protocol specifier
    $name =~ s#([^:/])/+#$1/#g;

    if( ($name =~ m#^file://#) or ($name =~ m#^/#) ) {

        $name =~ s#file://#/#;

        if( ! -e "$name" ) {
            if( $failure_behavior eq 'error' ) {
                ssm_print_always "ERROR: $name doesn't exist...\n\n" unless($silent);
                exit 1;
            } else {
                ssm_print "WARNING: $name doesn't exist...\n" unless($silent);
                return undef;
            }
        } else {
            copy($name, $tmp_file) or die "Failed to copy($name, $tmp_file): $!";
        }

    } elsif(    ($name =~ m#^http://# ) 
             or ($name =~ m#^https://#) 
             or ($name =~ m#^ftp://#  ) 
           ) {

        my $cmd = "wget -q $name -O $tmp_file";
        if($::o{debug}) { ssm_print "$cmd\n"; }
        unless( !system($cmd) ) {
            #
            # !system() should produce a positive result on success.  If we get
            # here, we know it failed.
            #
            if( $failure_behavior eq 'error' ) {
                ssm_print_always "ERROR: $name doesn't exist...\n\n";
                exit 1;
            } else {
                ssm_print "WARNING: $name doesn't exist...\n";
                $ERROR_LEVEL++;  if($::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }
                return undef;
            }
        }

    } else {

        ssm_print_always "\n";
        ssm_print_always "  I don't know how to acquire a file using the specified protocol:\n";
        ssm_print_always "  $name\n";
        ssm_print_always "\n";
        ssm_print_always "  You may want to verify that you have a valid 'base_url' specified\n";
        ssm_print_always "  in your configuration.\n";
        ssm_print_always "\n";

        exit 1;
    }

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }

    return $tmp_file;
}


#
# my $tmp_file = choose_tmp_file();
# my $tmp_file = choose_tmp_file($base_file_name);
#
sub choose_tmp_file {

    my $name = shift;

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(1))[3] . ":" . (caller(1))[2] . "() " . (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    unless($name) {
        $name = "/tmp/system-state-manager_tmp_file";
    }

    my $count = 0;
    while( -e "$name.$count" ) {
        $count++;
    }
    $name = "$name.$count";

    umask 0077;
    open(FILE,">$name") or die "Couldn't open $name for writing";
        print FILE "I am a little tmp file created by System State Manager.\n";
    close(FILE);

    ssm_print "$debug_prefix FILE $name\n" if( $::o{debug} );
    
    return $name;
}


sub hardlink_interactive {

    my $name   = shift;
    my $etype = 'file';

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    #
    # validate input
    unless( 
                defined($name)          and ($name          =~ m#^/#)
            and defined($CONF{$etype}{$name}{target}) and ($CONF{$etype}{$name}{target} =~ m#^/#)
            and defined($CONF{$etype}{$name}{type})   and ($CONF{$etype}{$name}{type}   =~ m/\S/)
    ) {
        return report_improper_file_definition($name);
    }

    #
    # Does it need fixing?
    my $needs_fixing = undef;
    if( ! -e $CONF{$etype}{$name}{target} ) {

        # Target ain't there
        ssm_print "WARNING: Hard link $name -> $CONF{$etype}{$name}{target} (target doesn't exist).\n";
        ssm_print "WARNING: Hard link $name -> Skipping this step.\n";
        $ERROR_LEVEL++;  if($::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }

        return 1;
    } 
    elsif( ! -e $name ) {
        # Ain't there
        $needs_fixing = 1;
    } 
    elsif( -l $name ) {
        # It's a softlink
        $needs_fixing = 1;
    } 
    else {
        #
        # See if link's inode is the same as target's inode
        my $st;

        $st = stat($name);
        my $file_inode = $st_ino;

        $st = stat($CONF{$etype}{$name}{target});
        my $target_inode = $st_ino;

        if($file_inode != $target_inode) {
            $needs_fixing = 1;
        }
    }

    #
    # Should we actually fix it?
    if( defined($needs_fixing) ) {

        if( ! check_depends_interactive($name, $etype) ) { return 1; }

        assign_state_to_thingy($name, 'b0rken');
        declare_OK_or_Not_OK($name, 0);

        unless( $::o{summary} ) {

            declare_file_actions($name, "create hard link $name");
            take_file_action($name, 'install_hardlink', 'yni#');
        }

    } else {

        assign_state_to_thingy($name, 'fixed');
        declare_OK_or_Not_OK($name, 1);
    }

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }

    return 1;
}


sub user_is_root {

    if($< == 0) { return 1; }
    return undef;
}

sub report_improper_service_definition {

    my $name = shift;
    my $etype = 'service';
    
    my ($package, $filename, $line) = caller;
    ssm_print "\n";
    ssm_print "Improper [service] definition (called from line $line of $filename)\n";
    ssm_print "\n";
    ssm_print "Here's what I know about it:\n";
    ssm_print "\n";
    ssm_print "  name   = $name\n";

    if(defined($CONF{$etype}{$name}{details})) { ssm_print "  mode   = $CONF{$etype}{$name}{details}\n";
                          } else { ssm_print "  mode   =\n"; }

    if(defined($CONF{$etype}{$name}{depends})) { ssm_print "  depends   = $CONF{$etype}{$name}{depends}\n";
                          } else { ssm_print "  depends   =\n"; }

    ssm_print "\n";
    ssm_print "  Skipping entry and incrementing ERROR_LEVEL...\n";
    ssm_print "\n";

    $ERROR_LEVEL++;
    if($::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }

    sleep 1;

    return 1;
}


sub report_improper_file_definition {

    my $name = shift;
    my $etype = 'file';

    my ($package, $filename, $line) = caller;
    ssm_print "\n";
    ssm_print "Improper [file] definition (called from line $line of $filename)\n";
    ssm_print "\n";
    ssm_print "Here's what I know about it:\n";

    if(defined($name)) { ssm_print "  name   = $name\n";
                } else { ssm_print "  name   =\n"; }

    if(defined($CONF{$etype}{$name}{type})) { ssm_print "  type   = $CONF{$etype}{$name}{type}\n";
                       } else { ssm_print "  type   =\n"; }

    if(defined($CONF{$etype}{$name}{target})) { ssm_print "  target = $CONF{$etype}{$name}{target}\n";
                         } else { ssm_print "  target =\n"; }

    if(defined($CONF{$etype}{$name}{mode})) { ssm_print "  mode   = $CONF{$etype}{$name}{mode}\n";
                       } else { ssm_print "  mode   =\n"; }

    if(defined($CONF{$etype}{$name}{owner})) { ssm_print "  owner  = $CONF{$etype}{$name}{owner}\n";
                        } else { ssm_print "  owner  =\n"; }

    if(defined($CONF{$etype}{$name}{group})) { ssm_print "  group  = $CONF{$etype}{$name}{group}\n";
                        } else { ssm_print "  group  =\n"; }

    if(defined($CONF{$etype}{$name}{major})) { ssm_print "  major  = $CONF{$etype}{$name}{major}\n";
                        } else { ssm_print "  major  =\n"; }

    if(defined($CONF{$etype}{$name}{minor})) { ssm_print "  minor  = $CONF{$etype}{$name}{minor}\n";
                        } else { ssm_print "  minor  =\n"; }

    if(defined($CONF{$etype}{$name}{md5sum})) { ssm_print "  md5sum = $CONF{$etype}{$name}{md5sum}\n";
                         } else { ssm_print "  md5sum =\n"; }

    if(defined($CONF{$etype}{$name}{prescript})) { ssm_print "  prescript = $CONF{$etype}{$name}{prescript}\n";
                            } else { ssm_print "  prescript =\n"; }

    if(defined($CONF{$etype}{$name}{postscript})) { ssm_print "  postscript = $CONF{$etype}{$name}{postscript}\n";
                             } else { ssm_print "  postscript =\n"; }

    if(defined($CONF{$etype}{$name}{depends})) { ssm_print "  depends = $CONF{$etype}{$name}{depends}\n";
                          } else { ssm_print "  depends =\n"; }

    if(defined($CONF{$etype}{$name}{generator})) { ssm_print "  generator = $CONF{$etype}{$name}{generator}\n";
                            } else { ssm_print "  generator =\n"; }

    if( defined($CONF{$etype}{$name}{type}) and ($CONF{$etype}{$name}{type} eq 'softlink') ) { 
        ssm_print "\n";
        ssm_print "  Make sure that file and target are absolute paths.  Relative\n";
        ssm_print "  links will still be created.\n";
    }

    ssm_print "\n";
    ssm_print "  Skipping entry and incrementing ERROR_LEVEL...\n";
    ssm_print "\n";

    $ERROR_LEVEL++;
    if($::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }

    sleep 1;

    return $ERROR_LEVEL;
}


sub uid_gid_and_mode_match {
    
    my $name = shift;
    my $etype = 'file';

    my $st = stat($name);

    my $mode  = sprintf "%04o", $st_mode & 07777;

    #
    # DEBUG Help
    #
    # my ($package, $filename, $line) = caller;
    # print ">> package: $package\n";
    # print ">> filename: $filename\n";
    # print ">> line: $line\n";
    # print ">> On system($mode) == in config($CONF{$etype}{$name}{mode})\n"; 

    if(    (   $mode == $CONF{$etype}{$name}{mode}  )
        and( $st_uid == $CONF{$etype}{$name}{owner} )
        and( $st_gid == $CONF{$etype}{$name}{group} ) ) {

        return 1;
    }

    return undef;
}


sub get_hostname {

    my $hostname = `hostname -f`;
    chomp $hostname;

    return $hostname;
}


sub update_bundle_file_comment_out_entry {

    my $name = shift;
    my $etype = 'file'; # XXX at some point, switch this to be passed by the calling routine, as this subroutine could handle non-file related etries as well. -BEF-

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my $new_name;

    if( $CONF{$etype}{$name}{original_name} ) {
        $name = $CONF{$etype}{$name}{original_name};
    }

    if(! $::o{"upload_url"} ) {

        _specify_an_upload_url();

        $ERROR_LEVEL++;
        if($::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }
        ssm_print "\n";

        return 3;
    }

    my @newfile;

    my $url  = "$::o{base_url}/$BUNDLEFILE{$name}";
    my $bundle_file = get_file($url, 'error');

    open(FILE, "<$bundle_file") or die("Couldn't open $bundle_file for reading");
    push my @input, (<FILE>);
    close(FILE);

    my $stanza_terminator = '^(\s+|$)';

    my $found_entry = 'no';
    while (@input) {

        $_ = shift @input;

        #
        # Match filename portion, then compare against filename we're looking for
        #                   |                |
        #                 vvvvvv            vvvvvvvvvvv
        if( m|^name\s*=\s*(\S.*)\s+$|  and  $1 eq $name ) {

            #
            # We've got a hit!  Rewind until we get to the beginning of the
            # stanza (the named file may occur anywhere in the stanza) -BEF-
            #
            until ($_ =~ m/^\[file\]/ ) {
                unshift @input, $_;
                $_ = pop @newfile;
            }

            if( $CONF{new_name}{$name} ) {
                ssm_print qq(Updating:  Commenting out entry for "$CONF{new_name}{$name}" in config file "$BUNDLEFILE{$name}".\n);
                ssm_print qq(           The entry for "$CONF{new_name}{$name}" in the config file is "$name".\n);
            } else {
                ssm_print qq(Updating:  Commenting out entry for "$name" in config file "$BUNDLEFILE{$name}".\n);
            }

            my $hostname = get_hostname();
            push @newfile, "#\n";
            push @newfile, "# Commented out via ssm client on $hostname at " . get_current_time_as_timestamp() . "\n";
            push @newfile, "#\n";

            until( m/$stanza_terminator/ ) {

                # Comment out each entry
                s/(.*)/#$1/;

                # Add line to new file
                push @newfile, $_;

                # Get next line to process
                $_ = shift @input;
            }
        }

        # Add all other lines into newfile verbatim
        push @newfile, $_;
    }

    my $tmp_bundle_file = choose_tmp_file();
    open(FILE, ">$tmp_bundle_file") or die("Couldn't open $tmp_bundle_file for writing");
    print FILE @newfile;
    close(FILE);

    copy_file_to_upstream_repo($tmp_bundle_file, $BUNDLEFILE{$name});
    unlink $tmp_bundle_file;

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }

    return 1;
}


#
# Usage:
#   my $name = update_or_add_file_stanza_to_bundlefile( %filespec );
#
#       Where %filespec keys may include the following:
#           name
#           comment
#           type
#           owner
#           group
#           mode
#           md5sum
#           target
#           major
#           minor
#
sub update_or_add_file_stanza_to_bundlefile {

    #
    # Name of system file in question, and attributes
    #
    my %filespec   = @_;
    my $etype = 'file';

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    show_debug_output_for_filespec($debug_prefix, %filespec) if( $::o{debug} );

    my $timestamp = get_current_time_as_timestamp();
    my $hostname  = get_hostname();
    $filespec{comment} = "From $hostname on $timestamp";

    my $url  = "$::o{base_url}/$BUNDLEFILE{$filespec{name}}";
    my $bundlefile = get_file($url, 'error');
    open(FILE, "<$bundlefile") or die("Couldn't open $bundlefile for reading");
    push my @input, (<FILE>);
    close(FILE);
    unlink $bundlefile;

    my $stanza_terminator = '^(\s+|$)';

    my @newfile;
    my $found_entry = 'no';
    while (@input) {

        $_ = shift @input;

        #
        # Match filename portion
        #                   |
        #                 vvvvvv
        if( m|^name\s*=\s*(\S.*)\s+$| ) {

            my $name_entry = normalized_file_name( $1 ); 

            # then compare against filename we're looking for
            if( $name_entry eq $filespec{name} ) {

                $found_entry = 'yes';

                #
                # We've got a hit!  Rewind until we get to the beginning of the
                # stanza (the named file may occur anywhere in the stanza) -BEF-
                #
                until ($_ =~ m/^\[file\]/ ) {
                    unshift @input, $_;
                    $_ = pop @newfile;
                }

                until( m/$stanza_terminator/ ) {

                    #
                    # Allow for, but normalize, existing "key = value" or "key=value" type definitions.
                    s#^name\s*=.*#name        = $filespec{name}#;

                    if(m/^comment\s*=/) {
                        if(defined $filespec{comment}) {
                            s/^comment\s*=.*/comment     = $filespec{comment}/;
                        } else {
                            s/^(comment\s*=.*)/# $1/;
                        }
                    }

                    if(m/^type\s*=/) {
                        if(defined $filespec{type}) {
                            s/^type\s*=.*/type        = $filespec{type}/;
                        } else {
                            s/^(type\s*=.*)/# $1/;
                        }
                    }

                    if(m/^owner\s*=/) {
                        if(defined $filespec{owner}) {
                            s/^owner\s*=.*/owner       = $filespec{owner}/;
                        } else {
                            s/^(owner\s*=.*)/# $1/;
                        }
                        delete $filespec{owner};
                    }

                    if(m/^group\s*=/) {
                        if(defined $filespec{group}) {
                            s/^group\s*=.*/group       = $filespec{group}/;
                        } else {
                            s/^(group\s*=.*)/# $1/;
                        }
                        delete $filespec{group};
                    }

                    if(m/^mode\s*=/) {
                        if(defined $filespec{mode}) {
                            s/^mode\s*=.*/mode        = $filespec{mode}/;
                        } else {
                            s/^(mode\s*=.*)/# $1/;
                        }
                        delete $filespec{mode};
                    }

                    if(m/^md5sum\s*=/) {
                        #
                        # When we match the md5sum bit, comment out the prior entry,
                        # but keep it for posterity, then add the new entry too.
                        #
                        s/^(md5sum\s*=.*)/# $1/;
                        if(defined $filespec{md5sum}) {
                            $_ .=       "md5sum      = $filespec{md5sum}  # $timestamp\n";
                            delete $filespec{md5sum};
                        }
                    }


                    if(m/^target\s*=/) {
                        if(defined $filespec{target}) {
                            s/^target\s*=.*/target     = $filespec{target}/;
                        } else {
                            s/^(target\s*=.*)/# $1/;
                        }
                        delete $filespec{target};
                    }

                    if(m/^major\s*=/) {
                        if(defined $filespec{major}) {
                            s/^major\s*=.*/major     = $filespec{major}/;
                        } else {
                            s/^(major\s*=.*)/# $1/;
                        }
                        delete $filespec{major};
                    }

                    if(m/^minor\s*=/) {
                        if(defined $filespec{minor}) {
                            s/^minor\s*=.*/minor     = $filespec{minor}/;
                        } else {
                            s/^(minor\s*=.*)/# $1/;
                        }
                        delete $filespec{minor};
                    }

                    push @newfile, $_;

                    $_ = shift @input;
                }

                # Add any entries that did not exist in the original filespec, but only in the new file (ie. changed from regular to softlink)
                foreach my $key (keys %filespec) {
                    next if( $key =~ /^(name|type|comment)$/ );
                    push @newfile, "$key     = $filespec{$key}\n";
                    print ">>> $key       = $filespec{$key} <<<\n";
                }
            }
        }

        push @newfile, $_;
    }

    if( $found_entry eq 'yes' ) {

        ssm_print qq(Updating:  Entry for "$filespec{name}" in configuration file "$BUNDLEFILE{$filespec{name}}" as type $filespec{type}.\n);

    } else {

        ssm_print qq(Adding:  Entry for "$filespec{name}" in configuration file "$BUNDLEFILE{$filespec{name}}" as type $filespec{type}.\n);

        push @newfile,   "\n";
        push @newfile,   "[file]\n";
        push @newfile,   "name        = $filespec{name}\n";
        push @newfile,   "comment     = $filespec{comment}\n"                          if(defined $filespec{comment});
        push @newfile,   "type        = $filespec{type}\n"                   if(defined $filespec{type});
        push @newfile,   "owner       = $filespec{owner}\n"                  if(defined $filespec{owner});
        push @newfile,   "group       = $filespec{group}\n"                  if(defined $filespec{group});
        push @newfile,   "mode        = $filespec{mode}\n"                   if(defined $filespec{mode});

        push @newfile,   "target      = $filespec{target}\n"                 if(defined $filespec{target});
        push @newfile,   "md5sum      = $filespec{md5sum}  # $timestamp\n"   if(defined $filespec{md5sum});
        push @newfile,   "major       = $filespec{major}\n"                  if(defined $filespec{major});
        push @newfile,   "minor       = $filespec{minor}\n"                  if(defined $filespec{minor});
        push @newfile,   "\n";

    }

    my $name = choose_tmp_file();
    open(FILE, ">$name") or die("Couldn't open $name for writing");
    print FILE @newfile;
    close(FILE);

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }

    return $name;
}

#
#   show_debug_output_for_filespec( $debug_prefix, %filespec );
#
sub show_debug_output_for_filespec {

    my $debug_prefix = shift;
    my %filespec   = @_;

    foreach ("type", "name", "owner", "group", "mode", "md5sum", "target", "major", "minor") {
        ssm_print "$debug_prefix \$filespec{$_} = $filespec{$_}\n" if( $filespec{$_} );
    }

    return 1;
}


#
# Usage:
#   my $name = add_bundlefile_stanza_to_bundlefile( $new_bundlefile );
#
sub add_bundlefile_stanza_to_bundlefile {

    #
    # Name of system file in question, and attributes
    #
    my $new_bundlefile = shift;

    my $timestamp = get_current_time_as_timestamp();
    my $hostname  = get_hostname();
    my $comment   = "From $hostname on $timestamp";

    # For now we always put added bundlefiles into the main config file
    my $parent_bundlefile = basename( $::o{config_file} );

    my $url  = "$::o{base_url}/$parent_bundlefile";

    my $bundlefile_copy = get_file($url, 'error');
    open(FILE, "<$bundlefile_copy") or die("Couldn't open $bundlefile_copy for reading");
    push my @input, (<FILE>);
    close(FILE);
    unlink $bundlefile_copy;

    my @newstanza;
    push @newstanza, "[bundles]\n";
    push @newstanza, "$new_bundlefile\n";
    push @newstanza,   "\n";

    ssm_print qq(Adding:  The following bundles stanza to configuration file "$parent_bundlefile":\n);
    ssm_print "\n";
    foreach (@newstanza) {
        ssm_print qq(  $_);
    }
    
    # Append the new stanza to the existing bundle file
    my @newfile;
    push @newfile, @input;
    push @newfile, "\n";
    push @newfile, @newstanza;
    
    my $name;

    # Add comment to top of new bundlefile and drop it in repo
    $name = choose_tmp_file();
    open(FILE, ">$name") or die("Couldn't open $name for writing");
    print FILE qq(#\n);
    print FILE qq(# $comment\n);
    print FILE qq(#\n);
    close(FILE);
    copy_file_to_upstream_repo($name, $new_bundlefile);

    # Add entry to parent bundle file and copy up to repo
    $name = choose_tmp_file();
    open(FILE, ">$name") or die("Couldn't open $name for writing");
    print FILE @newfile;
    close(FILE);
    copy_file_to_upstream_repo($name, $parent_bundlefile);

    # Now that the files have been updated and put in place, add the new
    # bundlefile to the "it exists list"
    $BUNDLEFILE_LIST{$new_bundlefile} = 1;

    return 1;
}


#
# Usage:
#   my $name = add_package_stanza_to_bundlefile( @pkg_entries );
#
#       Where @pkg_entries may include the following:
#
#           PKGNAME   OPTIONS
#
#       Example:
#           syslog-ng
#           rsync
#           zsh
#           zip
#           klogd       unwanted
#           lynx        priority=99
#           sysklogd    unwanted,priority=3
#
sub add_package_stanza_to_bundlefile {

    #
    # Name of system file in question, and attributes
    #
    my @pkg_entries   = @_;

    my $timestamp = get_current_time_as_timestamp();
    my $hostname  = get_hostname();
    my $comment   = "From $hostname on $timestamp";

    my $bundlefile = choose_valid_bundlefile();
    unless($bundlefile) {
        return 3;
    }

    my $url  = "$::o{base_url}/$bundlefile";

    my $bundlefile_copy = get_file($url, 'error');
    open(FILE, "<$bundlefile_copy") or die("Couldn't open $bundlefile_copy for reading");
    push my @input, (<FILE>);
    close(FILE);
    unlink $bundlefile_copy;

    my @newstanza;
    push @newstanza,   "[packages]\n";
    push @newstanza,   "#\n";
    push @newstanza,   "# Added on host $hostname on $timestamp\n";
    push @newstanza,   "#\n";
    foreach (@pkg_entries) {
        chomp;
        push @newstanza, "$_\n" unless(m/^\s/);
    }
    push @newstanza,   "\n";

    ssm_print qq(Adding:  The following package stanza to configuration file "$bundlefile".\n\n);
    foreach (@newstanza) {
        ssm_print qq(  $_);
    }
    
    # Append the new stanza to the existing bundle file
    my @newfile;
    push @newfile, @input;
    push @newfile, "\n";
    push @newfile, @newstanza;

    my $name = choose_tmp_file();
    open(FILE, ">$name") or die("Couldn't open $name for writing");
    print FILE @newfile;
    close(FILE);

    return $name;
}


sub turn_service_into_file_entry {

    my $name = shift;
    my $etype = 'service';

    my $dir = "/etc";

    my %details;
    foreach( split(/\s+/, $CONF{$etype}{$name}{details}) ) {
        my ($level, $prefix) = split(/:/);
        $details{$level} = ${prefix};
    }

    opendir(DIR,"$dir");
    my @dirs = grep { /^rc.\.d$/ && -d "$dir/$_" } readdir(DIR);
    closedir(DIR);

    foreach my $subdir (@dirs) {

        #
        # Get a list of all links to the init script, and pre-determine
        # them as 'unwanted'.  Their state will be overridden further
        # below if they exist in the state definition.
        #
        opendir(DIR,"$dir/$subdir");
        foreach( grep { /[SK]\d+$name$/ } readdir(DIR) ) {
            my $name = "$dir/$subdir/$_";
            $CONF{file}{$name}{type} = 'unwanted';
        }
        closedir(DIR);

        $subdir =~ m/rc(.)\.d/;
        my $level = $1;

        if(defined ($details{$level})) {
            my $prefix = $details{$level};
            my $name = "$dir/rc${level}.d/${prefix}${name}";
            $CONF{file}{$name}{type} = 'softlink';
            $CONF{$etype}{$name}{target} = "$dir/init.d/$name";
        }
    }

    return 1;
}


#
#   Usage:
#
#       my ($retval, @unsatisfied) = check_depends($name, $etype);
#
# Returns $retval eq '1' and @unsatisfied is empty, if dependencies are satisfied
# Returns $retval eq '2' and @unsatisfied as a list of unsatisfied dependencies, if unsatisfied
#
sub check_depends {

    my $name = shift;
    my $etype = shift;

    if(! defined $CONF{file}{$name}{type}) {
        ssm_print ">> name: $name\n" if( $::o{debug} );
        return 1;
    }

    my @unsatisfied;
    my %pkgs_currently_installed;

    #
    # No dependencies to check?  That's OK.  Return success.
    if(! defined $CONF{$etype}{$name}{depends}) { return 1; }

    if( $::o{debug} ) { print ">>> Dependencies for $name: $CONF{$etype}{$name}{depends}\n"; }
    
    #
    # Only check for pkgs if there's a pkg in the dependency list.  pkg
    # checking is an expensive process. -BEF-
    #
    if($CONF{$etype}{$name}{depends} =~ m/(^|\s)\w/ ) {    # Match package names in the list

        if( $::o{pkg_manager} eq 'none' ) {
            ssm_print "\n";
            ssm_print "           ERROR: No package manager is specified, but this configuration item\n";
            ssm_print "           ERROR: specifies one or more packages as dependencies.\n";
            ssm_print "           ERROR:\n";
            ssm_print "           ERROR:   $name\n";
            ssm_print "           ERROR:\n";
            ssm_print "           ERROR: Please review this item in config file $BUNDLEFILE{$name}\n";
            ssm_print "\n";

            exit 1;
        }

        %pkgs_currently_installed = get_pkgs_currently_installed();
    } 

    foreach( split(/\s+/, $CONF{$etype}{$name}{depends}) ) {
        #
        # Check file dependencies
        #
        if( /^\// ) {

            if( $::o{debug} ) { print ">>>> Checking on status of $_\n"; }
            #
            # Must be a file.  
            #
            my $file_dep = $_;

            if($file_dep =~ m|^$name/|) {

                my $calling_function = (caller(1))[3];
                if($calling_function eq 'SimpleStateManager::take_file_action') {

                    ssm_print "\n";

                    ssm_print "           WARNING: $name has $file_dep specified as a dependency.  This is\n";
                    ssm_print "           WARNING: probably not a good idea, as $file_dep would have to be\n";
                    ssm_print "           WARNING: a file inside $name (as a directory).  This could lead\n";
                    ssm_print "           WARNING: to a non-resolvable dependency.\n";

                    sleep 1;
                }
            }

            if( ! -e $file_dep) {  

                # If it doesn't exist, fail dep check.
                push @unsatisfied, $file_dep;
                if( $::o{debug} ) { print ">>>>>  $_ doesn't exist\n"; }

            } elsif( defined $::outstanding{$file_dep} and $::outstanding{$file_dep} ne 'fixed') {

                push @unsatisfied, $file_dep;
                if( $::o{debug} ) { print ">>>>>  $_ exists, but isn't considered 'fixed'\n"; }

            } else {

                if( $::o{debug} ) { print ">>>>> $_ exists, and isn't defined so it's mere existence makes it OK.\n"; }
            }
        } 
        # Check package dependencies
        else {
            #
            # Must be a package.  See if it's installed.
            my $pkg = $_;
            if( ! defined $pkgs_currently_installed{$pkg} ) { 
                push @unsatisfied, $pkg;
                if( $::o{debug} ) { print ">>>>> $pkg isn't installed, so keeping in the unsatisfied dependency list.\n"; }
            }
        }
    }

    # Looks like we have some unresolved issues.  Get thee to a counselor...
    if(@unsatisfied) { return (2, @unsatisfied); }
}


#
# do we check for recursion loops?  Nah.  Not yet, anyway. ;-) -BEF-
#
sub _include_bundle {

    my $name = shift;

    chomp($name);
    ssm_print "Bundle:  $name\n" unless($::o{only_this_file});

    $BUNDLEFILE_LIST{$name} = 1;

    # For --analyze-config purposes, prefix the input data from this
    # bundle file with it's own name as a BundleFile. -BEF-
    my @array;
    push @array, "\n";
    push @array, "BundleFile: $name\n";
    push @array, "\n";

    unless(($name =~ m#^file://#) 
        or ($name =~ m#^/#)
        or ($name =~ m#^http://#) 
        or ($name =~ m#^https://#) 
        or ($name =~ m#^ftp://#)) {

        $name = $::o{base_url} . '/' . $name;
    }

    my $tmp_file = get_file($name, 'error');

    open(FILE,"<$tmp_file") or die "Couldn't open $tmp_file for reading: $!";
        push @array, (<FILE>);
    close(FILE);
    unlink $tmp_file;

    #
    # Now add a blank line at the end of the array... -BEF-
    push( @array, "\n" );

    return @array;
}

sub backup {

    my $name = shift;

    if( ! -e "/usr/bin/bu" ) { return 1; }
    if( ! -e $name ) { return 1; }

    my $cmd = "/usr/bin/bu $name";
    !system($cmd) or die("FAILED: $cmd\n $!");

    return 1;
}


sub add_new_packages {

    push @{$::o{add_package}}, @ARGV;

    my $return_code = verify_packages_exist(@{$::o{add_package}});

    if( $return_code == 1 ) {

        add_packages_to_repo(@{$::o{add_package}});
        $CHANGES_MADE++;

    } else {

        ssm_print "\n";
        ssm_print "ERROR:   One or more packages couldn't be found in this sytem's configured\n";
        ssm_print "         package repositories.  Maybe check your spelling?\n";
        ssm_print "\n";
    }

    my $errors = $return_code - 1;
    $ERROR_LEVEL += $errors;

    return ($ERROR_LEVEL, $CHANGES_MADE);
}


sub add_new_files {

    push @{$::o{add_file}}, @ARGV;

    foreach my $name ( @{$::o{add_file}} ) {
        add_file_to_repo($name);
        $CHANGES_MADE++;
    }

    return ($ERROR_LEVEL, $CHANGES_MADE);
}


#
#   Usage:  my $type = get_file_type($nam$name
#
#   Detects the following file types:
#   - block
#   - character
#   - directory
#   - fifo
#   - hardlink  (detected as a regular file)
#   - regular
#   - softlink
#
sub get_file_type {
    
    my $name = shift;

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my $type;

    if( lstat($name) ) {

        if( S_ISLNK($st_mode) ) {
            $type = 'softlink';
        }
        elsif( S_ISREG($st_mode) ) {
            $type = 'regular';
        }
        elsif( S_ISDIR($st_mode) ) {
            $type = 'directory';
        }
        elsif( S_ISFIFO($st_mode) ) {
            $type = 'fifo';
        }
        elsif( S_ISBLK($st_mode) ) {
            $type = 'block';
        }
        elsif( S_ISCHR($st_mode) ) {
            $type = 'character';
        }

    } elsif( -l $name ) {

        # For some reason (a bug in perl maybe?), some symlinks may not be
        # successfully detected with stat, but are with this method.  -BEF-
        $type = 'softlink';

    } else {
        $type = 'non-existent';
    }

    return $type;
}


sub verify_packages_exist {

    my @packages = @_;

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my @packages_with_no_options;
    push @packages_with_no_options, @packages;
    s/\s+.*// for @packages_with_no_options;

    load_pkg_manager_functions();
    my $return_code = verify_pkgs_exist( @packages_with_no_options );

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }

    return $return_code;
}


sub add_packages_to_repo {

    my @packages = @_;

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my $bundlefile = choose_valid_bundlefile();
    unless($bundlefile) {
        return 3;
    }

    my $tmp_file = add_package_stanza_to_bundlefile( @packages );
    copy_file_to_upstream_repo($tmp_file, $bundlefile);
    unlink $tmp_file;

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }

    return 1;
}


sub add_file_to_repo {

    my $name = shift;
    my $type = shift;   # allow explicit declaration of type (e.g.: ignored, directory+contents-unwanted, etc.)

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    if( $name !~ m|^/| ) {
        ssm_print "$debug_prefix Finding fully qualified file name $name" if($::o{debug});
        $name = fully_qualified_file_name($name);
        ssm_print " => $name\n" if($::o{debug});
    }

    $name = normalized_file_name( $name ); 

    if(! defined $BUNDLEFILE{$name}) {
        $BUNDLEFILE{$name} = choose_valid_bundlefile();
    }

    if( ! defined $type ) {
        $type = get_file_type($name);
    }

    if($type eq 'non-existent') {
        ssm_print "ERROR:   File $name does not appear to exist!\n";
        $ERROR_LEVEL++;
        return 3;
    }
    ssm_print "$debug_prefix FILE $name is of TYPE $type\n" if($::o{debug});

    if($type eq 'regular') {
        add_file_to_repo_type_regular($name);
    }
    else {
        add_file_to_repo_type_nonRegular($name, $type);
    }

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }

    return 1;
}


sub add_file_to_repo_type_nonRegular {

    my $name   = shift;
    my $type   = shift;

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my %filespec;
    $filespec{type}     = $type;
    $filespec{name}     = $name;
    $filespec{owner}    = get_uid($name)        unless( ($filespec{type} eq 'ignore') );
    $filespec{group}    = get_gid($name)        unless( ($filespec{type} eq 'ignore') );
    $filespec{mode}     = get_mode($name)       unless( ($filespec{type} eq 'ignore') or ($filespec{type} eq 'softlink') );
    $filespec{target}   = readlink($name)           if( ($filespec{type} eq 'softlink') );
    $filespec{major}    = get_major($name)          if( ($filespec{type} eq 'character') or ($filespec{type} eq 'block') );
    $filespec{minor}    = get_minor($name)          if( ($filespec{type} eq 'character') or ($filespec{type} eq 'block') );;

    #show_debug_output_for_filespec($debug_prefix, %filespec) if( $::o{debug} );

    my $tmp_file = update_or_add_file_stanza_to_bundlefile( %filespec );

    my $bundlefile = "$BUNDLEFILE{$name}";
    copy_file_to_upstream_repo($tmp_file, $bundlefile);
    unlink $tmp_file;

    assign_state_to_thingy($name, 'fixed');

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }

    return 1;
}


sub add_file_to_repo_type_regular {

    my $name   = shift;
    my $etype = 'file';

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my %filespec;
    $filespec{type}     = 'regular';
    $filespec{name}     = $name;
    $filespec{owner}    = get_uid($name);
    $filespec{group}    = get_gid($name);
    $filespec{mode}     = get_mode($name);
    $filespec{md5sum}   = get_md5sum($name);

    #show_debug_output_for_filespec($debug_prefix, %filespec) if( $::o{debug} );

    # Copy the file itself into the repo, unless a version with the same md5sum is already there...
    unless($CONF{$etype}{$name}{md5sum} and ($CONF{$etype}{$name}{md5sum} eq $filespec{md5sum}) ) {
        my $filename_in_repo = "$name/$filespec{md5sum}";
        copy_file_to_upstream_repo($name, $filename_in_repo);
    }

    my $tmp_file = update_or_add_file_stanza_to_bundlefile( %filespec );

    my $bundlefile = "$BUNDLEFILE{$name}";
    copy_file_to_upstream_repo($tmp_file, $bundlefile);
    unlink $tmp_file;

    assign_state_to_thingy($name, 'fixed');

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }

    return 1;
}


#
# For packages or files
#
#   my $bundlefile = choose_valid_bundlefile( $proposed_bundlefile );
#   my $bundlefile = choose_valid_bundlefile();
#
#       If no proposed bundlefile is included, then it will prefer a bundlefile
#       specified on the command line, then fall back to the main config file.
#
sub choose_valid_bundlefile {

    my $proposed_bundlefile = shift;

    if(! defined $::o{upload_url}) {

        _specify_an_upload_url();

        $ERROR_LEVEL++;
        if($::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }
        ssm_print "\n";

        return undef;
    }

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    if(! defined $proposed_bundlefile) {
        $proposed_bundlefile = $::o{bundlefile};
    }

    # If a bundlefile was specified on the command line
    if($proposed_bundlefile) {

        if( ! $BUNDLEFILE_LIST{$proposed_bundlefile} ) {
            #
            # Hmm.  The specified bundlefile doesn't exist in this config.  
            #
        
            #
            # Check to see if it exists in the repo.  
            #
            my $url  = "$::o{base_url}/$proposed_bundlefile";
            my $tmpfile = get_file($url, 'warn', 'silent');

            if($tmpfile) {
                # It does exist!  Let's bail. -BEF-
                ssm_print "\n";
                ssm_print "ERROR: The bundlefile you specified, $proposed_bundlefile, exists in the\n";
                ssm_print "       repository, but is not currently referenced by this config.  It \n";
                ssm_print "       might be used by a different config, in which case it could be \n";
                ssm_print "       dangerous to the other config if we change it, and it's existing\n";
                ssm_print "       contents could be dangerous to this config.\n";
                ssm_print "\n";
                ssm_print "       Please specify either a totally new bundlefile or one that is \n";
                ssm_print "       already in use by this config. -The Mgmt\n";
                ssm_print "\n";
        
                unlink $tmpfile;

                exit 1;
        
            } else {

                #
                # The user has specified a new bundlefile.
                #
                add_bundlefile_stanza_to_bundlefile($proposed_bundlefile);
            }
        }

        #
        # Ok, it's passed the test.  It exists and it's already in the config.  Let's use it.
        #
        return $proposed_bundlefile;

    } else {
        #
        # And no bundlefile preference was specified, so we default to
        # adding it to the main configuration file. -BEF-
        #
        return basename( $::o{config_file} );
    }
}


#   Example:
#
#   my $name = "/tmp/$PROGNAME.log";
#   my $ending_lognumber    = 7;
#   my $starting_lognumber  = 1;
#   rotate_log_file($name, $starting_lognumber, $ending_lognumber);
#
sub rotate_log_file {

    my $name                = shift;
    my $starting_lognumber  = shift;
    my $ending_lognumber    = shift;

    my $i = $ending_lognumber;

    until( $i == $starting_lognumber ) {

        my $file_old = "$name." . ($i - 1);
        my $file_new = "$name." . $i;

        if( -e $file_old ) {
            #if( $::o{debug} ) { print " rename($file_old, $file_new)\n"; }
            rename($file_old, $file_new) or die("Couldn't rename $file_old to $file_new");
        }

        $i--;
    }

    my $file_old = $name;
    my $file_new = "$name.$starting_lognumber";

    if( -e $file_old ) {
        if( $::o{debug} ) { print " rename($file_old, $file_new)\n"; }
        rename($file_old, $file_new) or die("Couldn't rename $file_old to $file_new");
    }

    return 1;
}

#
# This is a pure perl which command.
# 
#   my $command = _which("rsync");
#   my $command = _which("rsync", "/usr/bin:/usr/sbin:/bobs/bargin/bin");
#
sub _which {

    my $name    = shift;
    my $path    = shift;

    if(! defined($path)) {
        $path = $ENV{PATH};
    }

    foreach my $dir (split(/:/,$path)) {
        my $binary = "$dir/$name";
        if(-x $binary) {
            return $binary;
        }
    }
    return undef;
}

#
# Usage: remove_file($name);
#        remove_file($name,'verbose');
#
sub remove_file {

    my $name         = shift;
    my $verbose      = shift;
    my $run_scripts  = shift;

    ssm_print "         FIXING:  Removing: $name\n" if( defined $verbose );

    if($::o{debug}) { ssm_print "remove_file($name)\n"; }

    #
    # remove_file is called by a number of subroutines as a supporting file
    # action, but we don't want to go off running pre and post scripts every
    # time it's called.  We only want to do it when it's called as the primary
    # file action.
    #
    # So, we test to see if it was called directly by
    # SimpleStateManager::take_file_action, which indicates it's the primary
    # file action, in which case we should run the pre and post scripts. 
    #
    my $calling_function = (caller(1))[3];
    execute_prescript($name) if( $calling_function eq 'SimpleStateManager::take_file_action' );

    remove_tree( $name, { 
        verbose => $verbose,
        safe => 1,
    });

    execute_postscript($name) if( $calling_function eq 'SimpleStateManager::take_file_action' );

    return 1;
}

sub compare_package_options {

    my $pkg                 = shift;
    my $challenger_options  = shift;

    ssm_print "compare_package_options()\n" if( $::o{debug} );

    my $incumbent_options   = $::PKGS_FROM_STATE_DEFINITION{$pkg};

    ssm_print "compare_package_options() >> pkg: $pkg\n" if( $::o{debug} );
    ssm_print "compare_package_options() >> challenger_options: $challenger_options\n" if( $::o{debug} );
    ssm_print "compare_package_options() >> incumbent_options:  $incumbent_options\n" if( $::o{debug} );

    if($incumbent_options eq '') {
        return $challenger_options;

    } elsif($challenger_options eq '') {
        return $incumbent_options;
    }

    my $incumbent_priority;
    if($incumbent_options =~ m/\bpriority=(\d+)/i) {
        $incumbent_priority = $1;
    } else {
        $incumbent_priority = 0;
    }
    #ssm_print "compare_package_options() >> incumbent_priority:  $incumbent_priority\n" if( $::o{debug} );

    my $challenger_priority;
    if($challenger_options =~ m/\bpriority=(\d+)/i) {
        $challenger_priority = $1;
    } else {
        $challenger_priority = 0;
    }
    #ssm_print "compare_package_options() >> challenger_priority:  $challenger_priority\n" if( $::o{debug} );

    my $winning_options;
    if($challenger_priority > $incumbent_priority) {
        $winning_options = $challenger_options;
    } else {
        $winning_options = $incumbent_options;
    }
    ssm_print "compare_package_options() >> winning_options:  $winning_options\n" if( $::o{debug} );

    return $winning_options;
}


sub remove_packages_interactive {

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    # Only do pkg stuff on later passes
    return 1 if( $::PASS_NUMBER == 1 );

    my %pending_pkg_changes = get_pending_pkg_changes('remove');

    if(%pending_pkg_changes) {

        ssm_print "Not OK:  Package removes\n";
        ssm_print "\n";
        ssm_print "         Need to:\n";

        my $max_length = 0;
        foreach my $pkg (sort keys %pending_pkg_changes) {
            my $length = length $pending_pkg_changes{$pkg};
            if($length > $max_length) {
                $max_length = $length;
            }
        }

        my @sort_list;
        foreach my $pkg (sort keys %pending_pkg_changes) {

            my $action = lc( $pending_pkg_changes{$pkg}{action} );
            my $pad = get_pad($max_length - length($action));

            push @sort_list, "- ${action}${pad} $pkg";
        }

        foreach my $line (sort @sort_list) {
            ssm_print "         $line\n";
        }

        take_pkg_action('remove_pkgs', (keys %pending_pkg_changes) );

    } else {
        ssm_print "OK:      Package removes\n";
    }

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }

    return 1;
}


sub autoremove_packages_interactive {

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    # Only do pkg stuff on later passes
    return 1 if( $::PASS_NUMBER == 1 );

    my %pending_pkg_changes = get_pending_pkg_changes('autoremove');

    if(%pending_pkg_changes) {

        if( $pending_pkg_changes{'-autoremove_unsupported'} ) {

            ssm_print "INFO:     Package autoremoves -> not supported by this package manager\n";

        } else {

            ssm_print "Not OK:  Package autoremoves\n";
            ssm_print "\n";
            ssm_print "         Need to:\n";

            my $max_length = 0;
            foreach my $pkg (sort keys %pending_pkg_changes) {

                ssm_print "$debug_prefix PKG $pkg\n" if($o::{debug});

                my $length = length $pending_pkg_changes{$pkg};
                if($length > $max_length) {
                    $max_length = $length;
                }
            }

            my @sort_list;
            foreach my $pkg (sort keys %pending_pkg_changes) {

                my $action = lc( $pending_pkg_changes{$pkg}{action} );
                my $pad = get_pad($max_length - length($action));
                push @sort_list, "- ${action}${pad} $pkg";
            }

            foreach my $line (sort @sort_list) {
                ssm_print "         $line\n";
            }

            take_pkg_action('autoremove', (keys %pending_pkg_changes) );
        }

    } else {
        ssm_print "OK:      Package autoremoves\n";
    }

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }

    return 1;
}


sub upgrade_packages_interactive {

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    # Only do pkg stuff on later passes
    return 1 if( $::PASS_NUMBER == 1 );

    my %pending_pkg_changes = get_pending_pkg_changes('upgrade');

    if(%pending_pkg_changes) {

        ssm_print "Not OK:  Package upgrades\n";
        ssm_print "\n";
        ssm_print "         Need to:\n";

        my $max_length = 0;
        foreach my $pkg (sort keys %pending_pkg_changes) {

            ssm_print "$debug_prefix PKG $pkg\n" if($o::{debug});

            my $length = length $pending_pkg_changes{$pkg};
            if($length > $max_length) {
                $max_length = $length;
            }
        }

        my @sort_list;
        foreach my $pkg (sort keys %pending_pkg_changes) {

            my $action = lc( $pending_pkg_changes{$pkg}{action} );
            my $pad = get_pad($max_length - length($action));

            if(
                ($pending_pkg_changes{$pkg}{current_version} and $pending_pkg_changes{$pkg}{target_version}) and 
                ($pending_pkg_changes{$pkg}{current_version} ne  $pending_pkg_changes{$pkg}{target_version})
                ) {
                push @sort_list, "- ${action}${pad} $pkg  from  $pending_pkg_changes{$pkg}{current_version} to $pending_pkg_changes{$pkg}{target_version}";
            } else {
                push @sort_list, "- ${action}${pad} $pkg";
            }
        }

        foreach my $line (sort @sort_list) {
            ssm_print "         $line\n";
        }

        take_pkg_action('upgrade_pkgs', (keys %pending_pkg_changes) );

    } else {
        ssm_print "OK:      Package upgrades\n";
    }

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }

    return 1;
}


sub install_packages_interactive {

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    # Only do pkg stuff on later passes
    return 1 if( $::PASS_NUMBER == 1 );

    my %pending_pkg_changes = get_pending_pkg_changes('install');

    if(%pending_pkg_changes) {

        ssm_print "Not OK:  Package installs\n";
        ssm_print "\n";
        ssm_print "         Need to:\n";

        my $max_length = 0;
        foreach my $pkg (sort keys %pending_pkg_changes) {
            my $length = length $pending_pkg_changes{$pkg};
            if($length > $max_length) {
                $max_length = $length;
            }
        }

        my @installs;
        my @sort_list;
        foreach my $pkg (sort keys %pending_pkg_changes) {

            my $action = lc( $pending_pkg_changes{$pkg}{action} );
            my $pad = get_pad($max_length - length($action));

            push @sort_list, "- ${action}${pad} $pkg";

            if($action ne 'remove') {
                #
                # If it's not a remove, then it's either an upgrade or an
                # install, and we handle them both the same way. 
                #
                push @installs, $pkg;
                #
                # So why do we ignore 'remove' entries?  It's because the
                # package managers handle that atomically when the install of
                # one package requires the removal of another.  In other words,
                # doing the 'install' will automatically result in the 'remove'
                # of the other packages. -BEF-
                #
            }
        }

        foreach my $line (sort @sort_list) {
            ssm_print "         $line\n";
        }

        take_pkg_action('install_pkgs', @installs );

    } else {
        ssm_print "OK:      Package installs\n";
    }

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }

    return 1;
}


sub update_package_repository_info_interactive {

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    # Only do pkg stuff on later passes
    if( $::PASS_NUMBER == 1 ) { return 1; }

    if( $::o{summary} ) { $::o{pkg_repo_update} = 'no'; }

    my $return_code;
    if( $::o{pkg_repo_update} eq 'no' ) {

        ssm_print "INFO:    Package repo update -> skipping\n";
        return 1;
    }
    elsif( $::o{pkg_repo_update} eq 'auto' ) {

        my $timestamp = get_pkg_repo_update_time_stamp();
        
        #
        # Need to find proper method for determining Yum repo update time.  Until then, the Yum.pm function returns undef,
        # so we fall back to the SSM timestamp method here.
        if( ! $timestamp and -e $PKG_REPO_UPDATE_TIMESTAMP_FILE ) {
            $timestamp = get_file_timestamp( $PKG_REPO_UPDATE_TIMESTAMP_FILE );
        }

        if( $timestamp ) {
            my $current_time = time();
            my $window_in_seconds = $::o{pkg_repo_update_window} * 60 * 60;     # hours * minutes * seconds
            my $age_of_timestamp = $current_time - $timestamp;

            if( $age_of_timestamp < $window_in_seconds ) {
                ssm_print "INFO:    Package repo update -> skipping (updated in the last $::o{pkg_repo_update_window} hours)\n";
                return 1;
            }
        }
    }

    ssm_print "INFO:    Package repo update -> updating\n";

    $return_code = update_pkg_availability_data();

    unless( -e $STATE_DIR ) {

        my $path = $STATE_DIR;

        if($::o{debug}) { ssm_print qq/$debug_prefix make_path "$path", { verbose => 0, mode => 0775, }) \n/; } 
        eval { make_path("$path", { verbose => 0, mode => 0775, }) };
        if($@) { ssm_print "Couldn’t create $path: $@"; }
    }

    touch $PKG_REPO_UPDATE_TIMESTAMP_FILE;

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }

    return $return_code;
}


# See http://www.webmasterworld.com/forum13/1012.htm for details. -BEF-
sub multisort {
    my ($a1, $a2, $a3) = split(/\s+/, $a);
    my ($b1, $b2, $b3) = split(/\s+/, $b);

    # Stringwise compare field 2 (element name)
    # then numeric field 1 (priority)
    # then stringwise field 3 (bundle)
    $a2 cmp $b2
        ||
    $b1 <=> $a1
        ||
    $a3 cmp $b3
}


sub _specify_an_upload_url {
        ssm_print "INFO:  You don't have an upload_url specified in the definition.\n";
        ssm_print "       Please take a moment to add an entry to your [global] section.\n";
        ssm_print "\n";
        ssm_print "       Here's an example or two (I highly recommend an ssh URL):\n";
        ssm_print "\n";
        ssm_print "         upload_url = ssh://xcat-master/install/ssm_repo.hostname/\n";
        ssm_print "         upload_url = ssh://username\@xcat-master/install/ssm_repo.hostname/\n";
        ssm_print "         upload_url = file://install/ssm_repo.hostname/\n";
        ssm_print "\n";
}


#
#   Usage:  copy_file_to_upstream_repo($filename_on_system, $filename_in_repo);
#             Where: 
#               $filename_on_system => file on this system, can be a temp file, or of any name
#               $filename_in_repo   => the name of the file as it _should_ be in the repo
#
#   Example:  copy_file_to_upstream_repo("/tmp/mytmp_file.2931", "/etc/ssm/defaults/bf40cf4d09789b92acc43775c8ed43f5");
#
sub copy_file_to_upstream_repo {

    my $filename_on_system = shift;
    my $filename_in_repo  = shift;

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    ssm_print qq($debug_prefix copy local file "$filename_on_system" to file name "$filename_in_repo" in repo.\n) if($::o{debug});

    #
    # For URL's of type "ssh://"
    #
    if( $::o{upload_url} =~ m|^ssh://([^/]*)(/.*)| ) {
        #                             ^^^^^  ^^^ 
        #                               |     |---------- Match the path to the repository
        #                               |
        #                               |---------------- Match the repo_host ( host.example.com or bobby@host.example.com )
        #
        my $repo_host = $1;
        my $repo_dir  = $2;
        if($::o{debug}) { ssm_print "\$repo_host $repo_host\n"; }
        if($::o{debug}) { ssm_print "\$repo_dir $repo_dir\n"; }

        my $cmd;

        my $dir  = dirname($filename_in_repo);

        my $path = "$repo_dir/$dir";
        $path =~ s|/+|/|g;
        if($::o{debug}) { ssm_print "\$path $path\n"; }

        my $destination_file   = "$repo_dir/$filename_in_repo";
        $destination_file =~ s|/+|/|g;
        if($::o{debug}) { ssm_print "\$destination_file $destination_file\n"; }

        #
        # Make sure the dir exists
        #
        $cmd = qq(ssh $repo_host mkdir -p -m 775 $path);
        if($::o{debug}) { ssm_print qq(\n\$cmd: $cmd\n); }
        !system($cmd) or die("Couldn't run $cmd\n");
        $repo_access_verified = 'yes';

        #
        # Copy up the contents
        #
        $cmd = qq(scp $filename_on_system $repo_host:$destination_file >/dev/null);
        if($::o{debug}) { ssm_print qq(\n\$cmd: $cmd\n); }
        !system($cmd) or die("Couldn't run $cmd\n");

        #
        # Chmod to ensure client style access to repos
        #
        $cmd = qq(ssh $repo_host chmod 644 $destination_file);
        !system($cmd) or die("Couldn't run $cmd\n");

    }
    #
    # For URL's of type "file://"
    #
    elsif( $::o{upload_url} =~ m|^file://(/.*)| ) {

        my $repo_dir = $1;

        #
        # Make sure the dir exists
        #
        my $dir  = dirname($filename_in_repo);
        umask 000;
        my $path = "$repo_dir/$dir";
        $path =~ s|/+|/|g;
        if($::o{debug}) { ssm_print qq/$debug_prefix make_path "$path", { verbose => 0, mode => 0775, }) \n/; } 
        eval { make_path("$path", { verbose => 0, mode => 0775, }) };
        if($@) { ssm_print "Couldn’t create $path: $@"; }

        #
        # Copy up the contents
        #
        my $destination_file   = "$repo_dir/$filename_in_repo";
        $destination_file =~ s|/+|/|g;
        if($::o{debug}) { ssm_print qq($debug_prefix copy $filename_on_system, $destination_file \n); }
        copy($filename_on_system, $destination_file) or die "Failed to copy($filename_on_system, $destination_file): $!";
        chmod oct(644), $destination_file;

    }
    elsif( $::o{upload_url} =~ m|^([^/]+)://| ) {
        my $unknown_protocol = $1;
        ssm_print "If you'd like $unknown_protocol to be supported, please let me know.\n";
        ssm_print '  - Brian Elliott Finley <brian@thefinleys.com>' . "\n";
    }

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }

    return 1;
}


#
#   Takes a filename as specified by user, and turns into a fully qualified
#   filename (if it's not already), preserving the user's vantage point with
#   regard to symbolic links, etc.
#
#       If the user specifies the filename as     "../bar/baz",
#       while sitting in                        "/opt/boo/",
#       then it returns                         "/opt/bar/baz",
#       even if "/opt" is a symlink pointing to "/foo", which would result in 
#       a true absolute path of                 "/foo/bar/baz".
#
sub fully_qualified_file_name {

    my $name = shift;

    if( ! -e $name ) {
        return undef;
    }

    # Remember our initial working directory so we can return later
    my $working_dir = getcwd();

    my $file_name_relative_dir = dirname( $name );

    # cd into target dir, no matter how it was specified (ie., ../my/dir)
    chdir $file_name_relative_dir;
    my $fully_qualified_dir = getcwd();
    my $basename = basename($name);
    my $fully_qualified_file_name = "$fully_qualified_dir/$basename";

    # Change back to our initial working directory
    chdir $working_dir;

    return $fully_qualified_file_name;
}


sub assign_state_to_thingy {

    my $thingy = shift;
    my $state = shift;

    $::outstanding{$thingy} = $state;
    if($::o{debug}) {
        print qq(>>> assign_state_to_thingy(): "$thingy" => "$state"\n);
    }

    return 1;
}


sub declare_file_actions {
    
    my $name = shift;
    my $optional_notice = shift;
    my $etype = 'file';

    my $dir  = dirname($name);
    my $dir_will_be_removed;

    ssm_print "\n";
    ssm_print "         Need to:\n";

    if($CONF{$etype}{$name}{prescript}) {
        ssm_print "         - $CONF{$etype}{$name}{prescript}\n";
    }

    if(   -e $dir   and ! -d $dir  ) {
        ssm_print "         - remove file $dir\n";
    }

    if( $CONF{$etype}{$name}{type} ne 'directory'  and  $CONF{$etype}{$name}{type} ne 'directory+contents-unwanted') {

        if( -e $name  and  -d $name ) {
            ssm_print "         - remove directory $name\n";
            $dir_will_be_removed = 1;
        }

        if( ! -e $dir   or  ! -d $dir  ) {
            ssm_print "         - create directory $dir\n";
        }
    }

    if( $CONF{$etype}{$name}{type} eq 'chown+chmod'  and  ! -e $name ) {
        ssm_print "         - create empty file $name\n";
    }

    if( $optional_notice ) {
        ssm_print "         - $optional_notice\n";
    }

    if(
            ( ! defined $dir_will_be_removed    )
        and ( $CONF{$etype}{$name}{type} ne 'unwanted'        )
        and ( $CONF{$etype}{$name}{type} ne 'softlink'        )
        and ( -e $name                          )
        and ( ! uid_gid_and_mode_match($name)   )
      ) {

        ssm_print "         - set ownership and permissions\n";
        diff_ownership_and_permissions($name, 12);
    }

    if($CONF{$etype}{$name}{postscript}) {
        ssm_print "         - $CONF{$etype}{$name}{postscript}\n";
    }

    return 1;
}


#
#   Usage:
#       declare_OK_or_Not_OK($name, $is_OK);
#       or declare_OK_or_Not_OK($name, $is_OK, "custom append message");
#
#           - Where $is_OK can be 1 (for OK).  Anything else is treated as Not OK.
#
sub declare_OK_or_Not_OK {

    my $name            = shift;
    my $is_OK           = shift;
    my $append_message  = shift;
    my $etype = 'file';

    my $state;
    if("$is_OK" eq "1") {
        $state = "OK:      ";
    } else {
        $state = "Not OK:  ";
    }

    my $type = ucfirst($CONF{$etype}{$name}{type});
    if($CONF{$etype}{$name}{type} eq 'hardlink') {
        $type = 'Hard Link';
    }
    elsif($CONF{$etype}{$name}{type} eq 'softlink') {
        $type = 'Soft Link';
    }
    elsif($CONF{$etype}{$name}{type} eq 'block') {
        $type = 'Block (special file)';
    }
    elsif($CONF{$etype}{$name}{type} eq 'character') {
        $type = 'Character (special file)';
    }
    elsif($CONF{$etype}{$name}{type} eq 'chown+chmod') {
        $type = 'Chown+Chmod';
    }
    elsif($CONF{$etype}{$name}{type} eq 'directory+contents-unwanted') {
        $type = 'Directory (w/contents unwanted)';
    }
    elsif($CONF{$etype}{$name}{type} eq 'fifo') {
        $type = 'FIFO (special file)';
    }

    my $message = $state . $type . ": " . $name;

    if($CONF{$etype}{$name}{type} eq 'hardlink'  or  $CONF{$etype}{$name}{type} eq 'softlink') {
        $message .= " -> $CONF{$etype}{$name}{target}";
    }

    if($append_message) {
        $message .= " -> $append_message";
    }

    ssm_print $message . "\n";

    return 1;
}


sub rename_file {

    my $name = shift @{$::o{rename_file}};
    my $newfile = shift @ARGV;
    my $etype = 'file';

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    if($BUNDLEFILE{$newfile}) {
        #
        # Prevent people from accidentally running twice in a row and
        # accidentally turning their new file into an 'unwanted' file...
        #
        ssm_print qq(\n);
        ssm_print "WARNING: Rename target $newfile already has an entry in the configuration.\n";
        ssm_print "         Not renaming.\n";
        ssm_print qq(\n);
        $ERROR_LEVEL++;

        return ($ERROR_LEVEL, $CHANGES_MADE);
    }

    my $bundlefile = $BUNDLEFILE{$name};
    my $tmp_bundlefile;

    #
    #   Grab filespec info from existing file definition read in from the
    #   config file
    #
    my %filespec;
    $filespec{type}     = $CONF{$etype}{$name}{type};
    $filespec{name}     = $name;
    $filespec{owner}    = $CONF{$etype}{$name}{owner}     if($CONF{$etype}{$name}{owner});
    $filespec{group}    = $CONF{$etype}{$name}{group}     if($CONF{$etype}{$name}{group});
    $filespec{mode}     = $CONF{$etype}{$name}{mode}      if($CONF{$etype}{$name}{mode});
    $filespec{target}   = $CONF{$etype}{$name}{target}    if($CONF{$etype}{$name}{target});
    $filespec{major}    = $CONF{$etype}{$name}{major}     if($CONF{$etype}{$name}{major});
    $filespec{minor}    = $CONF{$etype}{$name}{minor}     if($CONF{$etype}{$name}{minor});
    $filespec{md5sum}   = $CONF{$etype}{$name}{md5sum}    if($CONF{$etype}{$name}{md5sum});

    #
    # 1) Get a copy of the existing file, if it's a regular file, then use the
    #    copy_file_to_upstream_repo function to plop it back in the repo, but
    #    with it's new name.  If it has no md5sum, then there's no file in the
    #    repo to copy to a new name. ;-)
    #
    if($filespec{md5sum}) {
        my $url = qq($::o{base_url}/$name/$CONF{$etype}{$name}{md5sum});
        my $tmp_file = get_file($url, 'warn');
        my $filename_in_repo = "$newfile/$filespec{md5sum}";
        copy_file_to_upstream_repo($tmp_file, $filename_in_repo);
    }

    #
    # 2) Add stanza based on existing filespec, but with new file name, using
    #    existing bundlefile.
    #
    $filespec{name} = $newfile;
    $BUNDLEFILE{$newfile} = $bundlefile;
    #
    $tmp_bundlefile = update_or_add_file_stanza_to_bundlefile( %filespec );
    copy_file_to_upstream_repo($tmp_bundlefile, $bundlefile);
    unlink $tmp_bundlefile;

    #
    # 3) Update filespec info stanza for old file name, but change to be
    #    'unwanted'
    #
    $filespec{name}     = $name;
    $filespec{type}     = 'unwanted';
    delete $filespec{owner};
    delete $filespec{group};
    delete $filespec{mode};
    delete $filespec{target};
    delete $filespec{major};
    delete $filespec{minor};
    delete $filespec{md5sum};
    #
    $tmp_bundlefile = update_or_add_file_stanza_to_bundlefile( %filespec );
    copy_file_to_upstream_repo($tmp_bundlefile, $bundlefile);
    unlink $tmp_bundlefile;

    $CHANGES_MADE++;

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }

    return ($ERROR_LEVEL, $CHANGES_MADE);
}


sub list_bundlefiles {

    foreach my $bundlefile (sort keys %BUNDLEFILE_LIST) {
        ssm_print "Bundle:  $bundlefile\n";
    }

    return ($ERROR_LEVEL, $CHANGES_MADE);
}


sub export_config {

    my $export_dir  = $::o{export_config};
    my $dir = $export_dir;

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    if( -e $dir and ! -d $dir ) {
        ssm_print "\n";
        ssm_print "ERROR:  EXPORT_DIR $dir exists, but is not a directory.\n";
        ssm_print "        Exiting with no action taken.\n";
        ssm_print "\n";

        $ERROR_LEVEL++;

        return ($ERROR_LEVEL, $CHANGES_MADE);
    }

    # foreach bundlefile in list of bundlefiles
    foreach my $bundlefile (sort keys %BUNDLEFILE_LIST) {

        #print "bundlefile $bundlefile\n";

        #
        #   1) open target bundlefile for writing, and add each element
        #
        my $name = "$dir/$bundlefile";
        my $path = dirname($name);

        # If path doesn't exist, create it here
        #
        #   We do this for every bundlefile, because bundlefiles can live in
        #   directories.  Technically, they can live on remote URLs also, so I
        #   suppose we need to add code to handle that also... XXX
        #
        #   Should we:
        #   a) Leave them as remote references, and not pull them down? (I
        #      kinda like this one best -BEF-)
        #   b) Pull the files down into EXPORT_DIR and give them a unique 
        #      local name?
        #
        eval { make_path($path) };
        if($@) { ssm_print "Couldn’t create $path: $@"; }

        open(FILE,">$name") or die("Couldn't open $name for writing");
            #   foreach $global_entry
            #       write entry to target bundlefile
            for my $global_entry (sort keys %{$::o}) {
                print "Global Entry $global_entry\n";
            }

            #   foreach $name in sorted list
            #       if type 'regular', copy file into EXPORT_DIR repo
            #       write file entry to target bundlefile

            #   foreach $package
            #       write entry to target bundlefile

        close(FILE);
    }

    $CHANGES_MADE++;

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }

    return ($ERROR_LEVEL, $CHANGES_MADE);
}


#
# Usage: report_conflicting_definitions($etype, $name, $priority, $bundlefile);
#
sub report_conflicting_definitions() {

                my $etype = shift;
                my $name = shift;
                my $priority = shift;
                my $bundlefile = shift;

                # error out;
                ssm_print_always "\n";
                ssm_print_always "ERROR: Multiple (conflicting) definitions for:\n";
                ssm_print_always "\n";
                ssm_print_always "  [$etype]\n";
                ssm_print_always "  name     = $name\n";
                ssm_print_always "  priority = $priority\n";
                ssm_print_always "  ...\n";
                ssm_print_always "\n";
                ssm_print_always "  This instance was found in $bundlefile\n";
                ssm_print_always "  The conflicting instance was found in $BUNDLEFILE{$name}\n";
                ssm_print_always "\n";
                ssm_print_always "  Exiting now with no changes made.  Please examine your\n";
                ssm_print_always "  configuration and eliminate all but one of the definitions for\n";
                ssm_print_always "  this file, or change the priority of one of the definitions.\n";
                ssm_print_always "\n";

                $ERROR_LEVEL++;
                if($::o{debug}) { ssm_print_always "ERROR_LEVEL: $ERROR_LEVEL\n"; }

                # We go ahead and exit here to be super conservative.
                ssm_print_always "\n";
                exit $ERROR_LEVEL;
}


#
################################################################################

1;
