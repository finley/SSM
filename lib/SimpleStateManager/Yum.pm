#  
#   Copyright (C) 2006-2014 Brian Elliott Finley
#
#    vi: set et ai ts=4 filetype=perl tw=0 number:
# 

package SimpleStateManager::Yum;

use Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(
		get_pending_pkg_changes
                get_pkgs_that_pkg_manager_says_to_upgrade
                remove_pkgs
                upgrade_pkgs
                install_pkgs
                upgrade_ssm
		update_pkg_availability_data
                get_pkgs_provided_by_pkgs_from_state_definition
                get_pkgs_currently_installed
                get_pkg_dependencies
                get_pkg_reverse_dependencies
                get_running_kernel_pkg_name
            );

use strict;
use SimpleStateManager qw(ssm_print run_cmd choose_tmp_file);


################################################################################
#
#   This package provides the following functions:
#
#       % egrep '^sub ' lib/SimpleStateManager/Yum.pm | perl -pi -e 's/^sub /#   /; s/ {//;' | sort
#
#   get_pkg_dependencies
#   get_pkg_reverse_dependencies
#   get_pkgs_currently_installed
#   get_pkgs_provided_by_pkgs_from_state_definition
#   get_pkgs_that_pkg_manager_says_to_upgrade
#   get_running_kernel_pkg_name
#   install_pkgs
#   remove_pkgs
#   upgrade_pkgs
#   upgrade_ssm
#
#
################################################################################


################################################################################
#
#   Subroutines
#

#
#   my %pending_pkg_changes = get_pending_pkg_changes($action);
#   
#       Where $action is one of 'install', 'remove', or 'upgrade'.
#
sub get_pending_pkg_changes {

    my $action = shift;

    my $timer_start; my $debug_prefix; if( $main::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my %pkgs_already_installed = get_pkgs_currently_installed();

    my $basearch = get_basearch();

    my %space_delimited_pkg_list;
    my %pending_pkg_changes;
#//XXX
    if($action eq 'upgrade') {
        %pending_pkg_changes = do_apt_get_dry_run('dist-upgrade');

    } else {
        foreach my $pkg (keys %::PKGS_FROM_STATE_DEFINITION) {

            my $options = $::PKGS_FROM_STATE_DEFINITION{$pkg};

            if($options =~ m/\bunwanted\b/i) {

                $space_delimited_pkg_list{'remove'}  .= " $pkg";

            } else {

                #
                # If the package is already installed, no need to try and install it
                # again, so skip it.
                #
                next if( $pkgs_already_installed{"$pkg:$basearch"} );
                next if( $pkgs_already_installed{"$pkg"} );

                $space_delimited_pkg_list{'install'}  .= " $pkg";
            }
        }

        %pending_pkg_changes = do_apt_get_dry_run($action, $space_delimited_pkg_list{$action});
    }

    #
    # Help user to make sure they don't try to remove something they want to keep
    #
    foreach my $pkg (sort keys %pending_pkg_changes) {

        if( $pending_pkg_changes{$pkg} eq 'remove' ) {

            if ($::PKGS_TARGET_STATE{$pkg} and ($::PKGS_TARGET_STATE{$pkg} ne 'remove')) {
                ssm_print "WARNING: Package $pkg is now marked as $pending_pkg_changes{$pkg}, but was already marked as $::PKGS_TARGET_STATE{$pkg}\n";

            } elsif ($::PKGS_FROM_STATE_DEFINITION{$pkg} and $::PKGS_FROM_STATE_DEFINITION{$pkg} !~ m/\bunwanted\b/i ) {
                ssm_print "WARNING: Package $pkg is now marked as $pending_pkg_changes{$pkg}, but is marked for install in the config.\n";
            }

        } else {
            $::PKGS_TARGET_STATE{$pkg} = $pending_pkg_changes{$pkg};
        }
    }

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; sleep 2; }

    return %pending_pkg_changes;
}


sub get_basearch {

    my $timer_start; my $debug_prefix; if( $main::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my $basearch = `rpm -q --qf "%{arch}" -f /`;
    chomp $basearch;

    ssm_print "$debug_prefix $basearch\n" if( $main::o{debug} );

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; sleep 2; }

    return $basearch;
}


sub update_pkg_availability_data {

    my $timer_start; my $debug_prefix; if( $main::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    if( $::o{no_pkg_repo_update} ) {
        ssm_print "INFO:    Not updating package repo info\n";
        return 1;
    }

    #
    # Get the latest updates
    my $cmd = 'yum check-update >/dev/null';
    #
    # Run even if --no so that we don't get 'Unable to locate package X'
    # errors. -BEF-
    run_cmd($cmd, undef, 1);

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; sleep 2; }

    return 1;
}

sub remove_pkgs {
    ssm_print ">>\n>> remove_pkgs()\n" if( $main::o{debug} );

    my @packages = @_;

    my $file = choose_tmp_file();
    open(FILE,">$file") or die("Couldn't open $file for writing");
    foreach my $pkg (@packages) {
        print FILE "remove $pkg\n";
    }
    print FILE "transaction run\n";
    print FILE "exit\n";
    close(FILE);
    my $cmd = "yum -y -C shell $file";
    ssm_print ">> $cmd\n" if( $main::o{debug} );
    ssm_print "FIXING:  Packages -> Removing.\n";
    run_cmd($cmd);

    unlink($file);

    return 1;
}

#XXX is this the right thing to do?  Just an "yum update"?
sub upgrade_pkgs {
    ssm_print ">>\n>> upgrade_pkgs()\n" if( $main::o{debug} );

    my @packages = @_;

    if(scalar(@packages) eq 0) { return 1; }

    ssm_print "FIXING:  Packages -> Upgrading.\n";

    my $file = choose_tmp_file();
    open(FILE,">$file") or die("Couldn't open $file for writing");
    print FILE "update\n";
    print FILE "run\n";
    print FILE "exit\n";
    close(FILE);
    my $cmd = "yum -y shell $file";
    ssm_print ">>   $cmd\n" if( $main::o{debug} );
    run_cmd($cmd);

    unlink($file);

    return 1;    
}


sub install_pkgs {
    ssm_print ">>\n>> install_pkgs()\n" if( $main::o{debug} );

    my @packages = @_;

    if(scalar(@packages) eq 0) { return 1; }

    ssm_print "FIXING:  Packages -> Installing.\n";

    my $file = choose_tmp_file();
    open(FILE,">$file") or die("Couldn't open $file for writing");
    foreach my $pkg (@packages) {
        print FILE "install $pkg\n";
    }
    print FILE "run\n";
    print FILE "exit\n";
    close(FILE);
    my $cmd = "yum -y shell $file";
    ssm_print ">>   $cmd\n" if( $main::o{debug} );
    run_cmd($cmd);

    unlink($file);

    return 1;    
}


sub get_pkgs_that_pkg_manager_says_to_upgrade {

    my $timer_start; my $debug_prefix; if( $main::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    # In this hash, 'pkg' is the key, and 'version' is the value.
    my %hash;
    my $cmd;

    #
    # Get a list of packages that would be upgraded
    $cmd = 'yum check-update --cacheonly';
    ssm_print ">> $cmd\n" if( $main::o{debug} );

    #
    # This is harmless, so we run it even if --dry-run, so that we get
    # the output that is interesting for the rest of the dry run.
    #
    # Example output:                                                          Note - spaces here
    #                                                                          vvvvvvvvvvvvvvvvvv
    #   cups.x86_64                              1:1.2.4-11.18.el5_2.2  updates         
    #   cups-libs.x86_64                         1:1.2.4-11.18.el5_2.2  updates         
    #   dhcpv6-client.x86_64                     1.0.10-4.el5_2.3       updates         
    #   kernel.x86_64                            2.6.18-92.1.13.el5     updates         
    #   kernel-devel.x86_64                      2.6.18-92.1.13.el5     updates         
    #   kernel-headers.x86_64                    2.6.18-92.1.13.el5     updates         
    #   tzdata.noarch                            2008f-3.el5            updates         
    #
    open(OUTPUT,"$cmd|");
        while(<OUTPUT>) {
            if( m/^(\S+)\s+\d\S+-\d(\s+|\S+)\s+\S+/ ) {
                ssm_print "$debug_prefix  $1\n" if( $main::o{debug} );
                $hash{$1} = 1;
            }
        }
    close(OUTPUT);

    return (keys %hash);
}


sub upgrade_ssm {

    my $pkg = 'ssm.noarch';

    my @pkgs_to_be_upgraded = get_pkgs_that_pkg_manager_says_to_upgrade();
    foreach(@pkgs_to_be_upgraded) {

        if($_ eq $pkg) {

            ssm_print "FIXING:  Upgrading $pkg\n";
            install_pkgs($pkg);

            my $cmd = $main::o{invocation_command};
            ssm_print "Restarting ssm with: $cmd\n";
            exec($cmd) or die("Couldn't exec $cmd");
        }
    }
    return 1;
}

sub get_pkgs_currently_installed {
    
    my $timer_start; my $debug_prefix; if( $main::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    #
    # returns a hash: package => version
    #

    my %hash;

    if( $main::o{pkg_manager} eq 'yum' ) {

        my $cmd = 'rpm -qa --queryformat "%{NAME}.%{ARCH}\t%{VERSION}\tinstalled\n"';
        ssm_print "$debug_prefix system($cmd)\n" if( $main::o{debug} );
        open(FILE,"$cmd|") or die("couldn't open $cmd for reading");
        while (<FILE>) {
    
                #
                # Only choose packages marked as installed
                #
                # Sample output:
                #
                #   e2fsprogs.x86_64        1.39-8.el5      installed       
                #   e2fsprogs-libs.i386     1.39-8.el5      installed       
                #   e2fsprogs-libs.x86_64   1.39-8.el5      installed       
                #   ed.x86_64               0.2-38.2.2      installed       
                #   eject.x86_64            2.1.5-4.2.el5   installed       
                #   elfutils-libelf.x86_64  0.125-3.el5     installed       
                #   elinks.x86_64           0.11.1-5.1.el5  installed       
                #   ethtool.x86_64          5-1.el5         installed       
                #   expat.i386              1.95.8-8.2.1    installed       
                #   expat.x86_64            1.95.8-8.2.1    installed  
                #
                my ($pkg, $version, $state) = split;
                if( $state eq 'installed' ) {
                    # 
                    # RPM can import GPG keys to validate signatures on
                    # packages.  But why, oh why, Red Hat, do these
                    # imported keys show up as packages with an 
                    # 'rpm --qa' ?!?!?!!!!!  Argh...  
                    #
                    # This skips over them. -BEF-
                    next if($pkg =~ m/^gpg-pubkey\.\(none\)$/);
                    $hash{$pkg} = $version;
                    ssm_print "$debug_prefix $pkg = $version\n" if( $main::o{debug} );
                }
        }
        close(FILE);
    }

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; sleep 2; }

    return %hash;
}


sub get_pkgs_provided_by_pkgs_from_state_definition {
    ssm_print ">>\n>> get_pkgs_provided_by_pkgs_from_state_definition()\n" if( $main::o{debug} );

    my $PKGS_FROM_STATE_DEFINITION = shift;
    return %$PKGS_FROM_STATE_DEFINITION;
}

#
# Returns a hash of packages, with the package names as the keys.
#
# NOTE:  If there are alternates as dependencies, all alternates are returned
#        as the a key in a space seperated string format. -BEF-
#
sub get_pkg_dependencies {
    ssm_print ">>\n>> get_pkg_dependencies()\n" if( $main::o{debug} );

    my @packages = @_;

    my %dependencies;
    my %erasures;

    my $file = choose_tmp_file();
    open(FILE,">$file") or die("Couldn't open $file for writing");
    print FILE "install";
    foreach my $pkg (@packages) {
        print FILE " $pkg";
    }
    print FILE "\n";
    print FILE "transaction solve\n";
    print FILE "exit\n";
    close(FILE);
    my $cmd = "yum shell $file 2>&1";
    ssm_print ">>   $cmd\n" if( $main::o{debug} );

    open(OUTPUT,"$cmd|") or die;
        while(<OUTPUT>) {
            chomp;
            #
            # Output looks like:
            #   --> Running transaction check
            #   ---> Package nss-tools.x86_64 0:3.12.1.1-1.el5.centos.1 set to be updated
            #   ---> Package kernel.x86_64 0:2.6.18-92.1.1.el5 set to be installed
            #   ---> Package krb5-libs.x86_64 0:1.6.1-25.el5_2.1 set to be updated
            #   ---> Package krb5-workstation.x86_64 0:1.6.1-25.el5_2.1 set to be updated
            #   ---> Package kernel-headers.x86_64 0:2.6.18-92.1.13.el5 set to be updated
            #   ---> Package tzdata.noarch 0:2008f-3.el5 set to be updated
            #   ---> Package pam_krb5.x86_64 0:2.2.14-1.el5_2.1 set to be updated
            #   ---> Package cups-libs.x86_64 1:1.2.4-11.18.el5_2.2 set to be updated
            #   ---> Package kernel-devel.x86_64 0:2.6.18-92.1.1.el5 set to be installed
            #   ---> Package kernel.x86_64 0:2.6.18-92.1.13.el5 set to be installed
            #   ---> Package nss.x86_64 0:3.12.1.1-1.el5.centos.1 set to be updated
            #   ---> Package pam_krb5.i386 0:2.2.14-1.el5_2.1 set to be updated
            #   ---> Package kernel-devel.x86_64 0:2.6.18-92.1.13.el5 set to be installed
            #   ---> Package initscripts.x86_64 0:8.45.19.1.EL-1.el5.centos set to be updated
            #   ---> Package nss.i386 0:3.12.1.1-1.el5.centos.1 set to be updated
            #   ---> Package libtiff.x86_64 0:3.8.2-7.el5_2.2 set to be updated
            #   ---> Package dhcpv6-client.x86_64 0:1.0.10-4.el5_2.3 set to be updated
            #   ---> Package krb5-libs.i386 0:1.6.1-25.el5_2.1 set to be updated
            #   ---> Package cups.x86_64 1:1.2.4-11.18.el5_2.2 set to be updated
            #   --> Finished Dependency Resolution
            #   --> Running transaction check
            #   ---> Package nss-tools.x86_64 0:3.12.1.1-1.el5.centos.1 set to be updated
            #   ---> Package kernel.x86_64 0:2.6.18-92.1.1.el5 set to be installed
            #   ---> Package krb5-libs.x86_64 0:1.6.1-25.el5_2.1 set to be updated
            #   ---> Package krb5-workstation.x86_64 0:1.6.1-25.el5_2.1 set to be updated
            #   ---> Package kernel-headers.x86_64 0:2.6.18-92.1.13.el5 set to be updated
            #   ---> Package tzdata.noarch 0:2008f-3.el5 set to be updated
            #   ---> Package pam_krb5.x86_64 0:2.2.14-1.el5_2.1 set to be updated
            #   ---> Package cups-libs.x86_64 1:1.2.4-11.18.el5_2.2 set to be updated
            #   ---> Package kernel-devel.x86_64 0:2.6.18-92.1.1.el5 set to be installed
            #   ---> Package kernel.x86_64 0:2.6.18-92.1.13.el5 set to be installed
            #   ---> Package nss.x86_64 0:3.12.1.1-1.el5.centos.1 set to be updated
            #   ---> Package pam_krb5.i386 0:2.2.14-1.el5_2.1 set to be updated
            #   ---> Package kernel-devel.x86_64 0:2.6.18-92.1.13.el5 set to be installed
            #   ---> Package initscripts.x86_64 0:8.45.19.1.EL-1.el5.centos set to be updated
            #   ---> Package nss.i386 0:3.12.1.1-1.el5.centos.1 set to be updated
            #   ---> Package libtiff.x86_64 0:3.8.2-7.el5_2.2 set to be updated
            #   ---> Package dhcpv6-client.x86_64 0:1.0.10-4.el5_2.3 set to be updated
            #   ---> Package krb5-libs.i386 0:1.6.1-25.el5_2.1 set to be updated
            #   ---> Package cups.x86_64 1:1.2.4-11.18.el5_2.2 set to be updated
            #   ---> Package kernel-devel.x86_64 0:2.6.18-53.1.21.el5 set to be erased
            #   ---> Package kernel.x86_64 0:2.6.18-53.1.21.el5 set to be erased
            #   --> Finished Dependency Resolution
            #
            # So, we need to produce two sets of results (set to be updated -- such packages
            # should already be in the 'To be upgraded' listing):
            #   dependencies    -> m/set to be installed/ 
            #   erasures        -> m/set to be erased/ 
            if(m/\s+Package\s+(\S+)\s+\S+\s+set to be installed/) {
                $dependencies{$1} = 1;   
            }
            elsif(m/\s+Package\s+(\S+)\s+\S+\s+set to be updated/) {
                # Sometimes a packages is 'set to be updated', but is
                # not yet installed.  Go figure... -BEF-
                $dependencies{$1} = 1;   
            }
            elsif(m/\s+Package\s+(\S+)\s+\S+\s+set to be erased/) {
                $erasures{$1} = 1;   
            }
        }
    close(OUTPUT);
    unlink($file);

    # Dependencies and erasures that are the packages we're getting dependencies for
    # don't count.  Remove 'em.
    #
    # Ok, what's really going on here.  We'll, rather than try to explain it,
    # in the output above, search for /kernel\./ as an example. -BEF-
    foreach my $pkg (@packages) {
        if(defined $dependencies{$pkg}) { delete $dependencies{$pkg}; }
        if(defined $erasures{$pkg})     { delete $erasures{$pkg};     }
    }

    if( $main::o{debug} ) {
        foreach(sort keys %dependencies) {
            ssm_print ">>   Dependency: $_\n";
        }
        foreach(sort keys %erasures) {
            ssm_print ">>   Erasure: $_\n";
        }
    }
    return (\%dependencies, \%erasures);
}


sub get_pkg_reverse_dependencies {
    ssm_print ">>\n>> get_pkg_reverse_dependencies()\n" if( $main::o{debug} );

    my @packages = @_;

    my %reverse_dependencies;

    #
    # Find the reverse dependencies -- packages that depend on the package we're
    # considering removing.
    #
    # Yum doesn't have a way to simply ask it this.  But we can invoke the
    # "yum shell" feature, getting it to calculate the result of our potential 
    # transaction without actually doing it.  That way it will show us the 
    # reverse dependency list we're interested in.
    #
    my $file = choose_tmp_file();
    open(FILE,">$file") or die("Couldn't open $file for writing");
    foreach my $pkg (@packages) {
        print FILE "remove $pkg\n";
    }
    print FILE "transaction solve\n";
    print FILE "exit\n";
    close(FILE);
    my $cmd = "yum -C shell $file";
    ssm_print ">> $cmd\n" if( $main::o{debug} );

    open(OUTPUT,"$cmd|") or die;
    while(<OUTPUT>) {
        chomp;
        #
        # Output looks like:
        #
        #   Setting up Yum Shell
        #   > Setting up Remove Process
        #   Loading mirror speeds from cached hostfile
        #    * base: mirror.centos.org
        #    * updates: mirror.centos.org
        #    * addons: mirror.centos.org
        #    * extras: mirror.centos.org
        #   > --> Running transaction check
        #   ---> Package popt.x86_64 0:1.10.2-48.el5 set to be erased
        #   --> Processing Dependency: libpopt.so.0()(64bit) for package: util-linux
        #   --> Processing Dependency: libpopt.so.0()(64bit) for package: passwd
        #   --> Processing Dependency: libpopt.so.0()(64bit) for package: ntsysv
        #   [snip]
        #   --> Processing Dependency: popt = 1.10.2 for package: rpm
        #   --> Running transaction check
        #   ---> Package ntsysv.x86_64 0:1.3.30.1-2 set to be erased
        #   --> Processing Dependency: ntsysv for package: firstboot-tui
        #   ---> Package rpm-build.x86_64 0:4.4.2-48.el5 set to be erased
        #   ---> Package GConf2.x86_64 0:2.14.0-9.el5 set to be erased
        #   [snip]
        #   etc...
        #
        # What we want to capture is any "Package" that is "set to be erased".
        #
        if(m/Package\s+(\S+)\s+(\S+)\s+set to be erased/) {
            $reverse_dependencies{$1} = 1;
        }
    }
    close(OUTPUT);

    unlink($file);

    foreach my $pkg (@packages) {
        if(defined $reverse_dependencies{$pkg}) { 
            # We don't need to claim one of the listed packages as a reverse
            # dependency of one of the other listed packages. -BEF-
            delete $reverse_dependencies{$pkg};
        } else {
            ssm_print ">>   $pkg rdeps include $1\n" if( $main::o{debug} );
        }
    }

    return %reverse_dependencies;
}

sub get_running_kernel_pkg_name {

    use POSIX;
    my $release = (uname())[2];

    my $running_kernel_pkg_name = `rpm -qf /lib/modules/${release}/kernel`;
    chomp $running_kernel_pkg_name;
    $running_kernel_pkg_name =~ s/:.*//;

    return $running_kernel_pkg_name;
}

#
################################################################################


1;

