#  
#   Copyright (C) 2006-2010 Brian Elliott Finley
#
#   $Id: SystemStateManager.pm 378 2010-09-20 15:23:03Z finley $
#    vi: set filetype=perl tw=0:
# 

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


package SystemStateManager;

use Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(   
                version
                user_is_root
                get_current_state
                read_definition_file
                sync_state
                add_file_to_repo
                ssm_print 
                run_cmd
                choose_tmp_file
                email_log_file
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
use Fcntl qw( S_IFBLK S_IFCHR );
use Digest::MD5;
use LWP::Simple;
use Mail::Send;


################################################################################
#
#   This package provides the following functions:
#
#       % egrep '^sub ' lib/SystemStateManager.pm | perl -pi -e 's/^sub /#   /; s/ {//;' | sort
#
#   _add_file
#   add_file_to_repo
#   _backup
#   check_depends
#   choose_tmp_file
#   close_log_file
#   compare_package_options
#   create_directory
#   diff_file
#   diff_ownership_and_permissions
#   do_directory
#   do_generated_file
#   do_hardlink
#   do_ignore
#   do_regular_file
#   do_softlink
#   do_special_file
#   do_unwanted_file
#   do_you_want_me_to
#   email_log_file
#   _get_arch
#   get_file
#   get_pkgs_to_be_installed
#   get_pkgs_to_be_reinstalled
#   get_pkgs_to_be_removed
#   group_to_gid
#   _include_bundle
#   _initialize_log_file
#   _initialize_variables
#   install_file
#   md5sum_match
#   read_definition_file
#   remove_file
#   report_improper_file_definition
#   report_improper_service_definition
#   rotate_log_file
#   run_cmd
#   set_ownership_and_permissions
#   show_diff_comments
#   ssm_print
#   sync_state
#   turn_groupnames_into_gids
#   turn_service_into_file_entry
#   turn_usernames_into_uids
#   uid_gid_and_mode_match
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
# Hash for holding package information
my %PKGS_FROM_STATE_DEFINITION;
my %PKGS_PROVIDED_BY_PKGS_FROM_STATE_DEFINITION;

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
);

my $OUTSTANDING_PACKAGES_TO_REMOVE    = 0;
my $OUTSTANDING_PACKAGES_TO_UPGRADE   = 0;
my $OUTSTANDING_PACKAGES_TO_INSTALL   = 0;
my $OUTSTANDING_PACKAGES_TO_REINSTALL = 0;

my $ERROR_LEVEL  = 0;
my $CHANGES_MADE = 0;
our $LOGFILE;

#
################################################################################

################################################################################
#
#   Subroutines
#
sub _initialize_variables {

    (   %PKGS_FROM_STATE_DEFINITION,
        %PKGS_PROVIDED_BY_PKGS_FROM_STATE_DEFINITION,
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
    ) = ();
    
    $ERROR_LEVEL = 0;

    return 1;
}

sub _initialize_log_file {

    my $log_file = "/var/log/" . basename($0);

    my $starting_lognumber = 1;
    my $ending_lognumber = 49;
    rotate_log_file($log_file, $starting_lognumber, $ending_lognumber);

    umask 0027;
    open(LOGFILE,">$log_file") or die("Couldn't open $log_file for writing!");
    $LOGFILE = *LOGFILE;

    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
    $year += 1900;
    $mon  = sprintf("%02d", $mon + 1);
    $mday = sprintf("%02d", $mday);
    $hour = sprintf("%02d", $hour);
    $min = sprintf("%02d", $min);
    print LOGFILE "TIMESTAMP: $year.$mon.$mday - $hour:$min\n";

    return 1;
}

# ssm_print "thing to print";
sub ssm_print {

    my $content = shift;
    
    print STDOUT   $content;
    print $LOGFILE $content;

    return 1;
}

sub read_definition_file {

    _initialize_variables();

    _initialize_log_file();

    my @analyze;

    if( $main::o{debug} ) { ssm_print "read_definition_file()\n"; }

    unless( defined($main::o{definition_file}) ) {
        
        my $file = '/etc/ssm/client.conf';
        open(FILE,"<$file") or die("Couldn't open $file for reading. $!\n");
            while(<FILE>) {
                if(m/^definition_file\s+(.*)(\s|#|$)/) {
                    $main::o{definition_file} = $1;
                }
            }
        close(FILE);
    }

    $main::o{hostname} = `hostname -f`;
    chomp $main::o{hostname};

    if( $main::o{definition_file} =~ m,/$, ) {
        # URI ends with a slash.  Is a dir.  Append hostname
        $main::o{definition_file} .= $main::o{hostname};
    }

    ssm_print "\nState Definition File: $main::o{definition_file}\n" unless(@{$main::o{only_this_file}});

    my $tmp_file = get_file($main::o{definition_file});

    # For --analyze-config purposes, prefix the input data from the
    # state definition file with it's own name as a BundleFile. -BEF-
    my @input = "BundleFile: $main::o{definition_file}\n";
    push @input, "\n";

    open(FILE,"<$tmp_file") or die "Couldn't open $tmp_file for reading: $!";
        push @input, (<FILE>);
    close(FILE);
    unlink $tmp_file;
    
    my $stanza_terminator = '^(\s+|$)';
    my $comment = '^#';
    my $bundlefile;

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

                if( m/^pkg_manager\s+(.*)(\s|#|$)/ )    { $main::o{pkg_manager} = lc($1); }
                if( m/^base_ur[il]\s+(.*)(\s|#|$)/ )       { $main::o{base_url} = $1; }
                if( m/^git_ur[il]\s+(.*)(\s|#|$)/ )        { $main::o{git_url} = $1; }
                if( m/^svn_ur[il]\s+(.*)(\s|#|$)/ )        { $main::o{svn_url} = $1; }
                if( m/^email_log_to\s+(.*)(\s|#|$)/ )   { $main::o{email_log_to} = $1; }
                if( m/^log_file_perms\s+(.*)(\s|#|$)/ )   { $main::o{log_file_perms} = $1; }
                if( m/^remove_running_kernel\s+(.*)(\s|#|$)/ )   { $main::o{remove_running_kernel} = $1; }

                $_ = shift @input;
            }

            unless( ($main::o{pkg_manager} eq 'dpkg'    )
                 or ($main::o{pkg_manager} eq 'aptitude')
                 or ($main::o{pkg_manager} eq 'yum'     )
                 or ($main::o{pkg_manager} eq 'none'    )
            ) {
                ssm_print "\n";
                ssm_print "ERROR: Invalid entry in definition file.  Please specify your package\n";
                ssm_print "       management system with an entry like:\n";
                ssm_print "\n";
                ssm_print "          pkg_manager = aptitude\n";
                ssm_print "       or pkg_manager = dpkg\n";
                ssm_print "       or pkg_manager = yum\n";
                ssm_print "       or pkg_manager = none\n";
                ssm_print "\n";

                exit 1;
            }

            ssm_print "OK:      Package manager -> $main::o{pkg_manager}\n" unless(@{$main::o{only_this_file}}); 

            if( ! defined $main::o{base_url} ) { 
                # No base_url defined.  Therefore, we assume base_url 
                # should be the same as the definition file url, sans
                # the filename itself. -BEF-
                $main::o{base_url} = dirname( $main::o{definition_file} );
            }
            if( ! defined $main::o{remove_running_kernel} ) { 
                # Default to "no"
                $main::o{remove_running_kernel} = 'no';
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
                    if(! defined $PKGS_FROM_STATE_DEFINITION{$pkg}) {
                        $PKGS_FROM_STATE_DEFINITION{$pkg} = $options;
                    } else {
                        $PKGS_FROM_STATE_DEFINITION{$pkg} = compare_package_options($pkg, $options);
                        ssm_print ">> Winning options:  $PKGS_FROM_STATE_DEFINITION{$pkg}\n\n" if($main::o{debug});
                    }

                    if($main::o{debug}) { ssm_print "[packages]: $pkg, $options\n"; }

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

            if( (defined $name) and (defined $DETAILS{$name}) ) {
                ssm_print "\n";
                ssm_print "ERROR: Multiple (conflicting) definitions for:\n";
                ssm_print "\n";
                ssm_print "  [service]\n";
                ssm_print "  name = $name\n";
                ssm_print "  ...\n";
                ssm_print "\n";
                ssm_print "  Exiting now without modifying the service. Please examine your state\n";
                ssm_print "  definition file and eliminate all but one of the definitions for\n";
                ssm_print "  this service.\n";
                ssm_print "\n";

                $ERROR_LEVEL++;
                if($main::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }

                # We go ahead and exit here to be super conservative.
                ssm_print "\n";
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
                ssm_print "Not OK:  Service $name -> Unmet dependencies:\n";
                ssm_print "         $unsatisfied\n";
                $ERROR_LEVEL++;
                if($main::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }

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

                    if($main::o{debug}) { ssm_print "name before: $name\n"; }
                    # Turn double slashes into single slashes so that
                    # tests for conflicting host names work properly.
                    $name =~ s|/+|/|go;

                    # Turn directories specified with an ending slash
                    # into no ending slash to ensure conflicting
                    # directory names are treated properly.
                    $name =~ s|/$||go;
                    if($main::o{debug}) { ssm_print "name after: $name\n"; }


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
                    $generator = $value;

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
                ssm_print "\n";
                ssm_print "ERROR: Multiple (conflicting) definitions for:\n";
                ssm_print "\n";
                ssm_print "  [file]\n";
                ssm_print "  name     = $name\n";
                ssm_print "  priority = $priority\n";
                ssm_print "  ...\n";
                ssm_print "\n";
                ssm_print "  This instance of this file was found in $bundlefile\n";
                ssm_print "\n";
                ssm_print "  Exiting now without modifying the file. Please examine your state\n";
                ssm_print "  definition file and eliminate all but one of the definitions for\n";
                ssm_print "  this file, or raise the priority of one of the definitions.\n";
                ssm_print "\n";

                $ERROR_LEVEL++;
                if($main::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }

                # We go ahead and exit here to be super conservative.
                ssm_print "\n";
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

                }

            }

            unless(defined $TYPE{$name}) {
                return report_improper_file_definition($name);
            }
        }
    }  

    if( $main::o{analyze_config} ) {

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

# Print a pad of spaces of N length
# print_pad(N);
sub print_pad {

    my $pad = shift;

    my $i = 0;
    until($i == $pad) {
        print " ";
        $i++;
    }
    return 1;
}

sub turn_usernames_into_uids {
    foreach(keys %OWNER) {
        $OWNER{$_} = user_to_uid($OWNER{$_});
    }
    return 1;
}


sub turn_groupnames_into_gids {
    foreach(keys %GROUP) {
        $GROUP{$_} = group_to_gid($GROUP{$_});
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


sub sync_state {

    $CHANGES_MADE = 0;

    if( $main::o{pkg_manager} eq "dpkg" ) {
        require SystemStateManager::Dpkg;
        SystemStateManager::Dpkg->import();
    }
    elsif( $main::o{pkg_manager} eq "aptitude" ) {
        require SystemStateManager::Aptitude;
        SystemStateManager::Aptitude->import();
    }
    elsif( $main::o{pkg_manager} eq "yum" ) {
        require SystemStateManager::Yum;
        SystemStateManager::Yum->import();
    }
    elsif( $main::o{pkg_manager} eq "none" ) {
        require SystemStateManager::None;
        SystemStateManager::None->import();
    }

    upgrade_ssm() unless($main::o{answer_no});

    #
    # Files
    my %only_this_file_hash;
    foreach my $file ( @{$main::o{only_this_file}} ) {
        $only_this_file_hash{$file} = 1;
    }
    foreach my $file (sort keys %TYPE) {

        next if( @{$main::o{only_this_file}} and !defined($only_this_file_hash{$file}) );

        last if($main::o{only_packages});

        my $unsatisfied = check_depends($file);
        if($unsatisfied ne "1") {
            ssm_print "Not OK:  File $file -> Unmet dependencies:\n";
            ssm_print "         $unsatisfied\n";
            $ERROR_LEVEL++;
            if($main::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }
        }

        elsif( ($TYPE{$file} eq 'ignore') or ($TYPE{$file} eq 'ignored') ) {
            do_ignore($file);
        }
        elsif( $TYPE{$file} eq 'softlink' ) {
            do_softlink($file);
        }
        elsif( $TYPE{$file} eq 'hardlink' ) {
            do_hardlink($file);
        }
        elsif(     $TYPE{$file} eq 'block' 
                or $TYPE{$file} eq 'character'
                or $TYPE{$file} eq 'fifo'      ) {
            do_special_file($file);
        }
        elsif( $TYPE{$file} eq 'chown+chmod' ) {
            do_chown_and_chmod($file);
        }
        elsif( $TYPE{$file} eq 'regular' ) {
            do_regular_file($file);
        }
        elsif( $TYPE{$file} eq 'directory' ) {
            do_directory($file);
        }
        elsif( $TYPE{$file} eq 'unwanted' ) {
            do_unwanted_file($file);
        }
        elsif( $TYPE{$file} eq 'directory+contents-unwanted' ) {
            do_directory($file);
            do_contents_unwanted($file);
        }
        elsif( $TYPE{$file} eq 'generated' ) {
            do_generated_file($file);
        }
        else {
            return report_improper_file_definition($file);
        }
    }
    

    # Get integer value that represents the number of packages defined.
    if( (scalar (keys %PKGS_FROM_STATE_DEFINITION)) == 0) {
        ssm_print "OK:      Packages -> No [packages] defined in the state definition file.\n";
        return ($ERROR_LEVEL, $CHANGES_MADE);
    }
    elsif( $main::o{pkg_manager} eq 'none' ) {
        ssm_print "WARNING: Packages -> [packages] defined, but 'pkg_manager = none'.\n";
        return ($ERROR_LEVEL, $CHANGES_MADE);
    } 
    elsif( defined(@{$main::o{only_this_file}}) ) {
        # Don't print anything to keep output minimalist in this case.
        return ($ERROR_LEVEL, $CHANGES_MADE);
    }
    elsif( $main::o{only_files} ) {
        ssm_print "OK:      Option --only-files specified.  Skipping [packages] sections.\n"; 
        return ($ERROR_LEVEL, $CHANGES_MADE);
    } 
    else {

        # Do this here, and only once, for performance purposes. -BEF-
        %PKGS_PROVIDED_BY_PKGS_FROM_STATE_DEFINITION = get_pkgs_provided_by_pkgs_from_state_definition(\%PKGS_FROM_STATE_DEFINITION);

        if( $main::o{debug} ) {
            ssm_print '>> Contents of: %PKGS_PROVIDED_BY_PKGS_FROM_STATE_DEFINITION' . "\n";
            foreach (keys %PKGS_PROVIDED_BY_PKGS_FROM_STATE_DEFINITION) {
                ssm_print ">> Provided: $_=$PKGS_PROVIDED_BY_PKGS_FROM_STATE_DEFINITION{$_}\n" ;
            }
        }
    }

    ####################################################################
    #
    # BEGIN Package related activities
    #
    # 1 of 4
    #   Packages to Install:
    #   Install dependencies (not in definition):
    sync_state_install_packages();

    # 2 of 4
    #   Packages to Upgrade:
    #   Upgrade dependencies (not in definition):
    sync_state_upgrade_packages();

    # 3 of 4
    #   Packages to remove:
    #   Remove dependencies (in definition):
    sync_state_remove_packages();

    # 4 of 4
    #   Packages to Re-install: (DO WE REALLY NEED THIS? -BEF-)
    sync_state_reinstall_packages();

    #
    # END Package related activities
    #
    ####################################################################

    # Remove checked out SSM DB, if it exists.
    my $ou_path = "/tmp/ssm_db.repo.$$";
    remove_file("$ou_path");

    ssm_print "\n";
    ssm_print "Changes made:        $CHANGES_MADE\n";
    ssm_print "Outstanding changes:\n";
    ssm_print "-------------------------------\n";
    ssm_print "- Packages to install:     $OUTSTANDING_PACKAGES_TO_INSTALL\n";
    ssm_print "- Packages to re-install:  $OUTSTANDING_PACKAGES_TO_REINSTALL\n";
    ssm_print "- Packages to remove:      $OUTSTANDING_PACKAGES_TO_REMOVE\n";
    ssm_print "- Packages to upgrade:     $OUTSTANDING_PACKAGES_TO_UPGRADE\n";
    ssm_print "- Other:                   $ERROR_LEVEL\n";
    ssm_print "\n";

    $ERROR_LEVEL += $OUTSTANDING_PACKAGES_TO_INSTALL;
    $ERROR_LEVEL += $OUTSTANDING_PACKAGES_TO_REINSTALL;
    $ERROR_LEVEL += $OUTSTANDING_PACKAGES_TO_REMOVE;
    $ERROR_LEVEL += $OUTSTANDING_PACKAGES_TO_UPGRADE;

    if( $main::o{debug} ) { 
        ssm_print "lib/SystemStateManager.pm:sync_state() returning:\n";
        ssm_print "  \$ERROR_LEVEL:  $ERROR_LEVEL\n";
        ssm_print "  \$CHANGES_MADE: $CHANGES_MADE\n";
        ssm_print "\n";
    }

    sleep 1;
    return ($ERROR_LEVEL, $CHANGES_MADE);
}


sub close_log_file {
    if( $main::o{debug} ) { ssm_print "close_log_file()\n"; }
    close($LOGFILE) or die("Couldn't close $LOGFILE");

    my $log_file = "/var/log/" . basename($0);
    if( $main::o{log_file_perms} ) {
        chmod oct($main::o{log_file_perms}), $log_file;
    }

    return 1;
}

sub email_log_file {

    if( $main::o{debug} ) { ssm_print "email_log_file()\n"; }

    close_log_file();

    unless($main::o{email_log_to}) {
        return 1;
    }
    
    my $msg;
    my $fh;
    my $log_file = "/var/log/" . basename($0);
    my $file = $log_file;
    my $subject = "SSM: $main::o{hostname}";

    $msg = Mail::Send->new;
    $msg = Mail::Send->new(Subject => $subject, To => $main::o{email_log_to} );
    $fh = $msg->open;
    open(FILE,"<$file") or die("Couldn't open $file for reading!");
        while(<FILE>) {
            print $fh $_;
        }
    close(FILE);
    $fh->close;         # complete the message and send it

    return 1;
}


sub get_pkgs_to_be_removed {
    ssm_print ">>\n>> get_pkgs_to_be_removed()\n" if( $main::o{debug} );

    my %pkgs_currently_installed = get_pkgs_currently_installed();

    my @array;
    foreach my $pkg ( keys %pkgs_currently_installed ) {
        if( ! defined($PKGS_FROM_STATE_DEFINITION{$pkg}) or ($PKGS_FROM_STATE_DEFINITION{$pkg} =~ m/\bunwanted\b/i )) {
        ssm_print ">>> remove: $pkg\n" if( $main::o{debug} );
            push @array, $pkg;
        }
    }
    
    return @array;
}


#
# returns an array:  "pkg=version" or just "pkg"
#   - packages not currently installed
#   - packages from definition include version numbers if appropriate
#
sub get_pkgs_to_be_installed {
    ssm_print ">>\n>> get_pkgs_to_be_installed()\n" if( $main::o{debug} );

    my %pkgs_currently_installed = get_pkgs_currently_installed();

    #
    # If it's in the state definition, but not installed, install it.
    #
    my %hash;
    foreach my $pkg (keys %PKGS_FROM_STATE_DEFINITION) {
        if(( ! $pkgs_currently_installed{$pkg} ) and ( $PKGS_FROM_STATE_DEFINITION{$pkg} !~ m/\bunwanted\b/i )) {
            $hash{$pkg} = $PKGS_FROM_STATE_DEFINITION{$pkg};
        }
    }

    return (keys %hash);
}


sub get_pkgs_to_be_reinstalled {
    ssm_print ">>\n>> get_pkgs_to_be_reinstalled()\n" if( $main::o{debug} );

    #
    # returns an array:  "pkg=version" or just "pkg"
    #   packages currently installed that need to be reinstalled
    #

    my @array;
    return @array;  #XXX remove all calls to get_pkgs_to_be_reinstalled from code, then remove this subroutine. No longer needed w/no version number supported.  -BEF-

}


sub version {
    # Can't use ssm_print in here -- not initialiased yet. -BEF-
    my $progname = basename($0);
    my $VERSION = '___VERSION___';
    print <<EOF;
$progname (part of System State Manager) v$VERSION
    
EOF
}


#
# Usage: my $arch = get_arch();
#
sub _get_arch {

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
        my $even_if_answer_no = shift;

        if( ! $main::o{answer_no} or defined($even_if_answer_no) ) { 
            ssm_print ">> $cmd\n" if( $main::o{debug} );
            open(INPUT,"$cmd|") or die("FAILED: $cmd\n $!");
            while(<INPUT>) {
                ssm_print $_;
            }
            close(INPUT);
        }

        ssm_print "\n" if( defined $add_newline );

        return 1;
}


sub do_you_want_me_to {

    my $msg = shift;

    ssm_print $msg if(defined $msg);

    $_ = <STDIN>;

    if( m/^(y|yes)/i ) {
        return 'yes';
    } elsif( m/^(d|diff)/i ) {
        return 'diff';
    } elsif( m/^(a|add)/i ) {
        return 'add';
    } elsif( m/^(n|no)/i ) {
        return 'no';
    } elsif( m/^(c|comment|comments)/i ) {
        return 'comments';
    }
}


sub do_ignore {
     
    #
    # Simply ignore the entry.
    #

    my $file = shift;

    # validate input
    unless( 
            defined($file)        and ($file        =~ m#^/#)
        and defined($TYPE{$file}) and ($TYPE{$file} =~ m#\S#)
    ) {
        return report_improper_file_definition($file);
    }

    ssm_print "OK:      Ignoring $file\n";

    return 1;
}

sub do_softlink {

    # 
    # Accept either relative or absolute target, and implement as user
    # specifies.
    #

    my $file = shift;

    #
    # validate input
    unless( 
            defined($file)          and ($file          =~ m#^/#)
        and defined($TARGET{$file}) and (($TARGET{$file} =~ m#^/#) or ($TARGET{$file} =~ m#^\.\./#))
        and defined($TYPE{$file})   and ($TYPE{$file}   =~ m#\S#)
    ) {
        return report_improper_file_definition($file);
    }

    #
    # Singularize double slashes in target names
    $TARGET{$file} =~ s#/+#/#g;

    if( ! -e $TARGET{$file} ) {
        ssm_print "WARNING: Soft link $file -> $TARGET{$file} (target doesn't exist).\n";
        sleep 1;
    }

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

        ssm_print "Not OK:  Soft link $file -> $TARGET{$file}\n";
        ssm_print "         Need to:\n";
        ssm_print "         - $PRESCRIPT{$file}\n" if($PRESCRIPT{$file});
        ssm_print "         - remove $file\n" if( -e $file );
        ssm_print "         - create link\n";
        ssm_print "         - $POSTSCRIPT{$file}\n" if($POSTSCRIPT{$file});

        my $fix_it = undef;

        if($main::o{yes}) {
            $fix_it = 1;
        } elsif($main::o{answer_no}) {
            $fix_it = undef;
            $ERROR_LEVEL++;  if($main::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }
        } else {
            ssm_print "         Shall I do this? [N/y]: ";
            if( do_you_want_me_to() eq 'yes' ) { 
                $fix_it = 1;
            } else {
                ssm_print "         Ok, skipping this step.\n";
                $ERROR_LEVEL++;
                if($main::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }
                sleep 1;
            }
        }

        if( defined($fix_it) and ! $main::o{answer_no} ) {

            $CHANGES_MADE++;
            ssm_print "FIXING:  Soft link $file -> $TARGET{$file}\n";

            do_prescript($file);

            remove_file($file);
            symlink($TARGET{$file}, $file) or die "Couldn't symlink($TARGET{$file}, $file) $!";

            do_postscript($file);
        }
    } else {
        ssm_print "OK:      Soft link $file -> $TARGET{$file}\n";
    }

    return 1;
}


sub do_special_file {

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

    #
    # Does it need fixing?
    my $needs_fixing = undef;
    if( ! -e $file ) {
        # Ain't there
        $needs_fixing = 1;
    } 
    else {

        my $st = stat($file);

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
    }

    #
    # Should we actually fix it?
    my $fix_it = undef;
    if( defined($needs_fixing) ) {

        ssm_print "Not OK:  " . ucfirst($TYPE{$file}) . " file $file\n";
        ssm_print "         Need to:\n";
        ssm_print "         - $PRESCRIPT{$file}\n" if($PRESCRIPT{$file});
        ssm_print "         - remove $file\n" if( -e $file );
        ssm_print "         - create $file\n";
        ssm_print "         - $POSTSCRIPT{$file}\n" if($POSTSCRIPT{$file});

        if($main::o{yes}) {
            $fix_it = 1;
        } elsif($main::o{answer_no}) {
            $fix_it = undef;
            $ERROR_LEVEL++;  if($main::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }
        } else {

            ssm_print "         Shall I do this? [N/y]: ";

            if( do_you_want_me_to() eq 'yes' ) { 
                $fix_it = 1;
            } else {
                ssm_print "         Ok, skipping this step.\n";
                $ERROR_LEVEL++;
                if($main::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }
                sleep 1;
            }
        }

    } else {
        ssm_print "OK:      " . ucfirst($TYPE{$file}) . " file $file\n";
    }

    #
    # Take action
    if( defined($fix_it) and ! $main::o{answer_no} ) {

        $CHANGES_MADE++;
        ssm_print "FIXING:  " . ucfirst($TYPE{$file}) . " file $file\n";

        do_prescript($file);

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

        #
        # Ensure proper ownership
        set_ownership_and_permissions($file);

        do_postscript($file);
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


sub set_ownership_and_permissions {

    my $file = shift;

    ssm_print "FIXING:  Ownership and Perms: $file\n";

    chown $OWNER{$file}, $GROUP{$file}, $file;
    chmod oct($MODE{$file}), $file;

    return 1;
}


sub do_contents_unwanted {

    ssm_print ">> do_contents_unwanted()\n" if( $main::o{debug} );

    my $dir   = shift;

    #
    # validate input
    if(    !defined($dir)        or ($dir        !~ m#^/#)
        or !defined($TYPE{$dir}) or ($TYPE{$dir} !~ m/\S/)
      ) {
        return report_improper_file_definition($dir);
    }

    if( ! -e $dir ) {
        ssm_print "WARNING: Contents-unwanted directory $dir doesn't exist\n";
        return 1;
    }
    elsif( ! -d $dir ) {
        ssm_print "WARNING: Contents-unwanted directory $dir is not a directory\n";
        return 1;
    }

    ssm_print "INFO:    Processing contents-unwanted directory $dir\n";

    # state what we're doing
    # get list of files in directory
    my $file;
    opendir(DIR,"$dir") or die "Can't open $dir for reading";
        # see if each file matches a defined file
        #   * test this to be sure that:
        #       If /etc/iptables.d/stuff/monkey is defined, make sure it is
        #       not removed, even if /etc/iptables.d/stuff is not explicitly
        #       defined.  It is implicitly defined.  Ie.: match on left hand
        #       side of string if necessary.
        while (defined ($file = readdir DIR) ) {
            next if $file =~ /^\.\.?$/;
            $file = "$dir/$file";
            ssm_print ">>> in_directory: $file\n" if( $main::o{debug} );
            unless (defined $TYPE{$file}) {
                # for each file that isn't defined:  do_unwanted_file($file);
                $TYPE{$file} = 'unwanted';
                do_unwanted_file($file);
            }
        }
    closedir(DIR);

    return 1;
}


sub do_unwanted_file {

    my $file   = shift;

    #
    # validate input
    if(    !defined($file)        or ($file        !~ m#^/#)
        or !defined($TYPE{$file}) or ($TYPE{$file} !~ m/\S/)
    ) {
        return report_improper_file_definition($file);
    }

    #
    # Does it need fixing?
    my $needs_fixing = undef;
    if( -e $file or -l $file ) {
        # It exists, and must be destroyed!!!
        $needs_fixing = 1;
    } 

    #
    # Should we actually fix it?
    my $fix_it = undef;
    unless(defined($needs_fixing)) {
        ssm_print "OK:      Unwanted $file doesn't exist\n";

    } else {

        if( -d $file ) {
            ssm_print "Not OK:  Unwanted directory exists: $file\n";
            ssm_print "         Need to:\n";
            ssm_print "         - $PRESCRIPT{$file}\n" if($PRESCRIPT{$file});
            ssm_print "         - remove the contents of $file\n";
            ssm_print "         - remove $file\n";
            ssm_print "         - $POSTSCRIPT{$file}\n" if($POSTSCRIPT{$file});
        } else {
            ssm_print "Not OK:  Unwanted file exists: $file\n";
            ssm_print "         Need to:\n";
            ssm_print "         - $PRESCRIPT{$file}\n" if($PRESCRIPT{$file});
            ssm_print "         - remove $file\n";
            ssm_print "         - $POSTSCRIPT{$file}\n" if($POSTSCRIPT{$file});
        }

        if($main::o{yes}) {
            $fix_it = 1;
        } elsif($main::o{answer_no}) {
            $fix_it = undef;
            $ERROR_LEVEL++;  if($main::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }
        } else {

            ssm_print "         Shall I do this? [N/y]: ";

            if( do_you_want_me_to() eq 'yes' ) { 
                $fix_it = 1;
            } else {
                ssm_print "         Ok, skipping this step.\n";
                $ERROR_LEVEL++;
                if($main::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }
                sleep 1;
            }
        }
    }

    #
    # Take action
    if( defined($fix_it) ) {

        $CHANGES_MADE++;
        ssm_print "FIXING:  Removing: $file\n";

        do_prescript($file);
        remove_file($file);
        do_postscript($file);
    }

    return 1;
}


sub do_chown_and_chmod {

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
    my $fix_it = undef;
    if( defined($needs_fixing) ) {

        ssm_print "Not OK:  Chown+Chmod target $file\n";
        ssm_print "         Need to:\n";
        ssm_print "         - $PRESCRIPT{$file}\n" if($PRESCRIPT{$file});
        if( ! -e $file ) {
            ssm_print "         - create as empty file\n";
            ssm_print "         - set ownership and permissions\n";
        } else {
            ssm_print "         - fix ownership and permissions\n";
            diff_ownership_and_permissions($file, 12);
        }
        ssm_print "         - $POSTSCRIPT{$file}\n" if($POSTSCRIPT{$file});

        if($main::o{yes}) {
            $fix_it = 1;
        } elsif($main::o{answer_no}) {
            $fix_it = undef;
            $ERROR_LEVEL++;  if($main::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }
        } else {

            my $msg = "         Shall I do this? [N/y]: ";
            my $answer = do_you_want_me_to($msg);

            if( $answer eq 'yes' ) { 
                $fix_it = 1;
            } else {
                ssm_print "         Ok, skipping this step.\n";
                $ERROR_LEVEL++;
                if($main::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }
                sleep 1;
            }
        }
    } else {
        ssm_print "OK:      Chown+Chmod target $file\n";
    }

    #
    # Take action
    if( defined($fix_it) and ! $main::o{answer_no} ) {
        $CHANGES_MADE++;
        do_prescript($file);
        if( ! -e $file ) {
            # Ain't there -- create an empty file
            open(FILE,">$file") or die("Couldn't open $file for writing");
            close(FILE);
        } 
        set_ownership_and_permissions($file);
        do_postscript($file);
    }

    return 1;
}


sub do_directory {

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

    #
    # Does it need fixing?
    my $needs_fixing = undef;
    my $just_fix_uid_gid_and_mode = undef;
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
        $just_fix_uid_gid_and_mode = 1;
    } 

    #
    # Should we actually fix it?
    my $fix_it = undef;
    if( defined($needs_fixing) ) {

        ssm_print "Not OK:  Directory $file\n";
        ssm_print "         Need to:\n";
        if( defined($just_fix_uid_gid_and_mode) ) {
            ssm_print "         - fix ownership and permissions\n";
            diff_ownership_and_permissions($file, 12);
        } else {
            ssm_print "         - $PRESCRIPT{$file}\n" if($PRESCRIPT{$file});
            ssm_print "         - create $file\n";
            ssm_print "         - $POSTSCRIPT{$file}\n" if($POSTSCRIPT{$file});
        }

        if($main::o{yes}) {
            $fix_it = 1;
        } elsif($main::o{answer_no}) {
            $fix_it = undef;
            $ERROR_LEVEL++;  if($main::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }
        } else {

            my $msg = "         Shall I do this? [N/y]: ";
            my $answer = do_you_want_me_to($msg);

            if( $answer eq 'yes' ) { 
                $fix_it = 1;
            } else {
                ssm_print "         Ok, skipping this step.\n";
                $ERROR_LEVEL++;
                if($main::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }
                sleep 1;
            }
        }
    } else {
        ssm_print "OK:      Directory $file\n";
    }

    #
    # Take action
    if( defined($fix_it) and ! $main::o{answer_no} ) {
        $CHANGES_MADE++;
        if( defined($just_fix_uid_gid_and_mode) ) {
            set_ownership_and_permissions($file);
        } else {
            create_directory($file);
        }
    }

    return 1;
}


sub do_generated_file {

    my $file   = shift;

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

    # Generate file and get it's md5sum -- now considered to be the 
    # appropriate md5sum for $file.
    my $tmp_file = choose_tmp_file();
    open(TMP, "+>$tmp_file") or die "Couldn't open tmp file $!";

        open(INPUT,"$GENERATOR{$file}|") or die("Couldn't run $GENERATOR{$file} $!");
        print TMP (<INPUT>);
        close(INPUT);

        seek(TMP, 0, 0);
        $MD5SUM{$file} = Digest::MD5->new->addfile(*TMP)->hexdigest;

    close(TMP);


    #
    # Does it need fixing?
    my $needs_fixing = undef;
    my $just_fix_uid_gid_and_mode = undef;
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
        $just_fix_uid_gid_and_mode = 1;
    } 

    #
    # Should we actually fix it?
    my $fix_it = undef;
    if( defined($needs_fixing) ) {

        ssm_print "Not OK:  Generated file $file\n";
        ssm_print "         Need to:\n";
        if( defined($just_fix_uid_gid_and_mode) ) {
            ssm_print "         - fix ownership and permissions\n";
            diff_ownership_and_permissions($file, 12);
        } else {
            ssm_print "         - $PRESCRIPT{$file}\n" if($PRESCRIPT{$file});
            ssm_print "         - install $file\n";
            if( -e $file and ! uid_gid_and_mode_match($file) ) {
                # Also inform user about perms issue. -BEF-
                ssm_print "         - fix ownership and permissions\n";
                diff_ownership_and_permissions($file, 12);
            }
            ssm_print "         - $POSTSCRIPT{$file}\n" if($POSTSCRIPT{$file});
        }

        if($main::o{yes}) {
            $fix_it = 1;
            diff_file($file, $tmp_file);
        } elsif($main::o{answer_no}) {
            $fix_it = undef;
            diff_file($file, $tmp_file);
            $ERROR_LEVEL++;  if($main::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }
        } else {

            my $msg = "         Shall I do this? [N/y/d]: ";
            my $answer = do_you_want_me_to($msg);
            while( $answer eq 'diff' ) {
                diff_file($file, $tmp_file);
                $answer = do_you_want_me_to($msg);
            }

            if( $answer eq 'yes' ) { 
                $fix_it = 1;
            } else {
                ssm_print "         Ok, skipping this step.\n";
                $ERROR_LEVEL++;
                if($main::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }
                sleep 1;
            }
        }
    } else {
        ssm_print "OK:      Generated file $file\n";
    }

    #
    # Take action
    if( defined($fix_it) and ! $main::o{answer_no} ) {
        $CHANGES_MADE++;
        if( defined($just_fix_uid_gid_and_mode) ) {
            set_ownership_and_permissions($file);
        } else {
            install_file($file, $tmp_file);
        }
    }

    return 1;
}


sub do_regular_file {

    my $file   = shift;

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

    #
    # Does it need fixing?
    my $needs_fixing = undef;
    my $just_fix_uid_gid_and_mode = undef;
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
        $just_fix_uid_gid_and_mode = 1;
    } 

    #
    # Should we actually fix it?
    my $fix_it = undef;
    if( defined($needs_fixing) ) {

        ssm_print "Not OK:  Regular file $file\n";
        ssm_print "         Need to:\n";
        if( defined($just_fix_uid_gid_and_mode) ) {
            ssm_print "         - fix ownership and permissions:\n";
            diff_ownership_and_permissions($file, 12);
        } else {
            ssm_print "         - $PRESCRIPT{$file}\n" if($PRESCRIPT{$file});
            ssm_print "         - install $file\n";
            if( -e $file and ! uid_gid_and_mode_match($file) ) {
                # Also inform user about perms issue. -BEF-
                ssm_print "         - fix ownership and permissions\n";
                diff_ownership_and_permissions($file, 12);
            }
            ssm_print "         - $POSTSCRIPT{$file}\n" if($POSTSCRIPT{$file});
        }

        if($main::o{yes}) {
            $fix_it = 1;
            diff_file($file);
        } elsif($main::o{answer_no}) {
            $fix_it = undef;
            diff_file($file);
            $ERROR_LEVEL++;  if($main::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }
        } else {

            my $msg = "         Shall I do this? [N/y/d/c/a]: ";
            my $answer = do_you_want_me_to($msg);
            while( $answer eq 'diff' or $answer eq 'comments') {

                diff_file($file);

                if($answer eq 'comments') {
                    ssm_print "Here are the author's comments on this change:\n";
                    show_diff_comments($file);
                    ssm_print "\n";
                }

                $answer = do_you_want_me_to($msg);
            }

            if( $answer eq 'yes' ) { 
                $fix_it = 1;
            } elsif( $answer eq 'add' ) { 
                _add_file( $file );
            } else {
                ssm_print "         Ok, skipping this step.\n";
                $ERROR_LEVEL++;
                if($main::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }
                sleep 1;
            }
        }
    } else {
        ssm_print "OK:      Regular file $file\n";
    }

    #
    # Take action
    if( defined($fix_it) and ! $main::o{answer_no} ) {
        $CHANGES_MADE++;
        if( defined($just_fix_uid_gid_and_mode) ) {
            set_ownership_and_permissions($file);
        } else {
            install_file($file);
        }
    }

    return 1;
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


sub show_diff_comments {

    my $file     = shift;

    if( ! defined $main::o{svn_url} and ! defined $main::o{git_url}) {

        _try_a_revision_system();

    } elsif(defined $main::o{svn_url}) {

        my $svn = qq(svn --no-auth-cache);

        # NOTE:  If this is run without connectivity to the svn repository
        # (like if it's on a networked server, and the network is down),
        # then it may produce an error. 2009.11.05 -BEF-
        my $cmd = "$svn log --limit 1 $main::o{svn_url}/$file";
        run_cmd($cmd, undef, 1);

    } elsif(defined $main::o{git_url}) {

        my $cmd = "git log -1 $main::o{git_url}/$file";
        run_cmd($cmd, undef, 1);

    }

    return 1;
}


sub diff_file {

    my $file     = shift;
    my $tmp_file = shift;

    my $unlink = 'no';

    my $url;
    if( !defined($tmp_file) ) {
        $url = qq($main::o{base_url}/$file/$MD5SUM{$file});
        $tmp_file = get_file($url);
        $unlink = 'yes';
    }

    my $diff;
    if( $main::o{answer_no} or $main::o{yes}) {
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
    ssm_print "           Here is a diff between the file currently on your system (-)\n";
    ssm_print "           and the file in the repository (+):\n";
    ssm_print "           <<<------------------------------------------------------>>>\n\n";

    my $cmd = "$diff -urN $file $tmp_file";
    run_cmd($cmd, undef, 1);

    ssm_print "\n";
    ssm_print "           <<<------------------------------------------------------>>>\n\n";

    if( $unlink eq 'yes' ) {
        unlink $tmp_file;
    }

    return 1;
}

sub do_prescript {

    my $file = shift;

    if($PRESCRIPT{$file}) {
        my $cmd = $PRESCRIPT{$file};
        ssm_print qq(RUNNING: $cmd\n);
        run_cmd($cmd);
    }

    return 1;
}

sub do_postscript {

    my $file = shift;

    if($POSTSCRIPT{$file}) {
        my $cmd = $POSTSCRIPT{$file};
        ssm_print qq(RUNNING: $cmd\n);
        run_cmd($cmd);
    }

    return 1;
}


sub create_directory {

    my $file = shift;

    ssm_print "FIXING:  Creating: $file\n";

    do_prescript($file);

    if(-e $file) { remove_file($file); }

    eval { mkpath($file) };
    if($@) {
        die "Couldn’t create $file: $@";
    }

    set_ownership_and_permissions($file);

    do_postscript($file);

    return 1;
}


sub install_file {

    my $file     = shift;
    my $tmp_file = shift;

    ssm_print "FIXING:  Installing: $file\n";

    do_prescript($file);

    _backup($file);

    my $url;
    if( !defined($tmp_file) ) {
        $url = qq($main::o{base_url}/$file/$MD5SUM{$file});
        $tmp_file = get_file($url);
    }

    remove_file($file);
    copy($tmp_file, $file) or die "Failed to copy($tmp_file, $file): $!";
    unlink $tmp_file;

    set_ownership_and_permissions($file);

    do_postscript($file);

    return 1;
}


#
# my $tmp_file = get_file($file);
#
sub get_file {

    # copies $file, from wherever, to a temporary file name
    # returns that temporary file name

    my $file = shift;

    my $tmp_file = choose_tmp_file();

    # remove multiple slashes anywhere but after a protocol specifier
    $file =~ s#([^:/])/+#$1/#g;

    if( ($file =~ m#^file://#) or ($file =~ m#^/#) ) {

        $file =~ s#file://#/#;
        $file =~ s/(\s+|#).*//;
        if( ! -e $file ) {
            ssm_print "ERROR: $file doesn't exist...\n";
            ssm_print "\n";
            exit 1;
        }
        copy($file, $tmp_file) or die "get_file(): Failed to copy($file, $tmp_file): $!";

    } 
    elsif($file =~ m#^http://#) {
        #
        # Use a pure perl implementation
        #
        my $content;
        if( defined($content = get($file)) ) {
            open(FILE,">$tmp_file") or die("Couldn't open $tmp_file for writing!\n");
            print FILE $content;
            close(FILE);

        } else {
            ssm_print "WARNING: Failed to retrieve $file.\n";
            ssm_print "  Skipping this step.\n";
            $ERROR_LEVEL++;  if($main::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }
            sleep 1;
        }

    } elsif( ($file =~ m#^https://#) or ($file =~ m#^ftp://#) ) {

        my $cmd = "wget -q $file -O $tmp_file";
        run_cmd($cmd);

    } else {

        ssm_print "I don't know how to acquire a file using the specified protocol:\n";
        ssm_print "  $file\n";
        ssm_print "\n";
        ssm_print "  You may want to verify that you have a valid 'base_url' specified\n";
        ssm_print "  in your definition file.\n";
        ssm_print "\n";

        exit 1;
    }

    return $tmp_file;
}


#
# my $tmp_file = choose_tmp_file();
#
sub choose_tmp_file {

    my $count = 0;
    my $file = "/tmp/system-state-manager_tmp_file";

    while( -e "$file.$count" ) {
        $count++;
    }
    $file = "$file.$count";

    umask 0077;
    open(FILE,">$file") or die "Couldn't open $file for writing $!";
        print FILE "I am a little tmp file created by System State Manager.\n";
    close(FILE);
    
    return $file;
}


sub do_hardlink {

    my $file   = shift;

    #
    # validate input
    unless( 
                defined($file)          and ($file          =~ m#^/#)
            and defined($TARGET{$file}) and ($TARGET{$file} =~ m#^/#)
            and defined($TYPE{$file})   and ($TYPE{$file}   =~ m/\S/)
    ) {
        return report_improper_file_definition($file);
    }

    #
    # Does it need fixing?
    my $needs_fixing = undef;
    if( ! -e $TARGET{$file} ) {

        # Target ain't there
        ssm_print "WARNING: Hard link $file -> $TARGET{$file} (target doesn't exist).\n";
        ssm_print "  Skipping this step.\n";
        $ERROR_LEVEL++;  if($main::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }
        sleep 1;

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
    my $fix_it = undef;
    if( defined($needs_fixing) ) {

        ssm_print "Not OK:  Hard link $file -> $TARGET{$file}\n";
        ssm_print "         Need to:\n";
        ssm_print "         - $PRESCRIPT{$file}\n" if($PRESCRIPT{$file});
        ssm_print "         - remove $file\n" if( -e $file );
        ssm_print "         - create link\n";
        ssm_print "         - $POSTSCRIPT{$file}\n" if($POSTSCRIPT{$file});

        if($main::o{yes}) {
            $fix_it = 1;
        } elsif($main::o{answer_no}) {
            $fix_it = undef;
            $ERROR_LEVEL++;  if($main::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }
        } else {

            ssm_print "         Shall I do this? [N/y]: ";

            if( do_you_want_me_to() eq 'yes' ) { 
                $fix_it = 1;
            } else {
                ssm_print "         Ok, skipping this step.\n";
                $ERROR_LEVEL++;  if($main::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }
                sleep 1;
            }
        }
    } else {
        ssm_print "OK:      Hard link $file -> $TARGET{$file}\n";
    }

    #
    # Take action
    if( defined($fix_it) and ! $main::o{answer_no} ) {

        $CHANGES_MADE++;
        ssm_print "FIXING:  Hard link $file -> $TARGET{$file}\n";

        do_prescript($file);

        remove_file($file);
        link($TARGET{$file}, $file) or die "Couldn't link($TARGET{$file}, $file) $!";
        #
        #XXX
        #   Should we accept and use owner, group, and mode info for hardlinks?
        #
        #   If perms and ownership are changed on a hardlink, they are 
        #   changed for the file itself, and this is reflected by all
        #   names (links) for the file.

        do_postscript($file);
    }

    return 1;
}


sub user_is_root {

    if($< == 0) { return 1; }
    return undef;
}

sub report_improper_service_definition {

    my $name = shift;
    
    ssm_print "\n";
    ssm_print "Improper [service] definition.  Here's what I know about it:\n";
    ssm_print "  name   = $name\n";

    if(defined($DETAILS{$name})) { ssm_print "  mode   = $DETAILS{$name}\n";
                          } else { ssm_print "  mode   =\n"; }

    if(defined($DEPENDS{$name})) { ssm_print "  depends   = $DEPENDS{$name}\n";
                          } else { ssm_print "  depends   =\n"; }

    ssm_print "\n";
    ssm_print "  Skipping entry and incrementing ERROR_LEVEL...\n";
    ssm_print "\n";

    $ERROR_LEVEL++;
    if($main::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }

    sleep 1;

    return 1;
}


sub report_improper_file_definition {

    my $file = shift;
    
    ssm_print "\n";
    ssm_print "Improper [file] definition.  Here's what I know about it:\n";
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
    if($main::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }

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

#
#   add_file_to_repo(@ARGV);
#
sub add_file_to_repo {

    my @chunks = @_;

    if(! defined $LOGFILE) {
        #
        # If we are invoked independently via ssm_add-file, the log 
        # file won't be initialized yet. -BEF-
        _initialize_log_file();
    }

    ####################################################################
    #
    # Validate input
    #
    if( ! -d $main::o{ou_path} ) {
        ssm_print "\n";
        ssm_print "The OU directory you specified does not exist:\n";
        ssm_print "  $main::o{ou_path}\n";
        ssm_print "\n";
        ssm_print "  Please create it first, set access privileges for it,\n";
        ssm_print "  then try again.\n";
        ssm_print "\n";
        exit 1;
    }

    foreach(@chunks) {
        if( ! -e $_ ) {
            ssm_print "CHUNK $_ doesn't appear to exist.\n";
            ssm_print "\n";
            exit 1;
        }
    }
    #
    ####################################################################

    # Create the base dir
    my $dir = $main::o{ou_path} . '/' . $main::o{file_to_add};
    eval { mkpath($dir) };
    if($@) {
        ssm_print "Couldn’t create $dir: $@";
    }

    my $tmp_file = choose_tmp_file();
    open(TMP, "+>$tmp_file") or die "Couldn't open tmp file $!";

        ssm_print "Concatenating files...\n";
        foreach my $file (@chunks) {
            ssm_print "CHUNK: $file\n" if($main::o{debug});
            open(FILE,"<$file") or die "Couldn't open $file for reading $!";
                print TMP <FILE>;
            close(FILE);
        }

        ssm_print "Calculating md5sum...\n";
        seek(TMP, 0, 0);
        my $md5sum = Digest::MD5->new->addfile(*TMP)->hexdigest;

        my $file = $dir . '/' . $md5sum;
        $file =~ s#/+#/#g;

    close(TMP);

    ssm_print "Moving target file into place:\n";
    ssm_print "  $file\n";
    move($tmp_file, $file) or die "Couldn't move($tmp_file, $file) $!";
    chmod oct(644), $file;

    $main::o{comment} = localtime() . " | " . $main::o{comment};

    my $st = stat($chunks[0]);
    my $mode  = sprintf "%04o", $st_mode & 07777;
    my $owner = (getpwuid $st_uid)[0];
    my $group = (getgrgid $st_gid)[0];

    ssm_print "\n";
    ssm_print "Here's an entry you can cut and paste into your state definition\n";
    ssm_print "file.  Be sure to verify the owner, group, and mode values\n";
    ssm_print "------------------------------------------------------------------------\n";
    ssm_print "\n";
    ssm_print "[file]\n";
    ssm_print "name       = $main::o{file_to_add}\n";
    ssm_print "comment    = $main::o{comment}\n";
    ssm_print "type       = regular\n";
    ssm_print "md5sum     = $md5sum\n";
    ssm_print "owner      = $owner\n";
    ssm_print "group      = $group\n";
    ssm_print "mode       = $mode\n";
    ssm_print "#priority   = 0\n";
    ssm_print "#depends   = \n";
    ssm_print "#prescript  = \n";
    ssm_print "#postscript = \n";
    ssm_print "\n";

    return 1;
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


sub check_depends {

    my $name = shift;
    if(! defined $TYPE{$name}) {
        ssm_print ">> name: $name\n" if( $main::o{debug} );
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

    if( $main::o{debug} ) { print ">>> Dependencies: $DEPENDS{$name}\n"; }
    
    #
    # Only check for pkgs if there's a pkg in the dependency list.  pkg
    # checking is an expensive process. -BEF-
    if($DEPENDS{$name} =~ m/(^|\s)\w/ ) {    # Match package names in the list
        %pkgs_currently_installed = get_pkgs_currently_installed();
    } 

    foreach( split(/\s+/, $DEPENDS{$name}) ) {
        if( /^\// ) {
            #
            # Must be a file.  If it doesn't exist, fail dep check.
            if( ! -e $_) { $unsatisfied .= "$_ "; }

        } else {
            #
            # Must be a package.  See if it's installed.
            if( ! defined $pkgs_currently_installed{$_} ) { $unsatisfied .= "$_ "; }
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

    my @array;

    chomp($file);
    ssm_print "Bundle:  $file\n" unless(@{$main::o{only_this_file}});

    # For --analyze-config purposes, prefix the input data from this
    # bundle file with it's own name as a BundleFile. -BEF-
    push @array, "\n";
    push @array, "BundleFile: $file\n";
    push @array, "\n";

    unless(($file =~ m#^file://#) 
        or ($file =~ m#^/#)
        or ($file =~ m#^http://#) 
        or ($file =~ m#^https://#) 
        or ($file =~ m#^ftp://#)) {

        $file = $main::o{base_url} . '/' . $file;
    }

    my $tmp_file = get_file($file);

    open(FILE,"<$tmp_file") or die "Couldn't open $tmp_file for reading: $!";
        push @array, (<FILE>);
    close(FILE);
    unlink $tmp_file;

    #
    # Now add a blank line at the end of the array... -BEF-
    push( @array, "\n" );

    return @array;
}

sub _backup {

    my $file = shift;

    if( ! -e "/usr/bin/bu" ) { return 1; }
    if( ! -e $file ) { return 1; }

    my $cmd = "bu $file";
    !system($cmd) or die("FAILED: $cmd\n $!");

    return 1;
}


sub _add_file {

    my $file = shift;
    my $ou_path = "/tmp/ssm_db.repo.$$";

    eval { mkpath("$ou_path") };
    if($@) { die "Couldn’t create $ou_path: $@"; }

    my $dirname = $file;

    ssm_print qq(\n);
    if(defined $main::o{git_url}) {

#        #
#        # Ok -- we want to check out as little of the tree as possible.  Let's
#        # try to figure out how minimalistic our checkout can be (by finding
#        # the longest possible path)...  In other words, rather than checking
#        # out all of "/opt", let's see if we can just check out
#        # "/opt/corp/bloated_prog/etc/". -BEF-
#        #
#        my $success = 'lacking';
#        until($success eq 'yes') {
#
#            my $url = $main::o{svn_url} . "/" . $dirname;
#            my $cmd = "git status -s $url >/dev/null 2>&1";
#            if( $main::o{debug} ) { print ">> $cmd\n"; }
#            if( !system($cmd) ) {
#                $success = 'yes';  # I'm so excited!
#            } else {
#                $dirname = dirname($dirname);
#            }
#        }
#
#        #
#        # Ok, we now now that $dirname is the logest path (most minimal
#        # checkout), let's check it out. -BEF-
#        #

        #
        # We'll figure out how to do a minimalist checkout later...  For now,
        # we clone the whole schmear.
        #
        my $cmd = qq(git clone $main::o{git_url}/ $ou_path/);
        ssm_print qq(>> $cmd\n);
        !system($cmd) or die("Couldn't run: $cmd");

        my $hostname = `hostname -f`;
        chomp $hostname;
        my $comment = "$file on $hostname";

        $main::o{comment} = $comment;
        $main::o{ou_path} = $ou_path;
        $main::o{file_to_add} = $file;

        add_file_to_repo($file);

        my $pwd = (getpwuid($<))[1];

        #
        # Jump into the git repo dir
        #
        chdir $ou_path;

        #
        # Turn file into a relative path name
        #
        $file =~ s#^/##;
        $cmd = qq(git add $file);
        ssm_print qq(>> $cmd\n);
        !system($cmd) or die("Couldn't run: $cmd");
        ssm_print "\n";

        $cmd = qq(git commit -m "$comment" $file);
        ssm_print qq(>> $cmd\n);
        !system($cmd) or die("Couldn't run: $cmd");
        ssm_print "\n";

        #
        # Jump back to our prior dir
        #
        chdir $pwd;

    }
    elsif(defined $main::o{svn_url}) {

        my $svn     = qq(svn);

        my $success = 'lacking';
        until($success eq 'yes') {

            my $url = $main::o{svn_url} . "/" . $dirname;
            my $cmd = "$svn info $url 2>&1";
            if( $main::o{debug} ) { print ">> $cmd\n"; }

            open(INPUT,"$cmd|") or die("Couldn't $cmd");
            while(<INPUT>) {
                if( $main::o{debug} ) { print ">>> $_\n"; }
                if(m/^URL: /) { 
                    $success = 'yes'; 
                }
            }
            close(INPUT);

            $dirname = dirname($dirname) if($success eq 'lacking');
        }

        my $cmd = qq($svn checkout $main::o{svn_url}/$dirname $ou_path/$dirname);
        ssm_print qq(>> $cmd\n);
        !system($cmd) or die("Couldn't run: $cmd");

        my $hostname = `hostname -f`;
        chomp $hostname;
        my $comment = "$file on $hostname";

        $main::o{comment} = $comment;
        $main::o{ou_path} = $ou_path;
        $main::o{file_to_add} = $file;
        add_file_to_repo($file);

        my $pwd = (getpwuid($<))[1];
        $cmd = qq($svn stat $ou_path/$dirname);
        ssm_print qq(>> $cmd\n);
        open(INPUT, "$cmd|") or die $!;
            while(<INPUT>) {
                chomp;
                s/\S+\s+//;

                $cmd = qq(svn add "$_");
                ssm_print qq(>> $cmd\n);
                !system($cmd) or die("Couldn't run: $cmd");
                ssm_print "\n";
            }
        close(INPUT);

        $file =~ s#^/##;

        $cmd = qq($svn commit -m "$comment" $ou_path/$dirname);
        ssm_print qq(>> $cmd\n);
        !system($cmd) or die("Couldn't run: $cmd");
        ssm_print "\n";

        # Unlink that pesky subversion password cache
        my $cache = "$ENV{HOME}/.subversion/auth/svn.simple/f5066f0fa2dd7dca29c1963bb17227e0";
        if( $main::o{debug} ) { print "unlink $cache\n"; }
        unlink $cache;

    } else {

        _try_a_revision_system();

        $ERROR_LEVEL++;
        if($main::o{debug}) { ssm_print "ERROR_LEVEL: $ERROR_LEVEL\n"; }
        ssm_print "\n";
        exit $ERROR_LEVEL;
    }


    if(defined $main::o{git_url}) {
        ssm_print qq(Be sure to do a "git pull" against $ou_path on this machine to\n);
        ssm_print qq(incorporate these changes in the master repo...\n\n);
        #XXX should we do this automatically?
    }

    # Config chunks printed to the screen...
    ssm_print <<"EOF";
  Please take a moment to add the above config chunks to the appropriate
  state definition file or bundle, and to commit your changes.  You may
  want to open another terminal to do these things.

  Hit <Enter> to continue...
EOF

    $_ = <STDIN>;

    return 1;
}


#   Example:
#
#   my $file = "/tmp/$progname.log";
#   my $ending_lognumber    = 7;
#   my $starting_lognumber  = 1;
#   rotate_log_file($file, $starting_lognumber, $ending_lognumber);
#
sub rotate_log_file {

    if( $main::o{debug} ) { print "rotate_log_file()\n"; }

    my $file                = shift;
    my $starting_lognumber  = shift;
    my $ending_lognumber    = shift;

    my $i = $ending_lognumber;

    until( $i == $starting_lognumber ) {

        my $file_old = "$file." . ($i - 1);
        my $file_new = "$file." . $i;

        if( -e $file_old ) {
            if( $main::o{debug} ) { print " rename($file_old, $file_new)\n"; }
            rename($file_old, $file_new) or die("Couldn't rename $file_old to $file_new");
        }

        $i--;
    }

    my $file_old = $file;
    my $file_new = "$file.$starting_lognumber";

    if( -e $file_old ) {
        if( $main::o{debug} ) { print " rename($file_old, $file_new)\n"; }
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

sub remove_file {

    my $file    = shift;

    my $rm = _which("rm");
    my $cmd = "$rm -fr $file";
    !system($cmd) or die("FAILED: $cmd\n $!");

    return 1;
}

sub compare_package_options {

    if( $main::o{debug} ) { print "compare_package_options()\n"; }

    my $pkg                 = shift;
    my $challenger_options  = shift;

    my $incumbent_options   = $PKGS_FROM_STATE_DEFINITION{$pkg};

    ssm_print ">> pkg: $pkg\n" if( $main::o{debug} );
    ssm_print ">> challenger_options: $challenger_options\n" if( $main::o{debug} );
    ssm_print ">> incumbent_options:  $incumbent_options\n" if( $main::o{debug} );

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
    ssm_print ">> incumbent_priority:  $incumbent_priority\n" if( $main::o{debug} );

    my $challenger_priority;
    if($challenger_options =~ m/\bpriority=(\d+)/i) {
        $challenger_priority = $1;
    } else {
        $challenger_priority = 0;
    }
    ssm_print ">> challenger_priority:  $challenger_priority\n" if( $main::o{debug} );

    if($challenger_priority gt $incumbent_priority) {
        return $challenger_options;
    } else {
        return $incumbent_options;
    }

    exit 6; # if we get down to here -- something went wrong.  -BEF-
}

sub sync_state_remove_packages {
    my @pkgs_to_be_removed = get_pkgs_to_be_removed();
    my @pkgs_to_be_removed_deps;

    my $do_remove = undef;

    if( scalar(@pkgs_to_be_removed) > 0) {

        my %hash;
        my %pkgs_currently_installed = get_pkgs_currently_installed();
        my %reverse_dependencies = get_pkg_reverse_dependencies(@pkgs_to_be_removed);

        #
        # For each package that is not in the definition, and is about
        # to be removed, check to see if it is also listed in the reverse
        # dependencies.  If it is, delete it from the reverse dependencies,
        # as there's no need in having it listed in both places. -BEF-
        foreach my $pkg (@pkgs_to_be_removed) {
            if( defined($reverse_dependencies{$pkg}) ) {
                delete $reverse_dependencies{$pkg};
            }
        }

        #
        # For each of the reverse dependencies, if the package is 
        # currently installed, include it as a package to remove.
        # We don't include other dependencies, as there's no reason
        # to try and remove something that isn't there. -BEF-
        foreach my $pkg (keys %reverse_dependencies) {
            if( defined($pkgs_currently_installed{$pkg}) ) {
                $hash{$pkg} = 1; 
            }
        }
        foreach(keys %hash) {
            push(@pkgs_to_be_removed_deps, $_);
        }

        ssm_print "\n";
        ssm_print "Packages to remove: " . scalar(@pkgs_to_be_removed) . "\n";
        ssm_print "------------------------------------------------------------------------\n";
        foreach(sort @pkgs_to_be_removed) {
            ssm_print "$_\n";
        }
        ssm_print "\n";

        if( scalar(@pkgs_to_be_removed_deps) > 0) {
            ssm_print "Additional packages to remove:  The packages below are defined, but\n";
            ssm_print "depend on the packages being removed above, which are not defined.\n";
            ssm_print "This is generally an indication that you need to update your definition\n";
            ssm_print "file to a) include the packages above, or b) remove the packages below.\n";
            ssm_print "Hope that helps! --TheMgmt\n";
            ssm_print "------------------------------------------------------------------------\n";
            foreach(sort @pkgs_to_be_removed_deps) {
                ssm_print "$_\n";
            }
            ssm_print "\n";
        }
 
        # Find out if the running kernel belongs to a package slated to be
        # removed, and prevent it. -BEF-
        my $dont_remove_anything_as_running_kernel_is_listed = 0;
        my $running_kernel_pkg_name;
        if( $main::o{remove_running_kernel} ne 'yes' ) {
            $running_kernel_pkg_name = get_running_kernel_pkg_name();
            foreach( @pkgs_to_be_removed, @pkgs_to_be_removed_deps ) {
                if( m/$running_kernel_pkg_name/ ) {
                    ssm_print "$_\n" if $main::o{debug};
                    $dont_remove_anything_as_running_kernel_is_listed = 1;
                    last;
                }
            }
        }

        $OUTSTANDING_PACKAGES_TO_REMOVE = scalar(@pkgs_to_be_removed);
        $OUTSTANDING_PACKAGES_TO_REMOVE += scalar(@pkgs_to_be_removed_deps);
        if($dont_remove_anything_as_running_kernel_is_listed eq 1) {
            $do_remove = undef;
            ssm_print "WARNING: Packages -> Not removing -- running kernel is in the list ($running_kernel_pkg_name).\n";
            sleep 1;
        } elsif($main::o{yes}) {
            $do_remove = 1;
        } elsif($main::o{answer_no}) {
            $do_remove = undef;
            ssm_print "WARNING: Packages -> Not removing due to --no option.\n";
            sleep 1;
        } else {
            ssm_print "  Shall I do this? [N/y]: ";
            if( do_you_want_me_to() eq 'yes' ) { 
                $do_remove = 1;
            } else {
                ssm_print "  Ok, skipping this step.\n";
                sleep 1;
            }
        }

    } else {
        ssm_print "OK:      Packages -> No packages to remove.\n";
    }

    if( defined($do_remove) ) {
        $CHANGES_MADE += $OUTSTANDING_PACKAGES_TO_REMOVE;
        $OUTSTANDING_PACKAGES_TO_REMOVE = 0;
        remove_pkgs(@pkgs_to_be_removed, @pkgs_to_be_removed_deps);
    }
}

sub sync_state_upgrade_packages {
    my @pkgs_to_be_upgraded = get_pkgs_that_pkg_manager_says_to_upgrade();
    my @pkgs_to_be_upgraded_deps;

    my $do_upgrade = undef;

    if( scalar(@pkgs_to_be_upgraded) > 0) {

        my %hash;
        my ($dependencies, $erasures) = get_pkg_dependencies(@pkgs_to_be_upgraded);
        foreach $_ (keys %$dependencies) {
            my $already_listed = 'no';

            #
            # Each package may have a series of alternates as dependencies,
            # any one of which will satisfy it's dependency.  Those are
            # stored as the value in %$dependencies separated by spaces. -BEF-
            #
            my @pkg_alternatives = split(/\s+/, $_);
            foreach my $pkg (@pkg_alternatives) {
                if((defined $PKGS_FROM_STATE_DEFINITION{$pkg}) or (defined $PKGS_PROVIDED_BY_PKGS_FROM_STATE_DEFINITION{$pkg})) {
                    $already_listed = 'yes';
                }
            }
            if($already_listed eq 'no') {
                #
                # If we find that a package has a dependency that is not in it's state
                # definition, then we add it to the list of dependencies of packages to
                # be upgraded.  If there are alternates, we just take the first one. -BEF-
                $hash{$pkg_alternatives[0]} = 1;
            }
        }
        foreach(keys %hash) {
            push(@pkgs_to_be_upgraded_deps, $_);
        }

        my @pkgs_to_be_auto_removed;
        foreach $_ (keys %$erasures) {
            push(@pkgs_to_be_auto_removed, $_);
        }

        ssm_print "\n";
        ssm_print "Packages to upgrade: " . scalar(@pkgs_to_be_upgraded) . "\n";
        ssm_print "------------------------------------------------------------------------\n";
        foreach(sort @pkgs_to_be_upgraded) {
            ssm_print "$_\n";
        }
        ssm_print "\n";

        if( scalar(@pkgs_to_be_upgraded_deps) > 0) {
            ssm_print "Additional packages to install:  The packages below are not defined,\n";
            ssm_print "but are dependencies of the packages above, which are defined.  This is\n";
            ssm_print "generally an indication that you need to update your definition file to\n";
            ssm_print "a) include the packages below, or b) remove the packages above.\n";
            ssm_print "Hope that helps! --TheMgmt\n";
            ssm_print "------------------------------------------------------------------------\n";
            foreach(sort @pkgs_to_be_upgraded_deps) {
                ssm_print "$_\n";
            }
            ssm_print "\n";
        }

        if( scalar(@pkgs_to_be_auto_removed) > 0) {
            ssm_print "Packages to be removed:  The packages below are defined, but one or more\n";
            ssm_print "of the packages above need them removed to satisfy a dependency.  This\n";
            ssm_print "often happens when a newer version of a package that includes version\n";
            ssm_print "information in the name, such as a kernel package, obsoletes an earlier\n";
            ssm_print "version of the same package.  Generally, the resolution in this case is\n";
            ssm_print "to update your definition file to 1) remove the packages below, and\n";
            ssm_print "2) the next time this program iterates, add the packages from the\n";
            ssm_print "'Packages to remove' section.  Hope that helps! --TheMgmt\n";
            ssm_print "------------------------------------------------------------------------\n";
            foreach(sort @pkgs_to_be_auto_removed) {
                ssm_print "$_\n";
            }
            ssm_print "\n";
        }

        $OUTSTANDING_PACKAGES_TO_UPGRADE = scalar(@pkgs_to_be_upgraded);
        if($main::o{yes}) {
            $do_upgrade = 1;
        } elsif($main::o{answer_no}) {
            $do_upgrade = undef;
            ssm_print "WARNING: Packages -> Not upgrading due to --no option.\n";
            sleep 1;
        } else {
            ssm_print "  Shall I do this? [N/y]: ";
            if( do_you_want_me_to() eq 'yes' ) { 
                $do_upgrade = 1;
            } else {
                ssm_print "  Ok, skipping this step.\n";
                sleep 1;
            }
        }
    } else {
        ssm_print "OK:      Packages -> No packages to upgrade.\n";
    }

    if( defined($do_upgrade) ) {
        $CHANGES_MADE += $OUTSTANDING_PACKAGES_TO_UPGRADE;
        $OUTSTANDING_PACKAGES_TO_UPGRADE = 0;
        upgrade_pkgs(@pkgs_to_be_upgraded, @pkgs_to_be_upgraded_deps);
    }
}

sub sync_state_install_packages {
    my @pkgs_to_be_installed = get_pkgs_to_be_installed();
    my @pkgs_to_be_installed_deps;

    my $do_install = undef;

    if( scalar(@pkgs_to_be_installed) > 0) {

        my %hash;
        my ($dependencies, $erasures) = get_pkg_dependencies(@pkgs_to_be_installed);
        foreach $_ (keys %$dependencies) {
            my $already_listed = 'no';

            #
            # Each package may have a series of alternates as dependencies,
            # any one of which will satisfy it's dependency.  Those are
            # stored as the value in %$dependencies separated by spaces. -BEF-
            #
            my @pkg_alternatives = split(/\s+/, $_);
            foreach my $pkg (@pkg_alternatives) {
                if((defined $PKGS_FROM_STATE_DEFINITION{$pkg}) or (defined $PKGS_PROVIDED_BY_PKGS_FROM_STATE_DEFINITION{$pkg})) {
                    $already_listed = 'yes';
                }
            }
            if($already_listed eq 'no') {
                #
                # If we find that a package has a dependency that is not in it's state
                # definition, then we add it to the list of dependencies of packages to
                # be upgraded.  If there are alternates, we just take the first one. -BEF-
                $hash{$pkg_alternatives[0]} = 1;
            }
        }
        foreach(keys %hash) {
            push(@pkgs_to_be_installed_deps, $_);
        }

        my @pkgs_to_be_auto_removed;
        foreach $_ (keys %$erasures) {
            push(@pkgs_to_be_auto_removed, $_);
        }

        ssm_print "\n";
        ssm_print "Packages to install: " . scalar(@pkgs_to_be_installed) . "\n";
        ssm_print "------------------------------------------------------------------------\n";
        foreach(sort @pkgs_to_be_installed) {
            ssm_print "$_\n";
        }
        ssm_print "\n";

        if( scalar(@pkgs_to_be_installed_deps) > 0) {
            ssm_print "Additional packages to install:  The packages below are not defined,\n";
            ssm_print "but are dependencies of the packages above, which are defined.  This is\n";
            ssm_print "generally an indication that you need to update your definition file to\n";
            ssm_print "a) include the packages below, or b) remove the packages above.\n";
            ssm_print "Hope that helps! --TheMgmt\n";
            ssm_print "------------------------------------------------------------------------\n";
            foreach(sort @pkgs_to_be_installed_deps) {
                ssm_print "$_\n";
            }
            ssm_print "\n";
        }

        if( scalar(@pkgs_to_be_auto_removed) > 0) {
            ssm_print "Packages to be removed:  The packages below are defined, but one or more\n";
            ssm_print "of the packages above need them removed to satisfy a dependency.  This\n";
            ssm_print "often happens when a newer version of a package that includes version\n";
            ssm_print "information in the name, such as a kernel package, obsoletes an earlier\n";
            ssm_print "version of the same package.  Generally, the resolution in this case is\n";
            ssm_print "to update your definition file to 1) remove the packages below, and\n";
            ssm_print "2) the next time this program iterates, add the packages from the\n";
            ssm_print "'Packages to remove' section.  Hope that helps! --TheMgmt\n";
            ssm_print "------------------------------------------------------------------------\n";
            foreach(sort @pkgs_to_be_auto_removed) {
                ssm_print "$_\n";
            }
            ssm_print "\n";
        }

        $OUTSTANDING_PACKAGES_TO_INSTALL = scalar(@pkgs_to_be_installed);
        if($main::o{yes}) {
            $do_install = 1;
        } elsif($main::o{answer_no}) {
            $do_install = undef;
            ssm_print "WARNING: Packages -> Not installing due to --no option.\n";
            sleep 1;
        } else {
            ssm_print "  Shall I do this? [N/y]: ";
            if( do_you_want_me_to() eq 'yes' ) { 
                $do_install = 1;
            } else {
                ssm_print "  Ok, skipping this step.\n";
                sleep 1;
            }
        }

    } else {
        ssm_print "OK:      Packages -> No packages to install.\n";
    }

    if( defined($do_install) ) {
        $CHANGES_MADE += $OUTSTANDING_PACKAGES_TO_INSTALL;
        $OUTSTANDING_PACKAGES_TO_INSTALL = 0;
        install_pkgs(@pkgs_to_be_installed, @pkgs_to_be_installed_deps);
    }
}

sub sync_state_reinstall_packages {
    my @pkgs_to_be_reinstalled = get_pkgs_to_be_reinstalled();
    my $do_reinstall = undef;

    if( scalar(@pkgs_to_be_reinstalled) > 0) {

        ssm_print "\n";
        ssm_print "Packages to re-install: " . scalar(@pkgs_to_be_reinstalled) . "\n";
        ssm_print "------------------------------------------------------------------------\n";
        foreach(@pkgs_to_be_reinstalled) {
            ssm_print "$_\n";
        }

        $OUTSTANDING_PACKAGES_TO_REINSTALL = scalar(@pkgs_to_be_reinstalled);
        if($main::o{yes}) {
            $do_reinstall = 1;
        } elsif($main::o{answer_no}) {
            $do_reinstall = undef;
            ssm_print "WARNING: Packages -> Not re-installing due to --no option.\n";
            sleep 1;
        } else {
            ssm_print "  Shall I do this? [N/y]: ";
            if( do_you_want_me_to() eq 'yes' ) { 
                $do_reinstall = 1;
            } else {
                ssm_print "  Ok, skipping this step.\n";
                sleep 1;
            }
        }
    } else {
        ssm_print "OK:      Packages -> No packages to re-install.\n";
    }

    if( defined($do_reinstall) ) {
        $CHANGES_MADE += $OUTSTANDING_PACKAGES_TO_REINSTALL;
        $OUTSTANDING_PACKAGES_TO_REINSTALL = 0;
        reinstall_pkgs(@pkgs_to_be_reinstalled);
    }
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

sub _try_a_revision_system {
        ssm_print "INFO:  You don't have a git or svn repository specified in the definition\n";
        ssm_print "       file.  Please take a moment to add an entry to your [global] section.\n";
        ssm_print "\n";
        ssm_print "       Here's an example or two:\n";
        ssm_print "\n";
        ssm_print "         git_url = https://my-xcat-master.cluster/repos/ssm_repo/\n";
        ssm_print "         git_url = git://git.example.com/repos/ssm_repo/\n";
        ssm_print "         git_url = ssh://git.example.com/repos/ssm_repo/\n";
        ssm_print "\n";
        ssm_print "         svn_url = https://svn.example.com/repos/ssm_repo/trunk\n";
        ssm_print "\n";
}

#
################################################################################

1;

