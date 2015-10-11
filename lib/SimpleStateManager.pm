#  
#   Copyright (C) 2006-2015 Brian Elliott Finley
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
            );

use strict;
use File::Copy;
use File::Path;
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
use LWP::Simple;
use Mail::Send;
use Cwd 'abs_path';


################################################################################
#
#   This package provides the following functions:
#
#       % egrep '^sub ' lib/SimpleStateManager.pm | perl -p -e 's/^sub /#   /; s/ {//;' | sort
#
#   add_file_to_repo
#   add_file_to_repo_type_directory
#   add_file_to_repo_type_regular
#   add_file_to_repo_type_softlink
#   add_file_to_repo_type_nonRegular
#   add_new_files
#   autoremove_packages_interactive
#   backup
#   check_depends
#   check_depends_interactive
#   choose_bundlefile_for_file
#   choose_tmp_file
#   chown_and_chmod_interactive
#   close_log_file
#   compare_package_options
#   contents_unwanted_interactive
#   copy_file_to_upstream_repo
#   diff_file
#   diff_ownership_and_permissions
#   directory_interactive
#   do_you_want_me_to
#   email_log_file
#   execute_postscript
#   execute_prescript
#   generated_file_interactive
#   _get_arch
#   get_current_time_as_timestamp
#   get_file
#   get_file_timestamp
#   get_file_type
#   get_gid
#   get_hostname
#   get_md5sum
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
#   md5sum_match
#   multisort
#   please_specify_a_valid_pkg_manager
#   print_pad
#   read_config_file
#   regular_file_interactive
#   remove_file
#   remove_packages_interactive
#   report_improper_file_definition
#   report_improper_service_definition
#   rotate_log_file
#   run_cmd
#   set_ownership_and_permissions
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
#   update_or_add_file_stanza_to_bundlefile
#   update_bundle_file_comment_out_entry
#   update_package_repository_info_interactive
#   upgrade_packages_interactive
#   user_is_root
#   user_to_uid
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
my (
    %TYPE,    # regular, block, character, fifo, softlink, hardlink,
              # unwanted, directory+contents-unwanted, ignored, or generated.
              #
              # This is the only hash where _every_ file will have an 
              # entry.  Use it to get a list of filenames.
    %MODE,
    %OWNER,
    %GROUP,
    %MD5SUM,
    %MAJOR,
    %MINOR,
    %TARGET,      # target file or directory for a link
    %PRESCRIPT,   # script or command to be run before installing a file
    %POSTSCRIPT,  # script or command to be run after installing a file
    %DEPENDS,     # package and, or file dependencies
    %DETAILS,     # runlevel information for services
    %PRIORITY,    # priority level for files and/or packages
    %GENERATOR,   # script or command to run to generate a generated file
    %BUNDLEFILE,  # name of bundlefile where each file or package is defined
    %BUNDLEFILE_LIST,   # simple list of bundle files
    %TMPFILE,     # name of a temporary file associated with a file
);

my $OUTSTANDING_PACKAGES_TO_INSTALL   = 0;
my $OUTSTANDING_PACKAGES_TO_REMOVE    = 0;
my $OUTSTANDING_PACKAGES_TO_UPGRADE   = 0;

my $ERROR_LEVEL  = 0;
my $CHANGES_MADE = 0;
our $LOGFILE;
my $repo_access_verified = 0;

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
        %TYPE,
        %MODE,
        %OWNER,
        %GROUP,
        %MD5SUM,
        %MAJOR,
        %MINOR,
        %TARGET,
        %PRESCRIPT,
        %POSTSCRIPT,
        %DEPENDS,
        %DETAILS,
        %PRIORITY,
        %GENERATOR,
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


#
#   my $timestamp = get_file_timestamp($file);
#   (returns an epoch style timestamp)
#
sub get_file_timestamp {

    my $file = shift;
    
    if( ! -e $file ) {
        return undef;
    } else {
        return stat($file)->mtime;
    }
}


sub _initialize_log_file {

    my $log_file = "/var/log/" . basename($0);

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

                if( m/^pkg_manager\s+(.*)(\s|#|$)/ )                { $::o{pkg_manager} = lc($1); }
                if( m/^pkg_manager_autoremove\s+(.*)(\s|#|$)/ )     { $::o{pkg_manager_autoremove} = lc($1); }
                if( m/^base_ur[il]\s+(.*)(\s|#|$)/ )                { $::o{base_url} = $1; }
                if( m/^upload_url\s+(.*)(\s|#|$)/ )                 { $::o{upload_url} = $1; }
                if( m/^email_log_to\s+(.*)(\s|#|$)/ )               { $::o{email_log_to} = $1; }
                if( m/^log_file_perms\s+(.*)(\s|#|$)/ )             { $::o{log_file_perms} = $1; }
                if( m/^remove_running_kernel\s+(.*)(\s|#|$)/ )      { $::o{remove_running_kernel} = $1; }
                if( m/^upgrade_ssm_before_sync\s+(.*)(\s|#|$)/ )    { $::o{upgrade_ssm_before_sync} = $1; }
                if( m/^pkg_repo_update\s+(.*)(\s|#|$)/ )            { $::o{pkg_repo_update} = $1; }
                if( m/^pkg_repo_update_window\s+(.*)(\s|#|$)/ )     { $::o{pkg_repo_update_window} = $1; }

                ###############################################################################
                #
                # BEGIN  deprecated, but leave in for warning messages, etc.
                #
                if( m/^git_ur[il]\s+(.*)(\s|#|$)/ )                 { $::o{git_url} = $1; }  
                if( m/^svn_ur[il]\s+(.*)(\s|#|$)/ )                 { $::o{svn_url} = $1; }  
                #
                # END  deprecated
                #
                ###############################################################################

                $_ = shift @input;
            }

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

            #
            # Make sure it's one we support
            #
            unless( ($::o{pkg_manager} eq 'dpkg'    )
                 or ($::o{pkg_manager} eq 'aptitude')
                 or ($::o{pkg_manager} eq 'apt-get' )
                 or ($::o{pkg_manager} eq 'yum'     )
                 or ($::o{pkg_manager} eq 'none'    )
            ) {

                please_specify_a_valid_pkg_manager();

            }

            if( ! defined $::o{remove_running_kernel} ) { 
                # Default to "no"
                $::o{remove_running_kernel} = 'no';
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

                # Match only the first entry on the line.  This allows 
                # for comments after an entry. -BEF-
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

            if( (defined $name) and (defined $DETAILS{$name}) ) {
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
                $DETAILS{$name} = $details if(defined $details);
                $DEPENDS{$name} = $depends if(defined $depends);
            }

            my $unsatisfied = check_depends($name);
            if($unsatisfied ne "1") {
                ssm_print "Not OK:  Service $name -> Unmet Dependencies";
                unless( $::o{summary} ) {
                    ssm_print ":\n";
                    ssm_print "         $unsatisfied";
                }
                ssm_print "\n";
                if($::o{debug}) { ssm_print "read_config_file(): before $name is $::outstanding{$name}\n"; }
                $::outstanding{$name} = 'b0rken';
                if($::o{debug}) { ssm_print "read_config_file(): after $name is $::outstanding{$name}\n"; }

                $ERROR_LEVEL++; if($::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }

            } else {

                if(defined $DETAILS{$name}) {
                    turn_service_into_file_entry($name);
                } else {
                    report_improper_service_definition($name);
                }
            }
        }

        # 
        # [files] sections
        #
        elsif( m/^\[file\]/ ) {

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
                    if( $value =~ m/^<<\s*(.*)\s*$/ ) {

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
            if( (defined $PRIORITY{$name}) and ($PRIORITY{$name} > $priority) ) {
                # do nothing;

            # If existing priority is equal to this file's priority
            } elsif( (defined $PRIORITY{$name}) and ($PRIORITY{$name} == $priority) ) {
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
                    $TYPE{$name}       = $type       if(defined $type);
                    $MODE{$name}       = $mode       if(defined $mode);
                    $OWNER{$name}      = $owner      if(defined $owner);
                    $GROUP{$name}      = $group      if(defined $group);
                    $MD5SUM{$name}     = $md5sum     if(defined $md5sum);
                    $MAJOR{$name}      = $major      if(defined $major);
                    $MINOR{$name}      = $minor      if(defined $minor);
                    $TARGET{$name}     = $target     if(defined $target);
                    $PRESCRIPT{$name}  = $prescript  if(defined $prescript);
                    $POSTSCRIPT{$name} = $postscript if(defined $postscript);
                    $DEPENDS{$name}    = $depends    if(defined $depends);
                    $PRIORITY{$name}   = $priority   if(defined $priority);
                    $GENERATOR{$name}  = $generator  if(defined $generator);
                    $BUNDLEFILE{$name} = $bundlefile if(defined $bundlefile);

                    # And we start with a status of unknown, later to be
                    # determined as broken or fixed as appropriate.
                    $::outstanding{$name} = 'unknown' unless(defined $::outstanding{$name}); 
                }
            }

            unless(defined $TYPE{$name}) {
                return report_improper_file_definition($name);
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

    #if( $::o{debug} ) { ssm_print "turn_usernames_into_uids()\n"; }

    foreach(keys %OWNER) {
        $OWNER{$_} = user_to_uid($OWNER{$_});
    }
    return 1;
}


sub turn_groupnames_into_gids {

    #if( $::o{debug} ) { ssm_print "turn_groupnames_into_gids()\n"; }

    foreach(keys %GROUP) {
        $GROUP{$_} = group_to_gid($GROUP{$_});
    }
    return 1;
}


sub user_to_uid {

    my $user = shift;

    #if( $::o{debug} ) { ssm_print "user_to_uid($user)\n"; }

    if($user =~ m/^\d+$/) {
        # it's already all-numeric; as in, a uid was specified in the definition
        return $user;
    } else {
        return (getpwnam $user)[2];
    }
}


sub group_to_gid {

    my $group = shift;

    #if( $::o{debug} ) { ssm_print "group_to_gid($group)\n"; }

    if($group =~ m/^\d+$/) {
        # it's already all-numeric; as in, a gid was specified in the definition
        return $group;
    } else {
        return (getgrnam $group)[2];
    }
}


sub sync_state {

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    $CHANGES_MADE = 0;

    unless($::o{only_files}) {

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
        elsif( $::o{pkg_manager} eq "none" ) {
            ssm_print "$debug_prefix require SimpleStateManager::None;\n" if($::o{debug});
            require SimpleStateManager::None;
            SimpleStateManager::None->import();
        }

        if( defined $::o{upgrade_ssm_before_sync} and $::o{upgrade_ssm_before_sync} eq "yes" ) {
            upgrade_ssm() unless($::o{no});
        }
    }

    #
    # Files
    my %only_this_file_hash;
    if( $::o{only_this_file} ) {

        my %specified_files_that_arent_defined;

        foreach my $file ( @{$::o{only_this_file}} ) {

            $file = normalized_file_name( $file ); 

            if($TYPE{$file}) {  # if type is specified, then it exists in the definition
                $only_this_file_hash{$file} = 1;
            } else {
                $specified_files_that_arent_defined{$file} = 1;
            }
        }

        if(%specified_files_that_arent_defined) {

            ssm_print_always "\n";
            ssm_print_always "ERROR:  The following files were specified with --only-this-file, but do\n";
            ssm_print_always "        not exist in the definition:\n";
            ssm_print_always "\n";
            foreach my $file (sort keys %specified_files_that_arent_defined) {
                ssm_print_always "          $file\n";
            }
            ssm_print_always "\n";

            exit 1;
        }
    }

    foreach my $file (sort keys %TYPE) {

        next if( $::o{only_this_file} and !defined($only_this_file_hash{$file}) );

        last if($::o{only_packages});

        # elsif( ($TYPE{$file} eq 'ignore') or ($TYPE{$file} eq 'ignored') ) {
        if( ($TYPE{$file} eq 'ignore') or ($TYPE{$file} eq 'ignored') ) {
            ignore_file_interactive($file);
        }
        elsif( $TYPE{$file} eq 'softlink' ) {
            softlink_interactive($file);
        }
        elsif( $TYPE{$file} eq 'hardlink' ) {
            hardlink_interactive($file);
        }
        elsif(     $TYPE{$file} eq 'block' 
                or $TYPE{$file} eq 'character'
                or $TYPE{$file} eq 'fifo'      ) {
            special_file_interactive($file);
        }
        elsif( $TYPE{$file} eq 'chown+chmod' ) {
            chown_and_chmod_interactive($file);
        }
        elsif( $TYPE{$file} eq 'regular' ) {
            regular_file_interactive($file);
        }
        elsif( $TYPE{$file} eq 'directory' ) {
            directory_interactive($file);
        }
        elsif( $TYPE{$file} eq 'unwanted' ) {
            unwanted_file_interactive($file);
        }
        elsif( $TYPE{$file} eq 'directory+contents-unwanted' ) {
            directory_interactive($file);
            contents_unwanted_interactive($file);
        }
        elsif( $TYPE{$file} eq 'generated' ) {
            generated_file_interactive($file);
        }
        else {
            return report_improper_file_definition($file);
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
            ssm_print "INFO:    Packages -> No [packages] defined in the configuration.\n";
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
    remove_file("$ou_path", 'silent');

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

    my $file = shift;

    my $check_depends_results = check_depends($file);

    if($check_depends_results eq "1") {
        return 1;
    } 
    else {

        ssm_print "Not OK:  File $file -> Unmet Dependencies";
        unless( $::o{summary} ) {
            ssm_print ":\n";
            ssm_print "         $check_depends_results";
            ssm_print "\n";
        }
        $::outstanding{$file} = 'unmet_deps';
        $ERROR_LEVEL++;
        if($::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }

        my $action = 'null';
        take_file_action( $file, $action, 'n#' ) unless($::o{yes});
            # There is no "yes" action to take, so just skip if --yes.

        return undef;
    }
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
    my $file = $log_file;
    my $subject = "SSM: " . get_hostname();

    $msg = Mail::Send->new;
    $msg = Mail::Send->new(Subject => $subject, To => $::o{email_log_to} );
    $fh = $msg->open;
    open(FILE,"<$file") or die("Couldn't open $file for reading!");
        while(<FILE>) {
            print $fh $_;
        }
    close(FILE);
    $fh->close;         # complete the message and send it

    return 1;
}


#sub get_pkgs_to_be_removed {
#
#    if( $::o{debug} ) { ssm_print "get_pkgs_to_be_removed()\n"; }
#
#    my %pkgs_currently_installed = get_pkgs_currently_installed();
#
#    my @array;
#    foreach my $pkg ( keys %pkgs_currently_installed ) {
#        if( ! defined($::PKGS_FROM_STATE_DEFINITION{$pkg}) or ($::PKGS_FROM_STATE_DEFINITION{$pkg} =~ m/\bunwanted\b/i )) {
#        ssm_print ">>> remove: $pkg\n" if( $::o{debug} );
#            push @array, $pkg;
#        }
#    }
#    
#    return @array;
#}


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
    my %hash;
    foreach my $pkg (keys %::PKGS_FROM_STATE_DEFINITION) {
        if(( ! $pkgs_currently_installed{$pkg} ) and ( $::PKGS_FROM_STATE_DEFINITION{$pkg} !~ m/\bunwanted\b/i )) {
            $hash{$pkg} = $::PKGS_FROM_STATE_DEFINITION{$pkg};
        }
    }

    return (keys %hash);
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
#          where $prompts is one or more of 'ynda'
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

    my $file = shift;

    # validate input
    unless( 
            defined($file)        and ($file        =~ m#^/#)
        and defined($TYPE{$file}) and ($TYPE{$file} =~ m#\S#)
    ) {
        return report_improper_file_definition($file);
    }

    $::outstanding{$file} = 'fixed';
    ssm_print "OK:      Ignoring $file\n";

    return 1;
}

sub softlink_interactive {
#XXX make it look more like hardlink -- see $needs_fixing
    # 
    # Accept either relative or absolute target, and implement as user
    # specifies.
    #

    my $file = shift;

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    #
    # validate input
    unless( 
            defined($file)          and ($file          =~ m#^/#)
        and defined($TARGET{$file})
        and defined($TYPE{$file})   and ($TYPE{$file}   =~ m#\S#)
    ) {
        return report_improper_file_definition($file);
    }

    #
    # Singularize double slashes in target names for beautification purposes
    $TARGET{$file} =~ s#/+#/#g;

    #
    # In case it's a relative path name, move to the directory where the link
    # will live before testing for target existence. -BEF-
    #
    my    $cwd     = getcwd();
    my    $dirname = dirname( $file );
    chdir $dirname;
    if( ! -e $TARGET{$file} ) {
        ssm_print "WARNING: Soft link $file -> $TARGET{$file} (target doesn't exist).\n";
        $ERROR_LEVEL++;  if($::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }
    }
    chdir $cwd;

    my $current_target = readlink($file);

    #
    # Possibilities are:
    #   - $file exists and $current_target is right
    #       - leave it alone
    #
    #   - $file doesn't exist
    #       - create link
    #
    #   - $file exists, $current_target is wrong
    #       - rm $file 
    #       - create link
    #
    #   - $file exists, $current_target is undef (Ie: $file is not a softlink)
    #       - rm $file 
    #       - create link
    #
    unless( (defined $current_target) and ($current_target eq $TARGET{$file}) ) {

        $::outstanding{$file} = 'b0rken';
        if( $::o{debug} ) { print ">>>  Assigning $file as 'b0rken'\n"; }

        ssm_print "Not OK:  Soft link $file -> $TARGET{$file}\n";

        unless( $::o{summary} ) {

            my $action = 'install_softlink';

            ssm_print "         Need to:\n";
            ssm_print "         - $PRESCRIPT{$file}\n" if($PRESCRIPT{$file});
            ssm_print "         - remove pre-existing file $file\n" if( -e $file );
            ssm_print "         - create soft link\n";
            ssm_print "         - $POSTSCRIPT{$file}\n" if($POSTSCRIPT{$file});

            #
            # Decide what to do about it -- if anything
            #
            take_file_action( $file, $action, 'yn#' );
        }

    } else {

        $::outstanding{$file} = 'fixed';
        ssm_print "OK:      Soft link $file -> $TARGET{$file}\n";
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

    my $file     = shift;

    if($::o{debug}) { ssm_print "install_hardlink($file)\n"; }

    ssm_print "         FIXING:  Hard link $file -> $TARGET{$file}\n";

    my $calling_function = (caller(1))[3];
    execute_prescript($file) if( $calling_function eq 'SimpleStateManager::take_file_action' );
    remove_file($file);
    link($TARGET{$file}, $file) or die "Couldn't link($TARGET{$file}, $file) $!";
    execute_postscript($file) if( $calling_function eq 'SimpleStateManager::take_file_action' );
    
    return 1;

}


sub install_softlink {

    my $file     = shift;

    if($::o{debug}) { ssm_print "install_softlink($file)\n"; }

    ssm_print "         FIXING:  Soft link $file -> $TARGET{$file}\n";

    my $calling_function = (caller(1))[3];
    execute_prescript($file) if( $calling_function eq 'SimpleStateManager::take_file_action' );
    remove_file($file,'silent');
    symlink($TARGET{$file}, $file) or die "Couldn't symlink($TARGET{$file}, $file) $!";
    execute_postscript($file) if( $calling_function eq 'SimpleStateManager::take_file_action' );
    
    return 1;
}


sub install_special_file {

    my $file = shift;

    if($::o{debug}) { ssm_print "install_special_file($file)\n"; }

    ssm_print qq(         FIXING:  Creating ) . ucfirst($TYPE{$file}) . qq( file $file\n);

    my $calling_function = (caller(1))[3];
    execute_prescript($file) if( $calling_function eq 'SimpleStateManager::take_file_action' );
    remove_file($file);

    if($TYPE{$file} eq 'fifo') {
        umask 0000;
        mkfifo($file, oct($MODE{$file})) or die "Couldn't mkfifo($file, $MODE{$file})$!";
    }
    elsif($TYPE{$file} eq 'character') {
        #
        # Thanks to Jim Pirzyk, author of Unix::Mknod, for getting back to
        # me with a documentation fix that allows me to use his code here.
        # -BEF- 2006.05.08
        #
        my $mode = oct($MODE{$file});
        mknod( $file, S_IFCHR|$mode, makedev($MAJOR{$file}, $MINOR{$file}) );
    }
    elsif($TYPE{$file} eq 'block') {
        my $mode = oct($MODE{$file});
        mknod( $file, S_IFBLK|$mode, makedev($MAJOR{$file}, $MINOR{$file}) );
    }

    set_ownership_and_permissions($file);
    execute_postscript($file) if( $calling_function eq 'SimpleStateManager::take_file_action' );

    return 1;
}


sub special_file_interactive {

    my $file   = shift;

    #
    # validate input
    if( 
           !defined($file)          or ($file !~ m/\S/)
        or !defined($TYPE{$file})   or ($TYPE{$file} !~ m/\S/)
        or !defined($MODE{$file})   or ($MODE{$file} !~ m/^\d+$/)
        or !defined($OWNER{$file})  or ($OWNER{$file} !~ m/\S/)
        or !defined($GROUP{$file})  or ($GROUP{$file} !~ m/\S/)
        or (
                (($TYPE{$file} eq 'character') or ($TYPE{$file} eq 'block')) 
                and 
                (
                       !defined($MAJOR{$file}) or ($MAJOR{$file} !~ m/^\d+$/)
                    or !defined($MINOR{$file}) or ($MINOR{$file} !~ m/^\d+$/)
                )
           )
    ) {
        return report_improper_file_definition($file);
    }

    if( ! check_depends_interactive($file) ) { return 1; }   # just return now if failed deps check

    #
    # Does it need fixing?
    my $needs_fixing = undef;
    if( ! -e $file ) {
        $needs_fixing = 1;
    } 
    else {

        my $st = lstat($file);

        if( ! uid_gid_and_mode_match($file) ) {
            $needs_fixing = 1;
        } 
        elsif( ($TYPE{$file} eq 'fifo') and (! S_ISFIFO($st_mode)) ) {
            $needs_fixing = 1;
        }
        elsif( ($TYPE{$file} eq 'block') and (! S_ISBLK($st_mode)) ) {
            $needs_fixing = 1;
        }
        elsif( ($TYPE{$file} eq 'character') and (! S_ISCHR($st_mode)) ) {
            $needs_fixing = 1;
        }
        elsif( ($TYPE{$file} eq 'character') or ($TYPE{$file} eq 'block') ) {
            if( $MAJOR{$file} ne major($st->rdev) ) {
                $needs_fixing = 1;
            }
            elsif ($MINOR{$file} ne minor($st->rdev) ) {
                $needs_fixing = 1;
            }
        }
    }

    #
    # Should we actually fix it?
    my $fix_it = undef;
    if( defined($needs_fixing) ) {

        $::outstanding{$file} = 'b0rken';

        ssm_print "Not OK:  " . ucfirst($TYPE{$file}) . " file $file\n";
        unless( $::o{summary} ) {
            my $action = 'install_special_file';
            ssm_print "         Need to:\n";
            ssm_print "         - $PRESCRIPT{$file}\n" if($PRESCRIPT{$file});
            ssm_print "         - remove pre-existing file $file\n" if( -e $file );
            ssm_print "         - create $file as a $TYPE{$file} special file\n";
            ssm_print "         - $POSTSCRIPT{$file}\n" if($POSTSCRIPT{$file});

            #
            # Decide what to do about it -- if anything
            #
            take_file_action( $file, $action, 'yn#' );
        }

    } else {

        $::outstanding{$file} = 'fixed';
        ssm_print "OK:      " . ucfirst($TYPE{$file}) . " file $file\n";
    }

    return 1;
}


# Usage:
#   diff_ownership_and_permissions($file, $number_of_desired_leading_spaces);
sub diff_ownership_and_permissions {

    my $file = shift;
    my $spaces = shift;

    my $st = stat($file);

    my $mode  = sprintf "%04o", $st_mode & 07777;

    my ($i, $m, $u, $g);

    ($m, $u, $g) = ($mode, (getpwuid $st_uid)[0], (getgrgid $st_gid)[0]);
    $i = 0; until ($i eq $spaces) { $i++ ; ssm_print " "; }
    ssm_print "from:  $m - $u:$g\n";

    ($m, $u, $g) = ($MODE{$file}, (getpwuid $OWNER{$file})[0], (getgrgid $GROUP{$file})[0]);
    $i = 0; until ($i eq $spaces) { $i++ ; ssm_print " "; }
    ssm_print "to:    $m - $u:$g\n";

    return 1;
}

sub get_md5sum {

    my $file = shift;

    my $md5sum;
    open(FILE, "<$file") or die "Can’t open ’$file’ for reading: $!";
        binmode(FILE);
        $md5sum = Digest::MD5->new->addfile(*FILE)->hexdigest;
    close(FILE);

    return $md5sum;
}

sub get_gid {
    
    my $file = shift;

    my $st = stat($file);
    my $gid = (getgrgid $st_gid)[0];
    
    return $gid;
}

sub get_major {
    
    my $file = shift;

    my $st = lstat($file);
    my $major = major($st->rdev);
    
    return $major;
}

sub get_minor {
    
    my $file = shift;

    my $st = lstat($file);
    my $minor = minor($st->rdev);
    
    return $minor;
}

sub get_uid {
    
    my $file = shift;

    my $st = lstat($file);
    my $uid = (getpwuid $st_uid)[0];
    
    return $uid;
}

sub get_mode {
    
    my $file = shift;

    my $st = lstat($file);
    my $mode  = sprintf "%04o", $st_mode & 07777;

    return $mode;
}


#
# Usage:  touch($file);
#
sub touch {

    my $file = shift;

    if( ! -e $file ) {
        # Ain't there -- create an empty file.  Use append just in case...
        open(FILE,">>$file") or die("Couldn't open $file for writing");
        close(FILE);
    } 

    my $mtime = time;
    my $atime = $mtime;
    utime $atime, $mtime, $file;

    return 1;
}


sub set_ownership_and_permissions {

    my $file = shift;

    ssm_print "         FIXING:  Ownership and Perms: $file\n";

    touch($file);

    chown $OWNER{$file}, $GROUP{$file}, $file;
    chmod oct($MODE{$file}), $file;

    return 1;
}


sub contents_unwanted_interactive {

    ssm_print ">> contents_unwanted_interactive()\n" if( $::o{debug} );

    my $dir   = shift;

    $::outstanding{$dir} = 'fixed';

    #
    # validate input
    if(    !defined($dir)        or ($dir        !~ m#^/#)
        or !defined($TYPE{$dir}) or ($TYPE{$dir} !~ m/\S/)
      ) {
        return report_improper_file_definition($dir);
    }

    if( ! -e $dir ) {
        #ssm_print "Not OK: Contents-unwanted directory $dir doesn't exist\n";
        $::outstanding{$dir} = 'does not exist';
        return 1;
    }
    elsif( ! -d $dir ) {
        #ssm_print "Not OK: Contents-unwanted directory $dir is not a directory\n";
        $::outstanding{$dir} = 'not a directory';
        return 1;
    }

    # state what we're doing
    # get list of files in directory
    my $file;
    my $info_message_has_been_displayed;
    opendir(DIR,"$dir") or die "Can't open $dir for reading";
        #
        # See if each file matches a defined file
        #   * test this to be sure that:
        #       If /etc/iptables.d/stuff/monkey is defined, make sure it is
        #       not removed, even if /etc/iptables.d/stuff is not explicitly
        #       defined.  It is implicitly defined.  Ie.: match on left hand
        #       side of string if necessary.
        #
        while (defined ($file = readdir DIR) ) {

            next if $file =~ /^\.\.?$/;

            # We got a hit!
            unless($info_message_has_been_displayed or $::o{summary}) {
                ssm_print "INFO:    Processing contents-unwanted directory $dir\n";
                $info_message_has_been_displayed = 'yes';
            }
            $file = "$dir/$file";
            ssm_print ">>> in_directory: $file\n" if( $::o{debug} );
            unless (defined $TYPE{$file}) {
                #
                # For each file that isn't defined:  unwanted_file_interactive($file);
                #
                $TYPE{$file} = 'unwanted';
                unwanted_file_interactive($file);
                if($::outstanding{$file} ne 'fixed') {
                    $::outstanding{$dir} = 'unwanted file(s) still exist(s)';
                }
            }
        }

    closedir(DIR);

    #
    # As per the top of this subroutine, $::outstanding{$dir} will be set
    # to 'fixed' unless we leave something unresolved in the middle of the
    # routine. -BEF-
    #
    if($::outstanding{$dir} eq 'fixed') {
        ssm_print "OK:      Contents-unwanted $dir\n";
    } else {
        ssm_print "Not OK:  Contents-unwanted $dir\n";
    }

    return 1;
}


sub unwanted_file_interactive {

    my $file   = shift;

    #
    # validate input
    if(    !defined($file)        or ($file        !~ m#^/#)
        or !defined($TYPE{$file}) or ($TYPE{$file} !~ m/\S/)
    ) {
        return report_improper_file_definition($file);
    }

    # don't do "check_depends_interactive" for an unwanted file...

    #
    # Does it need fixing?
    my $needs_fixing = undef;
    if( -e $file or -l $file ) {
        # It exists, and must be destroyed!!!
        $needs_fixing = 1;
    } 

    #
    # Should we actually fix it?
    if(defined($needs_fixing)) {

        $::outstanding{$file} = 'b0rken';
        if( $::o{debug} ) { print ">>>  Assigning $file as 'b0rken'\n"; }

        if( -d $file ) {
            ssm_print "Not OK:  Unwanted directory exists: $file\n";
        } else {
            ssm_print "Not OK:  Unwanted file exists: $file\n";
        }

        unless( $::o{summary} ) {
            my $action = 'remove_file';
            if( -d $file ) {
                ssm_print "         Need to:\n";
                ssm_print "         - $PRESCRIPT{$file}\n" if($PRESCRIPT{$file});
                ssm_print "         - remove the contents of $file\n";
                ssm_print "         - remove $file\n";
                ssm_print "         - $POSTSCRIPT{$file}\n" if($POSTSCRIPT{$file});
            } else {
                ssm_print "         Need to:\n";
                ssm_print "         - $PRESCRIPT{$file}\n" if($PRESCRIPT{$file});
                ssm_print "         - remove $file\n";
                ssm_print "         - $POSTSCRIPT{$file}\n" if($POSTSCRIPT{$file});
            }

            #
            # Decide what to do about it -- if anything
            #
            take_file_action( $file, $action, 'yn#' );
        }

    } else {

        $::outstanding{$file} = 'fixed';
        ssm_print "OK:      Unwanted $file doesn't exist\n";

    }

    return 1;

}


sub chown_and_chmod_interactive {

    my $file   = shift;

    #
    # validate input
    if(    !defined($file)         or ($file !~ m#^/#)
        or !defined($TYPE{$file})  or ($TYPE{$file} !~ m/\S/)
        or !defined($MODE{$file})  or ($MODE{$file} !~ m/^\d+$/)
        or !defined($OWNER{$file}) or ($OWNER{$file} !~ m/\S/)
        or !defined($GROUP{$file}) or ($GROUP{$file} !~ m/\S/)
    ) {
        return report_improper_file_definition($file);
    }

    if( ! check_depends_interactive($file) ) { return 1; }   # just return now if failed deps check

    #
    # Does it need fixing?
    my $needs_fixing = undef;
    if( ! -e $file ) {
        $needs_fixing = 1;
    }
    elsif( ! uid_gid_and_mode_match($file) ) {
        $needs_fixing = 1;
    } 

    #
    # Should we actually fix it?
    if( defined($needs_fixing) ) {

        $::outstanding{$file} = 'b0rken';
        if( $::o{debug} ) { print ">>>  Assigning $file as 'b0rken'\n"; }

        ssm_print "Not OK:  Chown+Chmod target $file\n";

        unless( $::o{summary} ) {
            my $action = 'set_ownership_and_permissions';
            if( ! -e $file ) {
                ssm_print "         Need to:\n";
                ssm_print "         - $PRESCRIPT{$file}\n" if($PRESCRIPT{$file});
                ssm_print "         - create empty file\n";
                ssm_print "         - set ownership and permissions\n";
                ssm_print "         - $POSTSCRIPT{$file}\n" if($POSTSCRIPT{$file});
            } else {
                ssm_print "         Need to:\n";
                ssm_print "         - $PRESCRIPT{$file}\n" if($PRESCRIPT{$file});
                ssm_print "         - set ownership and permissions\n";
                diff_ownership_and_permissions($file, 12);
                ssm_print "         - $POSTSCRIPT{$file}\n" if($POSTSCRIPT{$file});
            }

            #
            # Decide what to do about it -- if anything
            #
            take_file_action( $file, $action, 'yn#' );

        }

    } else {

        $::outstanding{$file} = 'fixed';
        ssm_print "OK:      Chown+Chmod target $file\n";

    }

    return 1;
}


sub directory_interactive {

    my $file   = shift;

    #
    # validate input
    if(    !defined($file)         or ($file !~ m#^/#)
        or !defined($TYPE{$file})  or ($TYPE{$file} !~ m/\S/)
        or !defined($MODE{$file})  or ($MODE{$file} !~ m/^\d+$/)
        or !defined($OWNER{$file}) or ($OWNER{$file} !~ m/\S/)
        or !defined($GROUP{$file}) or ($GROUP{$file} !~ m/\S/)
    ) {
        return report_improper_file_definition($file);
    }

    if( ! check_depends_interactive($file) ) { return 1; }   # just return now if failed deps check

    #
    # Does it need fixing?
    my $needs_fixing = undef;
    my $set_ownership_and_permissions = undef;
    if( ! -e $file ) {
        # Ain't there
        $needs_fixing = 1;
    } 
    elsif( ! -d $file ) {
        # It's not a directory
        $needs_fixing = 1;
    } 
    elsif( ! uid_gid_and_mode_match($file) ) {
        $needs_fixing = 1;
        $set_ownership_and_permissions = 1;
    } 

    #
    # Should we actually fix it?
    if( defined($needs_fixing) ) {

        $::outstanding{$file} = 'b0rken';
        if( $::o{debug} ) { print ">>>  Assigning $file as 'b0rken'\n"; }

        ssm_print "Not OK:  Directory $file\n";

        unless( $::o{summary} ) {
            
            my $action;

            ssm_print "         Need to:\n";
            if( defined($set_ownership_and_permissions) ) {

                $action = 'set_ownership_and_permissions';
                ssm_print "         - fix ownership and permissions\n";
                diff_ownership_and_permissions($file, 12);

            } else {

                $action = 'install_directory';
                ssm_print "         - $PRESCRIPT{$file}\n" if($PRESCRIPT{$file});
                ssm_print "         - create directory\n";
                ssm_print "         - $POSTSCRIPT{$file}\n" if($POSTSCRIPT{$file});

            }

            #
            # Decide what to do about it -- if anything
            #
            take_file_action( $file, $action, 'yn#' );
        }

    } else {
        $::outstanding{$file} = 'fixed';
        ssm_print "OK:      Directory $file\n";
    }

    return 1;
}


sub generated_file_interactive {

    my $file   = shift;

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    #
    # validate input
    if(    !defined($file)             or ($file             !~ m#^/#   )
        or !defined($TYPE{$file})      or ($TYPE{$file}      !~ m/\S/   )
        or !defined($MODE{$file})      or ($MODE{$file}      !~ m/^\d+$/)
        or !defined($OWNER{$file})     or ($OWNER{$file}     !~ m/\S/   )
        or !defined($GROUP{$file})     or ($GROUP{$file}     !~ m/\S/   )
        or !defined($GENERATOR{$file}) or ($GENERATOR{$file} !~ m/\S/   )
    ) {
        return report_improper_file_definition($file);
    }

    #
    # Take the generator and write it into an executable file
    my $generator_script = choose_tmp_file();
    open(FILE,">$generator_script") or die("Couldn't open $generator_script for writing.");
        print FILE $GENERATOR{$file};
    close(FILE);
    chmod oct(700), $generator_script;

    # Generate file and get it's md5sum -- now considered to be the 
    # appropriate md5sum for $file.
    $TMPFILE{$file} = choose_tmp_file();
    open(TMP, "+>$TMPFILE{$file}") or die "Couldn't open tmp file $!";

        if( $::o{debug} ) { print ">>>  The Generator(tm): $GENERATOR{$file}\n"; }

        open(INPUT,"$generator_script|") or die("Couldn't run $generator_script $!");
            print TMP (<INPUT>);
        close(INPUT);
        unlink $generator_script;

        seek(TMP, 0, 0);
        $MD5SUM{$file} = Digest::MD5->new->addfile(*TMP)->hexdigest;

    close(TMP);

    if( ! check_depends_interactive($file) ) { return 1; }   # just return now if failed deps check

    #
    # Does it need fixing?
    my $needs_fixing = undef;
    my $set_ownership_and_permissions = undef;
    if( ! -e $file ) {
        # Ain't there
        $needs_fixing = 1;
    } 
    elsif( ! -f $file ) {
        # It's not a generated file
        # for now I'm thinking a generated file _must_ be a regular
        # file -- as in, no special files. -BEF-
        $needs_fixing = 1;
    } 
    elsif( ! md5sum_match($file) ) {
        $needs_fixing = 1;
    }
    elsif( ! uid_gid_and_mode_match($file) ) {
        $needs_fixing = 1;
        $set_ownership_and_permissions = 1;
    } 

    #
    # Should we actually fix it?
    if( defined($needs_fixing) ) {

        $::outstanding{$file} = 'b0rken';
        if( $::o{debug} ) { print ">>>  Assigning $file as 'b0rken'\n"; }

        ssm_print "Not OK:  Generated file $file\n";

        unless( $::o{summary} ) {

            my $action;

            ssm_print "         Need to:\n";
            if( defined($set_ownership_and_permissions) ) {

                $action = 'set_ownership_and_permissions';
                ssm_print "         - fix ownership and permissions\n";
                diff_ownership_and_permissions($file, 12);

            } else {

                $action = 'install_file';
                ssm_print "         - $PRESCRIPT{$file}\n" if($PRESCRIPT{$file});
                ssm_print "         - generate file\n";
                if( -e $file and ! uid_gid_and_mode_match($file) ) {
                    # Also inform user about perms issue. -BEF-
                    ssm_print "         - fix ownership and permissions\n";
                    diff_ownership_and_permissions($file, 12);
                }
                ssm_print "         - $POSTSCRIPT{$file}\n" if($POSTSCRIPT{$file});

            }

            take_file_action( $file, $action, 'ynd#' );
        }

    } else {
        $::outstanding{$file} = 'fixed';
        if( $::o{debug} ) { print ">>>  Assigning $file as 'fixed'\n"; }
        ssm_print "OK:      Generated file $file\n";
    }

    unlink $TMPFILE{$file};

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }

    return 1;
}


sub regular_file_interactive {

    my $file   = shift;

    ssm_print ">> regular_file_interactive($file)\n" if( $::o{debug} );

    #
    # validate input
    if(    !defined($file)          or ($file          !~ m#^/#   )
        or !defined($TYPE{$file})   or ($TYPE{$file}   !~ m/\S/   )
        or !defined($MODE{$file})   or ($MODE{$file}   !~ m/^\d+$/)
        or !defined($OWNER{$file})  or ($OWNER{$file}  !~ m/\S/   )
        or !defined($GROUP{$file})  or ($GROUP{$file}  !~ m/\S/   )
        or !defined($MD5SUM{$file}) or ($MD5SUM{$file} !~ m/\S/   )
    ) {
        return report_improper_file_definition($file);
    }

    if( ! check_depends_interactive($file) ) { return 1; }   # just return now if failed deps check

    #
    # Does it need fixing?
    my $needs_fixing = undef;
    my $set_ownership_and_permissions = undef;
    if( ! -e $file ) {
        # Ain't there
        $needs_fixing = 1;
    } 
    elsif( ! -f $file ) {
        # It's not a regular file
        $needs_fixing = 1;
    } 
    elsif( ! md5sum_match($file) ) {
        $needs_fixing = 1;
    }
    elsif( ! uid_gid_and_mode_match($file) ) {
        $needs_fixing = 1;
        $set_ownership_and_permissions = 1;
    } 

    #
    # Should we actually fix it?
    if( defined($needs_fixing) ) {

        $::outstanding{$file} = 'b0rken';
        if( $::o{debug} ) { print ">>>  Assigning $file as 'b0rken'\n"; }

        ssm_print "Not OK:  Regular file $file\n";

        unless( $::o{summary} ) {

            my $action;

            ssm_print "         Need to:\n";
            if( defined($set_ownership_and_permissions) ) {

                $action = 'set_ownership_and_permissions';
                ssm_print "         - fix ownership and permissions:\n";
                diff_ownership_and_permissions($file, 12);

            } else {

                $action = 'install_file';
                ssm_print "         - $PRESCRIPT{$file}\n" if($PRESCRIPT{$file});
                ssm_print "         - copy version from repo\n";
                if( -e $file and ! uid_gid_and_mode_match($file) ) {
                    # Also inform user about perms issue. -BEF-
                    ssm_print "         - fix ownership and permissions\n";
                    diff_ownership_and_permissions($file, 12);
                }
                ssm_print "         - $POSTSCRIPT{$file}\n" if($POSTSCRIPT{$file});
            }

            #
            # Decide what to do about it -- if anything
            #
            take_file_action( $file, $action, 'ynda#' );
        }
            
    } else {
        $::outstanding{$file} = 'fixed';
        ssm_print "OK:      Regular file $file\n";
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
#   Usage:  $return_code = take_file_action( $file, $action );
#   Usage:  $return_code = take_file_action( $file, $action, [$prompts,] [$msg] );
#
#       Where $prompts is one or more of 'ynda'.  Order doesn't matter:
#       - y - yes
#       - n - no
#       - d - diff
#       - a - add
#       - # - comment out
#
sub take_file_action {

    my $timer_start; my $debug_prefix; if( $main::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    #
    # test for --yes and --no and --summary right here. Hmm...
    #
    my $file    = shift;
    my $action  = shift;
    my $prompts = shift;
    my $msg     = shift;

    my $return_code = 0;

    #
    # First pass is observation only.
    #
    if( $main::PASS_NUMBER == 1 ) { 

        ssm_print ">>> Skipping action as this is the first PASS\n\n";
        $return_code = 1; 
    }

    if($main::o{debug}) { 
        ssm_print "$debug_prefix ( $file, $action"; 
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

            my $unsatisfied = check_depends($file);
            if($unsatisfied ne "1") {
                #
                # $prompts should be limited to N and # if depends are not met, so we
                # strip out all prompt characters except for "n" for no, and "#" for
                # comment out. -BEF-
                #
                $prompts =~ s/[^n#]//g;
                ssm_print "\n";
                ssm_print "           NOTE: Options limited due to Unmet Dependencies\n";
            }

            $answer = do_you_want_me_to($prompts);
        }   

        if( $answer eq 'n' ) {
            $return_code = 1;

        } elsif( $answer eq 'd' ) {
            diff_file($file);
            $return_code = 2;  # we did our diff, but don't want to exit the higher level loop yet

        } elsif( $answer eq 'a' ) {
            $return_code = add_file_to_repo($file);
            $::outstanding{$file} = 'fixed';
            $CHANGES_MADE++;

        } elsif( $answer eq '#' ) {
            $return_code = update_bundle_file_comment_out_entry($file);
            $::outstanding{$file} = 'fixed';
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
                if($::o{debug}) { ssm_print "return_code = $actions{$action}($file);\n"; }
                $return_code = $actions{$action}($file);

                $::outstanding{$file} = 'fixed'; #XXX is it really?  verify return code
                $CHANGES_MADE++;

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

    my $file = shift;

    open(FILE, "<$file") or die "Can’t open ’$file’ for reading: $!";
        binmode(FILE);
        if( Digest::MD5->new->addfile(*FILE)->hexdigest eq $MD5SUM{$file} ) {
            return 1;
        }
    close(FILE);

    return undef;
}


sub diff_file {

    my $file     = shift;
    my $tmp_file = shift;

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    if( $::o{summary} ) {
        # Don't do diffs in --summary mode
        return 1;
    }

    ssm_print "         DIFFING:  $file\n";

    if($::o{debug}) { ssm_print "diff_file($file)\n"; }

    my $unlink = 'no';

    my $url;
    if( ! defined $tmp_file ) {
        if( defined $TMPFILE{$file} ) {
            # generated files will have one of these
            $tmp_file = $TMPFILE{$file};

        } else {
            $url = qq($::o{base_url}/$file/$MD5SUM{$file});
            $tmp_file = get_file($url, 'warn');
            $unlink = 'yes';
        }
    }

    if( ! defined $tmp_file ) {
        # Hmm.  get_file must have failed
        # Just drop the user back to their choices...
        return 1;
    }

    my $diff;
    if( $::o{no} or $::o{yes}) {
        # Never use colordiff if non-interactive
        foreach( "diff") {
            $diff = _which($_);
            last if( defined($diff) );
        }
    } else {
        foreach( "colordiff", "diff") {
            $diff = _which($_);
            last if( defined($diff) );
        }
    }

    ssm_print "\n";
    ssm_print "           <<<------------------------------------------------------>>>\n";
    ssm_print "           Here's a diff between the file on your system (left side) and the\n";
    ssm_print "           one in the repository (right side).\n";
    if( ! -e $file ) {
        print "\n";
        print "           $file does not yet exist, so diffing against /dev/null.\n";
        $file = '/dev/null';
    }
    ssm_print "           <<<------------------------------------------------------>>>\n\n";

    my $cmd = "$diff -y $file $tmp_file";

    run_cmd($cmd, undef, 1);

    ssm_print "\n";
    ssm_print "           ------------------------------------------------------------\n";
    ssm_print "            Currently on This Machine   <-- | -->   Repository Version\n";
    ssm_print "           ------------------------------------------------------------\n";
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

    my $file = shift;

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    if($PRESCRIPT{$file}) {
        my $cmd = $PRESCRIPT{$file};
        ssm_print qq(         RUNNING: $cmd\n);
        run_cmd($cmd);
    }

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }

    return 1;
}

sub execute_postscript {

    my $file = shift;

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    if($POSTSCRIPT{$file}) {
        my $cmd = $POSTSCRIPT{$file};
        ssm_print qq(         RUNNING: $cmd\n);
        run_cmd($cmd);
    }

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }

    return 1;
}


sub install_directory {

    my $file = shift;

    ssm_print "         FIXING:  Creating: $file\n";

    if($::o{debug}) { ssm_print "install_directory($file)\n"; }

    my $calling_function = (caller(1))[3];
    execute_prescript($file) if( $calling_function eq 'SimpleStateManager::take_file_action' );

    if(-e $file) { remove_file($file, 'silent'); }

    my $dir = $file;
    eval { mkpath($dir) };
    if($@) { ssm_print "Couldn’t create $dir: $@"; }

    set_ownership_and_permissions($file);

    execute_postscript($file) if( $calling_function eq 'SimpleStateManager::take_file_action' );

    return 1;
}


sub install_file {

    my $file     = shift;
    my $tmp_file = shift;

    if($::o{debug}) { ssm_print "install_file($file)\n"; }

    ssm_print "         FIXING:  Installing: $file\n";

    my $url;
    if( ! defined $tmp_file ) {

        #
        # Apparently we weren't passed a tmp file -- good, that's the recommended method.
        #

        # If we have a pre-defined tmp file associated with this file, then use it.
        if( defined $TMPFILE{$file} ) {

            $tmp_file = $TMPFILE{$file};

        } else {

            $url = qq($::o{base_url}/$file/$MD5SUM{$file});
            $tmp_file = get_file($url, 'warn');
        }
    }

    if( ! defined $tmp_file ) {
        # Hmm.  get_file must have failed
        # Just drop the user back to their choices...
        return 2;
    }

    my $calling_function = (caller(1))[3];
    execute_prescript($file) if( $calling_function eq 'SimpleStateManager::take_file_action' );
    backup($file);
    remove_file($file, 'silent');
    copy($tmp_file, $file) or die "Failed to copy($tmp_file, $file): $!";
    unlink $tmp_file;

    set_ownership_and_permissions($file);

    execute_postscript($file) if( $calling_function eq 'SimpleStateManager::take_file_action' );

    return 1;
}


#
# my $tmp_file = get_file($file, 'nowarn');
# my $tmp_file = get_file($file, 'warn');
# my $tmp_file = get_file($file, 'error');              # the default
# my $tmp_file = get_file($file, 'error', 'silent'); 
#
sub get_file {

    # copies $file, from wherever, to a temporary file name
    # returns that temporary file name

    my $file = shift;
    my $failure_behavior = shift;
    my $silent = shift;

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(1))[3] . ":" . (caller(1))[2] . "() " . (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    $failure_behavior = 'error' if( ! defined $failure_behavior );

    my $tmp_file = choose_tmp_file();

    # remove multiple slashes anywhere but after a protocol specifier
    $file =~ s#([^:/])/+#$1/#g;

    if( ($file =~ m#^file://#) or ($file =~ m#^/#) ) {

        $file =~ s#file://#/#;
        $file =~ s/(\s+|#).*//;
        if( ! -e $file ) {
            if( $failure_behavior eq 'error' ) {
                ssm_print_always "ERROR: $file doesn't exist...\n\n" unless($silent);
                exit 1;
            } else {
                ssm_print "WARNING: $file doesn't exist...\n" unless($silent);
                return undef;
            }
        } else {
            copy($file, $tmp_file) or die "$debug_prefix Failed to copy($file, $tmp_file): $!";
        }

    } elsif(    ($file =~ m#^http://# ) 
             or ($file =~ m#^https://#) 
             or ($file =~ m#^ftp://#  ) 
           ) {

        my $cmd = "wget -q $file -O $tmp_file";
        if($::o{debug}) { ssm_print "$cmd\n"; }
        unless( !system($cmd) ) {
            #
            # !system() should produce a positive result on success.  If we get
            # here, we know it failed.
            #
            if( $failure_behavior eq 'error' ) {
                ssm_print_always "ERROR: $file doesn't exist...\n\n";
                exit 1;
            } else {
                ssm_print "WARNING: $file doesn't exist...\n";
                $ERROR_LEVEL++;  if($::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }
                return undef;
            }
        }

    } else {

        ssm_print_always "\n";
        ssm_print_always "  I don't know how to acquire a file using the specified protocol:\n";
        ssm_print_always "  $file\n";
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
#
sub choose_tmp_file {

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(1))[3] . ":" . (caller(1))[2] . "() " . (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my $count = 0;
    my $file = "/tmp/system-state-manager_tmp_file";

    while( -e "$file.$count" ) {
        $count++;
    }
    $file = "$file.$count";

    umask 0077;
    open(FILE,">$file") or die "Couldn't open $file for writing";
        print FILE "I am a little tmp file created by System State Manager.\n";
    close(FILE);

    ssm_print "$debug_prefix FILE $file\n" if( $::o{debug} );
    
    return $file;
}


sub hardlink_interactive {

    my $file   = shift;

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    #
    # validate input
    unless( 
                defined($file)          and ($file          =~ m#^/#)
            and defined($TARGET{$file}) and ($TARGET{$file} =~ m#^/#)
            and defined($TYPE{$file})   and ($TYPE{$file}   =~ m/\S/)
    ) {
        return report_improper_file_definition($file);
    }

    if( ! check_depends_interactive($file) ) { return 1; }   # just return now if failed deps check

    #
    # Does it need fixing?
    my $needs_fixing = undef;
    if( ! -e $TARGET{$file} ) {

        # Target ain't there
        ssm_print "WARNING: Hard link $file -> $TARGET{$file} (target doesn't exist).\n";
        ssm_print "WARNING: Hard link $file -> Skipping this step.\n";
        $ERROR_LEVEL++;  if($::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }

        return 1;
    } 
    elsif( ! -e $file ) {
        # Ain't there
        $needs_fixing = 1;
    } 
    elsif( -l $file ) {
        # It's a softlink
        $needs_fixing = 1;
    } 
    else {
        #
        # See if link's inode is the same as target's inode
        my $st;

        $st = stat($file);
        my $file_inode = $st_ino;

        $st = stat($TARGET{$file});
        my $target_inode = $st_ino;

        if($file_inode != $target_inode) {
            $needs_fixing = 1;
        }
    }

    #
    # Should we actually fix it?
    if( defined($needs_fixing) ) {

        $::outstanding{$file} = 'b0rken';
        if( $::o{debug} ) { print ">>>  Assigning $file as 'b0rken'\n"; }

        ssm_print "Not OK:  Hard link $file -> $TARGET{$file}\n";

        unless( $::o{summary} ) {

            my $action = 'install_hardlink';

            ssm_print "         Need to:\n";
            ssm_print "         - $PRESCRIPT{$file}\n" if($PRESCRIPT{$file});
            ssm_print "         - remove pre-existing file $file\n" if( -e $file );
            ssm_print "         - create hard link\n";
            ssm_print "         - $POSTSCRIPT{$file}\n" if($POSTSCRIPT{$file});

            take_file_action( $file, $action, 'yn#' );
        }

    } else {

        $::outstanding{$file} = 'fixed';
        ssm_print "OK:      Hard link $file -> $TARGET{$file}\n";
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
    
    my ($package, $filename, $line) = caller;
    ssm_print "\n";
    ssm_print "Improper [service] definition (called from line $line of $filename)\n";
    ssm_print "\n";
    ssm_print "Here's what I know about it:\n";
    ssm_print "\n";
    ssm_print "  name   = $name\n";

    if(defined($DETAILS{$name})) { ssm_print "  mode   = $DETAILS{$name}\n";
                          } else { ssm_print "  mode   =\n"; }

    if(defined($DEPENDS{$name})) { ssm_print "  depends   = $DEPENDS{$name}\n";
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

    my $file = shift;

    my ($package, $filename, $line) = caller;
    ssm_print "\n";
    ssm_print "Improper [file] definition (called from line $line of $filename)\n";
    ssm_print "\n";
    ssm_print "Here's what I know about it:\n";

    if(defined($file)) { ssm_print "  name   = $file\n";
                } else { ssm_print "  name   =\n"; }

    if(defined($TYPE{$file})) { ssm_print "  type   = $TYPE{$file}\n";
                       } else { ssm_print "  type   =\n"; }

    if(defined($TARGET{$file})) { ssm_print "  target = $TARGET{$file}\n";
                         } else { ssm_print "  target =\n"; }

    if(defined($MODE{$file})) { ssm_print "  mode   = $MODE{$file}\n";
                       } else { ssm_print "  mode   =\n"; }

    if(defined($OWNER{$file})) { ssm_print "  owner  = $OWNER{$file}\n";
                        } else { ssm_print "  owner  =\n"; }

    if(defined($GROUP{$file})) { ssm_print "  group  = $GROUP{$file}\n";
                        } else { ssm_print "  group  =\n"; }

    if(defined($MAJOR{$file})) { ssm_print "  major  = $MAJOR{$file}\n";
                        } else { ssm_print "  major  =\n"; }

    if(defined($MINOR{$file})) { ssm_print "  minor  = $MINOR{$file}\n";
                        } else { ssm_print "  minor  =\n"; }

    if(defined($MD5SUM{$file})) { ssm_print "  md5sum = $MD5SUM{$file}\n";
                         } else { ssm_print "  md5sum =\n"; }

    if(defined($PRESCRIPT{$file})) { ssm_print "  prescript = $PRESCRIPT{$file}\n";
                            } else { ssm_print "  prescript =\n"; }

    if(defined($POSTSCRIPT{$file})) { ssm_print "  postscript = $POSTSCRIPT{$file}\n";
                             } else { ssm_print "  postscript =\n"; }

    if(defined($DEPENDS{$file})) { ssm_print "  depends = $DEPENDS{$file}\n";
                          } else { ssm_print "  depends =\n"; }

    if(defined($GENERATOR{$file})) { ssm_print "  generator = $GENERATOR{$file}\n";
                            } else { ssm_print "  generator =\n"; }

    if( defined($TYPE{$file}) and ($TYPE{$file} eq 'softlink') ) { 
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
    
    my $file = shift;

    my $st = stat($file);

    my $mode  = sprintf "%04o", $st_mode & 07777;

    if(    (   $mode == $MODE{$file}  )
        and( $st_uid == $OWNER{$file} )
        and( $st_gid == $GROUP{$file} ) ) {

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

    my $file = shift;

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    if(! $::o{"upload_url"} ) {

        _specify_an_upload_url();

        $ERROR_LEVEL++;
        if($::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }
        ssm_print "\n";

        return 3;
    }

    my @newfile;

    my $url  = "$::o{base_url}/$BUNDLEFILE{$file}";
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
        if( m|^name\s*=\s*(\S.*)\s+$|  and  $1 eq $file ) {

            #
            # We've got a hit!  Rewind until we get to the beginning of the
            # stanza (the named file may occur anywhere in the stanza) -BEF-
            #
            until ($_ =~ m/^\[file\]/ ) {
                unshift @input, $_;
                $_ = pop @newfile;
            }

            ssm_print qq(Updating:  Commenting out entry for "$file" in config file "$BUNDLEFILE{$file}".\n);

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

    copy_file_to_upstream_repo($tmp_bundle_file, $BUNDLEFILE{$file});
    unlink $tmp_bundle_file;

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }

    return 1;
}


#
# Usage:
#   my $file = update_or_add_file_stanza_to_bundlefile( %filespec );
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

    my $timestamp = get_current_time_as_timestamp();
    my $hostname  = get_hostname();
    my $comment   = "From $hostname on $timestamp";

    my $name = $filespec{name};
    my $url  = "$::o{base_url}/$BUNDLEFILE{$name}";
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
            if( $name_entry eq $name ) {

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

                    # Allow "key = value" or "key=value" type definitions.
                       s#^name\s*=.*#name       = $name#;
                    s/^comment\s*=.*/comment    = $comment/             if(defined $comment);
                       s/^type\s*=.*/type       = $filespec{type}/      if(defined $filespec{type});
                      s/^owner\s*=.*/owner      = $filespec{owner}/     if(defined $filespec{owner});
                      s/^group\s*=.*/group      = $filespec{group}/     if(defined $filespec{group});
                       s/^mode\s*=.*/mode       = $filespec{mode}/      if(defined $filespec{mode});

                    #
                    # When we match the md5sum bit, comment out the prior entry,
                    # but keep it for posterity, then add the new entry too.
                    #
                    if( s/^(md5sum\s*=.*)/# $1/ ) {
                        $_ .=       "md5sum     = $filespec{md5sum}  # $timestamp\n" if(defined $filespec{md5sum});
                    };

                     s/^target\s*=.*/target     = $filespec{target}/    if(defined $filespec{target});
                      s/^major\s*=.*/major      = $filespec{major}/     if(defined $filespec{major});
                      s/^minor\s*=.*/minor      = $filespec{minor}/     if(defined $filespec{minor});

                    push @newfile, $_;

                    $_ = shift @input;
                }
            }
        }

        push @newfile, $_;
    }

    if( $found_entry eq 'yes' ) {

        ssm_print qq(Updating:  Entry for "$name" in configuration file "$BUNDLEFILE{$name}" as type $filespec{type}.\n);

    } else {

        ssm_print qq(Adding:  Entry for "$name" in configuration file "$BUNDLEFILE{$name}" as type $filespec{type}.\n);

        push @newfile,   "\n";
        push @newfile,   "[file]\n";
        push @newfile,   "name       = $name\n";
        push @newfile,   "comment    = $comment\n"                          if(defined $comment);
        push @newfile,   "type       = $filespec{type}\n"                   if(defined $filespec{type});
        push @newfile,   "owner      = $filespec{owner}\n"                  if(defined $filespec{owner});
        push @newfile,   "group      = $filespec{group}\n"                  if(defined $filespec{group});
        push @newfile,   "mode       = $filespec{mode}\n"                   if(defined $filespec{mode});

        push @newfile,   "target     = $filespec{target}\n"                 if(defined $filespec{target});
        push @newfile,   "md5sum     = $filespec{md5sum}  # $timestamp\n"   if(defined $filespec{md5sum});
        push @newfile,   "major      = $filespec{major}\n"                  if(defined $filespec{major});
        push @newfile,   "minor      = $filespec{minor}\n"                  if(defined $filespec{minor});
        push @newfile,   "\n";

    }

    my $file = choose_tmp_file();
    open(FILE, ">$file") or die("Couldn't open $file for writing");
    print FILE @newfile;
    close(FILE);

    return $file;
}


#
# Usage:
#   my $file = add_bundlefile_stanza_to_bundlefile( $new_bundlefile );
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

    ssm_print qq(Adding:  The following bundles stanza to configuration file "$parent_bundlefile".\n);
    ssm_print "\n";
    foreach (@newstanza) {
        ssm_print qq(  $_);
    }
    
    # Append the new stanza to the existing bundle file
    my @newfile;
    push @newfile, @input;
    push @newfile, "\n";
    push @newfile, @newstanza;
    
    my $file;

    # Add comment to top of new bundlefile and drop it in repo
    $file = choose_tmp_file();
    open(FILE, ">$file") or die("Couldn't open $file for writing");
    print FILE qq(#\n);
    print FILE qq(# $comment\n);
    print FILE qq(#\n);
    close(FILE);
    copy_file_to_upstream_repo($file, $new_bundlefile);

    # Add entry to parent bundle file and copy up to repo
    $file = choose_tmp_file();
    open(FILE, ">$file") or die("Couldn't open $file for writing");
    print FILE @newfile;
    close(FILE);
    copy_file_to_upstream_repo($file, $parent_bundlefile);

    return 1;
}


#
# Usage:
#   my $file = add_package_stanza_to_bundlefile( @pkg_entries );
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

    my $file = choose_tmp_file();
    open(FILE, ">$file") or die("Couldn't open $file for writing");
    print FILE @newfile;
    close(FILE);

    return $file;
}


sub turn_service_into_file_entry {

    my $name = shift;

    my $dir = "/etc";

    my %details;
    foreach( split(/\s+/, $DETAILS{$name}) ) {
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
            my $file = "$dir/$subdir/$_";
            $TYPE{$file} = 'unwanted';
        }
        closedir(DIR);

        $subdir =~ m/rc(.)\.d/;
        my $level = $1;

        if(defined ($details{$level})) {
            my $prefix = $details{$level};
            my $file = "$dir/rc${level}.d/${prefix}${name}";
            $TYPE{$file} = 'softlink';
            $TARGET{$file} = "$dir/init.d/$name";
        }
    }

    return 1;
}


#
# Returns '1' if dependencies are satisfied
# Returns a list of unsatisfied dependencies if unsatisfied
#
sub check_depends {

    my $name = shift;
    if(! defined $TYPE{$name}) {
        ssm_print ">> name: $name\n" if( $::o{debug} );
        return 1;
    }

    my $unsatisfied;
    my %pkgs_currently_installed;

    unless( "$TYPE{$name}" eq 'directory' ) {
        # add file's directory as dependency
        my $dirname = dirname $name;
        $DEPENDS{$name} .= " $dirname";
    };

    #
    # No dependencies to check?  That's OK.  Return success.
    if(! defined $DEPENDS{$name}) { return 1; }

    # Singularize spaces
    $DEPENDS{$name} =~ s/^\s+//;

    if( $::o{debug} ) { print ">>> Dependencies for $name: $DEPENDS{$name}\n"; }
    
    #
    # Only check for pkgs if there's a pkg in the dependency list.  pkg
    # checking is an expensive process. -BEF-
    if($DEPENDS{$name} =~ m/(^|\s)\w/ ) {    # Match package names in the list
        %pkgs_currently_installed = get_pkgs_currently_installed();
    } 

    foreach( split(/\s+/, $DEPENDS{$name}) ) {
        if( /^\// ) {
            if( $::o{debug} ) { print ">>>> Checking on status of $_\n"; }
            #
            # Must be a file.  
            #
            my $file = $_;
            if( ! -e $file) {  
                # If it doesn't exist, fail dep check.
                $unsatisfied .= "$file "; 
                if( $::o{debug} ) { print ">>>>>  $_ doesn't exist\n"; }

            } elsif( defined $::outstanding{$file} and $::outstanding{$file} ne 'fixed') {

                if($file =~ m|^$name|) {
                    ssm_print "WARNING: You have $file specified as a dependency of $name, which is probably\n";
                    ssm_print "         not a good idea, seing as how $name is a directory that holds $file\n";
                    ssm_print "         and could form a non-resolving dependency.\n";
                    sleep 1;
                }

                $unsatisfied .= "$file "; 
                if( $::o{debug} ) { print ">>>>>  $_ exists, but isn't considered 'fixed'\n"; }

            } else {
                if( $::o{debug} ) { 
                    print ">>>>>  $_ exists, and isn't defined so it's mere existence makes it OK.\n"; 
                }
            }

        } else {
            #
            # Must be a package.  See if it's installed.
            my $pkg = $_;
            if( ! defined $pkgs_currently_installed{$pkg} ) { $unsatisfied .= "$pkg "; }
        }
    }

    if(defined $unsatisfied) { return $unsatisfied; }

    return 1;
}

#
# do we check for recursion loops?  Nah.  Not yet, anyway. ;-) -BEF-
#
sub _include_bundle {

    my $file = shift;

    chomp($file);
    ssm_print "Bundle:  $file\n" unless($::o{only_this_file});

    $BUNDLEFILE_LIST{$file} = 1;

    # For --analyze-config purposes, prefix the input data from this
    # bundle file with it's own name as a BundleFile. -BEF-
    my @array;
    push @array, "\n";
    push @array, "BundleFile: $file\n";
    push @array, "\n";

    unless(($file =~ m#^file://#) 
        or ($file =~ m#^/#)
        or ($file =~ m#^http://#) 
        or ($file =~ m#^https://#) 
        or ($file =~ m#^ftp://#)) {

        $file = $::o{base_url} . '/' . $file;
    }

    my $tmp_file = get_file($file, 'error');

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

    my $file = shift;

    if( ! -e "/usr/bin/bu" ) { return 1; }
    if( ! -e $file ) { return 1; }

    my $cmd = "/usr/bin/bu $file";
    !system($cmd) or die("FAILED: $cmd\n $!");

    return 1;
}


sub add_new_packages {

    push @{$::o{add_package}}, @ARGV;

    add_packages_to_repo( @{$::o{add_package}} );
    $CHANGES_MADE++;

    return ($ERROR_LEVEL, $CHANGES_MADE);
}


sub add_new_files {

    push @{$::o{add_file}}, @ARGV;

    foreach my $file ( @{$::o{add_file}} ) {
        add_file_to_repo($file);
        $CHANGES_MADE++;
    }

    return ($ERROR_LEVEL, $CHANGES_MADE);
}


#
#   Usage:  my $type = get_file_type($file);
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
    
    my $file = shift;

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my $type;

    if( lstat($file) ) {

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

    } elsif( -l $file ) {

        # For some reason (a bug in perl maybe?), some symlinks may not be
        # successfully detected with stat, but are with this method.  -BEF-
        $type = 'softlink';

    } else {
        $type = 'non-existent';
    }

    return $type;
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

    my $file = shift;

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    if( $file !~ m|^/| ) {
        ssm_print "$debug_prefix Finding fully qualified file name $file" if($::o{debug});
        $file = fully_qualified_file_name($file);
        ssm_print " => $file\n" if($::o{debug});
    }

    $file = normalized_file_name( $file ); 

    if(! defined $BUNDLEFILE{$file}) {
        $BUNDLEFILE{$file} = choose_valid_bundlefile();
    }

    my $type = get_file_type($file);
    if($type eq 'non-existent') {
        ssm_print "ERROR:   File $file does not appear to exist!\n";
        $ERROR_LEVEL++;
        return 3;
    }
    ssm_print "$debug_prefix FILE $file is of TYPE $type\n" if($::o{debug});

    if($type eq 'regular') {
        add_file_to_repo_type_regular($file);
    }
    else {
        add_file_to_repo_type_nonRegular($file, $type);
    }

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }

    return 1;
}


sub add_file_to_repo_type_nonRegular {

    my $file   = shift;
    my $type   = shift;

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my %filespec;
    $filespec{type}     = $type;
    $filespec{name}     = $file;
    $filespec{owner}    = get_uid($file);
    $filespec{group}    = get_gid($file);
    $filespec{mode}     = get_mode($file)       unless( ($filespec{type} eq 'softlink') );
    $filespec{target}   = readlink($file)           if( ($filespec{type} eq 'softlink') );
    $filespec{major}    = get_major($file)          if( ($filespec{type} eq 'character') or ($filespec{type} eq 'block') );
    $filespec{minor}    = get_minor($file)          if( ($filespec{type} eq 'character') or ($filespec{type} eq 'block') );;

    my $tmp_file = update_or_add_file_stanza_to_bundlefile( %filespec );

    my $bundlefile = "$BUNDLEFILE{$file}";
    copy_file_to_upstream_repo($tmp_file, $bundlefile);
    unlink $tmp_file;

    $::outstanding{$file} = 'fixed';

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; }

    return 1;
}


sub add_file_to_repo_type_regular {

    my $file   = shift;

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my %filespec;
    $filespec{type}     = 'regular';
    $filespec{name}     = $file;
    $filespec{md5sum}   = get_md5sum($file);
    $filespec{owner}    = get_uid($file);
    $filespec{group}    = get_gid($file);
    $filespec{mode}     = get_mode($file);

    # Copy the file itself into the repo
    my $filename_in_repo = "$file/$filespec{md5sum}";
    copy_file_to_upstream_repo($file, $filename_in_repo);

    my $tmp_file = update_or_add_file_stanza_to_bundlefile( %filespec );

    my $bundlefile = "$BUNDLEFILE{$file}";
    copy_file_to_upstream_repo($tmp_file, $bundlefile);
    unlink $tmp_file;

    $::outstanding{$file} = 'fixed';

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

    if(! defined $proposed_bundlefile) {
        $proposed_bundlefile = $::o{bundlefile};
    }

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

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
#   my $file = "/tmp/$PROGNAME.log";
#   my $ending_lognumber    = 7;
#   my $starting_lognumber  = 1;
#   rotate_log_file($file, $starting_lognumber, $ending_lognumber);
#
sub rotate_log_file {

    my $file                = shift;
    my $starting_lognumber  = shift;
    my $ending_lognumber    = shift;

    my $i = $ending_lognumber;

    until( $i == $starting_lognumber ) {

        my $file_old = "$file." . ($i - 1);
        my $file_new = "$file." . $i;

        if( -e $file_old ) {
            #if( $::o{debug} ) { print " rename($file_old, $file_new)\n"; }
            rename($file_old, $file_new) or die("Couldn't rename $file_old to $file_new");
        }

        $i--;
    }

    my $file_old = $file;
    my $file_new = "$file.$starting_lognumber";

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

    my $file    = shift;
    my $path    = shift;

    if(! defined($path)) {
        $path = $ENV{PATH};
    }

    foreach my $dir (split(/:/,$path)) {
        my $binary = "$dir/$file";
        if(-x $binary) {
            return $binary;
        }
    }
    return undef;
}

#
# Usage: remove_file($file);
#        remove_file($file,'silent');
#
sub remove_file {

    my $file        = shift;
    my $silent      = shift;
    my $run_scripts  = shift;

    ssm_print "         FIXING:  Removing: $file\n" unless( defined $silent );

    if($::o{debug}) { ssm_print "remove_file($file)\n"; }

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
    execute_prescript($file) if( $calling_function eq 'SimpleStateManager::take_file_action' );

    my $rm = _which("rm");
    my $cmd = "$rm -fr $file";
    !system($cmd) or die("FAILED: $cmd\n $!");

    execute_postscript($file) if( $calling_function eq 'SimpleStateManager::take_file_action' );

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

            ssm_print "WARNING: Package autoremoves -> not supported by this package manager\n";

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

        my @sort_list;
        foreach my $pkg (sort keys %pending_pkg_changes) {

            my $action = lc( $pending_pkg_changes{$pkg}{action} );
            my $pad = get_pad($max_length - length($action));

            push @sort_list, "- ${action}${pad} $pkg";
        }

        foreach my $line (sort @sort_list) {
            ssm_print "         $line\n";
        }

        take_pkg_action('install_pkgs', (keys %pending_pkg_changes) );

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

        if( -e $PKG_REPO_UPDATE_TIMESTAMP_FILE ) {

            my $current_time = time();
            my $timestamp = get_file_timestamp( $PKG_REPO_UPDATE_TIMESTAMP_FILE );

            my $age_of_timestamp = $current_time - $timestamp;

            my $window_in_seconds = $::o{pkg_repo_update_window} * 60 * 60;     # hours * minutes * seconds

            if( $age_of_timestamp < $window_in_seconds ) {
                ssm_print "INFO:    Package repo update -> skipping (updated in the last $::o{pkg_repo_update_window} hours)\n";
                return 1;
            }
        }
    }

    ssm_print "INFO:    Package repo update -> updating\n";

    $return_code = update_pkg_availability_data();

    mkpath("$STATE_DIR", 0, 0775) unless( -e $STATE_DIR );
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
        eval { mkpath("$path", 0, 0775) };
        if($::o{debug}) { ssm_print qq($debug_prefix mkpath "$path", 0, 0775\n); }
        if($@) { ssm_print "Couldn’t create $dir: $@"; }

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


sub fully_qualified_path {

    my $file = shift;

    my $dir = dirname($file) . "/" . basename($file);

    return 
}


sub fully_qualified_file_name {

    my $file = shift;

    my $working_dir = getcwd();

    # cd into target dir, no matter how it was specified (ie.,
    # ../my/dir)
    chdir dirname( $file );
    my $path = getcwd();
    my $basename = basename($file);
    my $fully_qualified_file_name = "$path/$basename";

    # cd -
    chdir $working_dir;

    return $fully_qualified_file_name;
}


sub normalized_file_name {
    
    my $file = shift;

    # Turn double slashes into single slashes so that tests for conflicting
    # host names work properly.
    $file =~ s|/+|/|go;

    # Turn directories specified with an ending slash into no ending slash to
    # ensure conflicting directory names are treated properly.
    $file =~ s|/$||o;

    return $file;
}
#
################################################################################

1;

