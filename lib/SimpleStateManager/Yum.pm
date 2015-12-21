#  
#   Copyright (C) 2006-2015 Brian Elliott Finley
#
#    vi: set et ai ts=4 filetype=perl tw=0 number:
# 

package SimpleStateManager::Yum;

use Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(
                autoremove_pkgs
                do_pkg_manager_dry_run
                get_pending_pkg_changes
                get_pkgs_provided_by_pkgs_from_state_definition
                get_pkgs_currently_installed
                get_pkg_dependencies
                get_pkg_reverse_dependencies
                get_pkg_repo_update_time_stamp
                get_running_kernel_pkg_name
                install_pkgs
                remove_pkgs
                update_pkg_availability_data
                upgrade_pkgs
            );

use strict;
use SimpleStateManager qw(ssm_print run_cmd choose_tmp_file);


################################################################################
#
#   This package provides the following functions:
#
#       % egrep '^sub ' lib/SimpleStateManager/Yum.pm | perl -pi -e 's/^sub /#   /; s/ {//;' | sort
#
#   autoremove_pkgs
#   do_pkg_manager_dry_run
#   download_pkgs
#   get_basearch
#   get_pending_pkg_changes
#   get_pkg_repo_update_time_stamp
#   get_pkgs_currently_installed
#   get_pkgs_provided_by_pkgs_from_state_definition
#   get_running_kernel_pkg_name
#   install_pkgs
#   remove_pkgs
#   update_pkg_availability_data
#   upgrade_pkgs
#
################################################################################


################################################################################
#
#   Subroutines
#

sub download_pkgs {

    # Requires the package "yum-plugin-downloadonly"
    #my $cmd = 'yum --downloadonly install PKG1 PKG2 ...';
    #run_cmd($cmd, undef, 1);

}

#
#   Usage:  my %hash = do_pkg_manager_dry_run($action, $space_delimited_pkg_list);
#   Usage:  my %hash = do_pkg_manager_dry_run("install", "ash sendmail rsync");
#   Usage:  my %hash = do_pkg_manager_dry_run("remove", "ash sendmail rsync");
#   Usage:  my %hash = do_pkg_manager_dry_run("upgrade");
#   Usage:  my %hash = do_pkg_manager_dry_run("autoremove");
#
#       Returns a hash of $pkg = $pending_state;
#       Where $pending_state may be one of 'install', 'upgrade', 'dist-upgrade', 'autoremove, or 'remove'.
#
sub do_pkg_manager_dry_run {

    my $action                   = shift;
    my $space_delimited_pkg_list = shift;

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my %pending_pkg_changes;

    if(! $space_delimited_pkg_list) {
        if($action eq 'upgrade' or $action eq 'dist-upgrade') {
            #
            # make sure we have some value in this variable to feed the
            # function below...
            $space_delimited_pkg_list = "";

        } else {
            return %pending_pkg_changes;
        }
    }

    #
    # Prep the commands
    my $yumscript = choose_tmp_file();
    open(FILE,">$yumscript") or die("Couldn't open $yumscript for writing");

        if($action eq 'upgrade') {
            print FILE "update\n";
        }
        if($action eq 'autoremove') {
            print FILE "autoremove\n";
        }
        elsif($action eq 'install') {
            print FILE "install $space_delimited_pkg_list\n";
        }
        elsif($action eq 'remove') {
            print FILE "remove $space_delimited_pkg_list\n";
        }

        print FILE "transaction solve\n";

    close(FILE);

    #
    # Run it
    my $cmd = "yum --cacheonly --setopt=assumeyes=False shell $yumscript\n";
    ssm_print "$debug_prefix $cmd\n" if( $::o{debug} );
    open(INPUT,"$cmd|") or die;
    while(<INPUT>) {
        #
        # Input looks like:
        #   [snip]
        #   --> Running transaction check
        #   ---> Package nss-tools.x86_64 0:3.12.1.1-1.el5.centos.1 set to be updated
        #   ---> Package kernel.x86_64 0:2.6.18-92.1.13.el5 set to be installed
        #   ---> Package kernel-devel.x86_64 0:2.6.18-53.1.21.el5 set to be erased
        #   --> Finished Dependency Resolution
        #
        #
        # transaction solve
        # --> Running transaction check
        # ---> Package bu.noarch 0:1.5-1 will be updated
        # ---> Package bu.noarch 0:1.6-1 will be an update
        # --> Finished Dependency Resolution
        #
        if(m/\s+Package\s+(\S+)\s+(\d\S+)\s+.* be (installed|updated|erased)/) {
            my $pkg = $1;
            my $version = $2;
            my $action = $3;

            $version =~ s/\d+://;

            ssm_print "$debug_prefix $pkg $version $action\n" if( $::o{debug} );

            if( $action eq "updated" ) {
                $pending_pkg_changes{$pkg}{action} = 'upgrade';
                $pending_pkg_changes{$pkg}{current_version} = $version;
            } 
            elsif( $action eq "installed" ) {
                $pending_pkg_changes{$pkg}{action} = 'install';
                $pending_pkg_changes{$pkg}{target_version} = $version;
            } 
            elsif( $action eq "erased" ) {
                $pending_pkg_changes{"$pkg $version"}{action} = 'remove';
            } 
        }
        elsif(m/\s+Package\s+(\S+)\s+(\d\S+)\s+.* be an (update)/) {
            my $pkg = $1;
            my $version = $2;
            my $action = $3;

            $version =~ s/\d+://;

            if( $action eq "update" ) {
                $pending_pkg_changes{$pkg}{action} = 'upgrade';
                $pending_pkg_changes{$pkg}{target_version} = $version;
            } 
        }
    }
    close(INPUT);
    unlink($yumscript);

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; sleep 2; }

    return %pending_pkg_changes;
}


#
#   my %pending_pkg_changes = get_pending_pkg_changes($action);
#   
#       Where $action is one of 'install', 'remove', or 'upgrade'.
#
sub get_pending_pkg_changes {

    my $action = shift;

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my %pkgs_already_installed = get_pkgs_currently_installed();

    my $basearch = get_basearch();

    my %space_delimited_pkg_list;
    my %pending_pkg_changes;

    if($action eq 'upgrade') {
        %pending_pkg_changes = do_pkg_manager_dry_run($action);

    } elsif($action eq 'autoremove') {

        #
        # Does this system even support this feature?
        #
        my $feature_found = undef;

        my $cmd = 'yum --help';
        open(INPUT,"$cmd|") or die("Couldn't run $cmd for input\n");
        while(<INPUT>) {
            if( m/^autoremove/ ) {
                $feature_found = 'yes';
            }
        }
        close(INPUT);

        unless( $feature_found ) { 

            # packages cannot begin with a hyphen, so just pass the response back in this way
            $pending_pkg_changes{'-autoremove_unsupported'} = 1;

            return %pending_pkg_changes;
        }

        %pending_pkg_changes = do_pkg_manager_dry_run('autoremove');


    } else {

        foreach my $pkg (keys %::PKGS_FROM_STATE_DEFINITION) {

            my $options = $::PKGS_FROM_STATE_DEFINITION{$pkg};

            if($options =~ m/\bunwanted\b/i) {

                $space_delimited_pkg_list{'remove'}  .= " $pkg" if($pkgs_already_installed{"$pkg.$basearch"});

            } else {

                #
                # If the package is already installed, no need to try and install it
                # again, so skip it.
                #
                next if( $pkgs_already_installed{"$pkg.$basearch"} );
                next if( $pkgs_already_installed{"$pkg"} );

                $space_delimited_pkg_list{'install'}  .= " $pkg";
            }
        }

        %pending_pkg_changes = do_pkg_manager_dry_run($action, $space_delimited_pkg_list{$action});
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

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my $basearch = `rpm -q --qf "%{arch}" -f /`;
    chomp $basearch;

    ssm_print "$debug_prefix $basearch\n" if( $::o{debug} );

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; sleep 2; }

    return $basearch;
}


sub update_pkg_availability_data {

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

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
    ssm_print ">>\n>> remove_pkgs()\n" if( $::o{debug} );

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
    ssm_print ">> $cmd\n" if( $::o{debug} );
    ssm_print "FIXING:  Packages -> Removing.\n";
    run_cmd($cmd);

    unlink($file);

    return 1;
}

#XXX is this the right thing to do?  Just an "yum update"?
sub upgrade_pkgs {
    ssm_print ">>\n>> upgrade_pkgs()\n" if( $::o{debug} );

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
    ssm_print ">>   $cmd\n" if( $::o{debug} );
    run_cmd($cmd);

    unlink($file);

    return 1;    
}


sub install_pkgs {

    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

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
    ssm_print "$debug_prefix $cmd\n" if( $::o{debug} );
    run_cmd($cmd);

    unlink($file);

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; sleep 2; }

    return 1;    
}


#
# returns a hash of:   $package.$basearch => $version
#
sub get_pkgs_currently_installed {
    
    my $timer_start; my $debug_prefix; if( $::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }


    my %hash;

    if( $::o{pkg_manager} eq 'yum' ) {

        my $cmd = 'rpm -qa --queryformat "%{NAME}.%{ARCH}\t%{VERSION}\tinstalled\n"';
        ssm_print "$debug_prefix system($cmd)\n" if( $::o{debug} );
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
                    ssm_print "$debug_prefix PKG $pkg = $version\n" if( $::o{debug} );
                }
        }
        close(FILE);
    }

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; sleep 2; }

    return %hash;
}


sub get_pkgs_provided_by_pkgs_from_state_definition {
    ssm_print ">>\n>> get_pkgs_provided_by_pkgs_from_state_definition()\n" if( $::o{debug} );

    my $PKGS_FROM_STATE_DEFINITION = shift;
    return %$PKGS_FROM_STATE_DEFINITION;
}


sub get_running_kernel_pkg_name {

    use POSIX;
    my $release = (uname())[2];

    my $running_kernel_pkg_name = `rpm -qf /lib/modules/${release}/kernel`;
    chomp $running_kernel_pkg_name;
    $running_kernel_pkg_name =~ s/:.*//;

    return $running_kernel_pkg_name;
}


sub autoremove_pkgs {

    my @pkgs = @_;

    my $timer_start; my $debug_prefix; if( $main::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    return remove_pkgs(@pkgs);
}


sub get_pkg_repo_update_time_stamp {
    return undef;
}

#
################################################################################


1;

