#  
#   Copyright (C) 2006-2015 Brian Elliott Finley
#
#    vi: set et ai ts=4 filetype=perl tw=0 number:
# 

package SimpleStateManager::Dpkg;

use Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(
                upgrade_ssm
                upgrade_pkgs
                install_pkgs
                remove_pkgs
                get_pkgs_provided_by_pkgs_from_state_definition
                get_pkgs_currently_installed
                get_pkgs_that_pkg_manager_says_to_upgrade
                get_pkg_dependencies
                get_pkg_reverse_dependencies
                get_pkg_provides
                get_running_kernel_pkg_name
                get_pending_pkg_changes
                get_native_arch
                update_pkg_availability_data
            );
use strict;
use SimpleStateManager qw(ssm_print run_cmd);

use AptPkg::Config '$_config';
use AptPkg::System '$_system';
use AptPkg::Cache;

$_config->init;
$_system            = $_config->system;
$_config->{quiet}   = 2;

my $pkg_cache = AptPkg::Cache->new;
my $policy = $pkg_cache->policy;
my $pkg_changes_made;


################################################################################
#
#   This package provides the following functions:
#
#       % egrep '^sub ' lib/SimpleStateManager/Dpkg.pm | perl -p -e 's/^sub /#   /; s/ {//;' | sort
#
#   do_apt_get_dry_run
#   get_native_arch
#   get_pending_pkg_changes
#   get_pkg_dependencies
#   get_pkg_dependencies_old
#   get_pkg_provides
#   get_pkg_reverse_dependencies
#   get_pkgs_currently_installed
#   get_pkgs_from_state_definition
#   get_pkgs_provided_by_pkgs_from_state_definition
#   get_pkgs_that_pkg_manager_says_to_upgrade
#   get_pkgs_we_need_to_install
#   get_pkgs_we_need_to_upgrade
#   get_running_kernel_pkg_name
#   install_pkgs
#   remove_pkgs
#   update_pkg_availability_data
#   upgrade_pkgs
#   upgrade_ssm
#
################################################################################


################################################################################
#
#   Subroutines
#

sub upgrade_ssm {

    my $timer_start; my $debug_prefix; if( $main::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my $pkg = 'ssm';

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


sub upgrade_pkgs {

    my $timer_start; my $debug_prefix; if( $main::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    $pkg_changes_made = 'yes';
    return install_pkgs(@_);    
}


sub install_pkgs {

    my $timer_start; my $debug_prefix; if( $main::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my @pkgs = @_;

    my $pkgs;
    foreach(@pkgs) {
        next unless(defined $_);
        $pkgs .= " $_";
    }

    if(defined $pkgs) {

        my $cmd;

        ssm_print "FIXING:  Packages -> Downloading...\n";
        $cmd = 'DEBIAN_FRONTEND=noninteractive apt-get -q=2 --force-yes --yes --download-only install';
        run_cmd($cmd);

        ssm_print "FIXING:  Packages -> Installing...\n";
        $cmd = 'DEBIAN_FRONTEND=noninteractive apt-get -q=2 --force-yes --yes install' . $pkgs;
        run_cmd($cmd);

        # Remove any packages lying around in the cache.  Again.
        $cmd = 'apt-get clean';
        run_cmd($cmd);
    }

    $pkg_changes_made = 'yes';

    return 1;    
}


sub remove_pkgs {

    my @pkgs = @_;

    my $timer_start; my $debug_prefix; if( $main::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my $cmd;
    foreach(@pkgs) {
        next unless(defined $_);
        $cmd .= " $_";
    }

    if(defined $cmd) {
        ssm_print "FIXING:  Packages -> Removing.\n";
        $cmd = 'DEBIAN_FRONTEND=noninteractive apt-get -q=2 --force-yes --yes remove' . $cmd;
        run_cmd($cmd);
    }

    $pkg_changes_made = 'yes';

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; sleep 2; }

    return 1;
}


sub get_pkgs_currently_installed {

    my $timer_start; my $debug_prefix; if( $main::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    # set up the cache
    if($pkg_changes_made) {
        $pkg_cache = AptPkg::Cache->new;
        $policy = $pkg_cache->policy;
        $pkg_changes_made = undef;
    }

    #
    # returns a hash: package => version
    #
    my %pkgs_currently_installed;
    foreach my $pkg (sort keys %{$pkg_cache}) {
        my $p_ref = $pkg_cache->{$pkg};
        if( $p_ref->{CurrentState} and $p_ref->{CurrentState} eq 'Installed' ) {
            #print "get_pkgs_currently_installed() >> $pkg $p_ref->{CurrentVer}{VerStr}\n" if($main::o{debug});
            $pkgs_currently_installed{$pkg}{'current_version'}   = $p_ref->{CurrentVer}{VerStr};
            if ( my $c_ref = $policy->candidate($p_ref) ) {
                $pkgs_currently_installed{$pkg}{'candidate_version'} = $c_ref->{VerStr} if( $c_ref->{VerStr} ne $p_ref->{CurrentVer}{VerStr} );
            }
        }
    }

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; sleep 2; }

    return %pkgs_currently_installed;
}


sub update_pkg_availability_data {

    my $timer_start; my $debug_prefix; if( $main::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    if( $::o{no_pkg_repo_update} ) {
        ssm_print "INFO:    Not updating package repo info\n";
        return 1;
    }

    #
    # Get the latest updates
    my $cmd = 'apt-get -q=2 update';
    #
    # Run even if --no so that we don't get 'Unable to locate package X'
    # errors. -BEF-
    run_cmd($cmd, undef, 1);

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; sleep 2; }

    return 1;
}


sub get_pkgs_we_need_to_upgrade {

    my $timer_start; my $debug_prefix; if( $main::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my %pkgs_we_need_to_upgrade;

    update_pkg_availability_data();

    my %pkgs_currently_installed = get_pkgs_currently_installed();

    foreach my $pkg (keys %pkgs_currently_installed) {

        if( $pkgs_currently_installed{$pkg}{'candidate_version'} ) {

            # debug output
            ssm_print "$debug_prefix Needs upgrade:  $pkg " if( $main::o{debug} );
            ssm_print "Current: $pkgs_currently_installed{$pkg}{'current_version'}  " if( $main::o{debug} );
            ssm_print "Upgrade to: $pkgs_currently_installed{$pkg}{'candidate_version'}\n" if( $main::o{debug} );

            $pkgs_we_need_to_upgrade{$pkg} = $pkgs_currently_installed{$pkg}{'candidate_version'};
        }
    }

    #foreach my $pkg (keys %pkgs_currently_installed) {
    #
    #    my $p_ref = $pkg_cache->{$pkg};
    #
    #    if ( my $c_ref = $policy->candidate($p_ref) ) {
    #
    #        my $candidate_version = $c_ref->{VerStr};
    #        my $current_version   = $p_ref->{CurrentVer}{VerStr};
    #
    #        if( $candidate_version ne $current_version ) {
    #            $pkgs_we_need_to_upgrade{$pkg} = $candidate_version;
    #            ssm_print ">> Needs upgrade:  $pkg  CurrVer: $current_version  CandVer: $candidate_version\n" if( $main::o{debug} );
    #        }
    #    }
    #}

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; sleep 2; }

    return %pkgs_we_need_to_upgrade;
}


sub get_pkgs_we_need_to_install {

    my $timer_start; my $debug_prefix; if( $main::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my %pkgs_currently_installed = get_pkgs_currently_installed();

    my %pkgs_we_need_to_install;
    foreach my $pkg (keys %::PKGS_FROM_STATE_DEFINITION) {
    print "X=X $pkg\n";
        if( ! $pkgs_currently_installed{$pkg} ) {
            $pkgs_we_need_to_install{$pkg} = 1;
            ssm_print ">> Needs to be installed:  $pkg\n" if( $main::o{debug} );
        }
    }
    
    return %pkgs_we_need_to_install;
}


#
#   my %pending_pkg_changes = get_pending_pkg_changes($action);
#   
#       Where $action is one of 'install', 'remove', or 'upgrade'.
#
sub get_pending_pkg_changes {

    my $action = shift;

    my $timer_start; my $debug_prefix; if( $main::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my %pkgs_already_installed = get_pkgs_currently_installed();

    my $native_arch = get_native_arch();

    my %space_delimited_pkg_list;
    my %pending_pkg_changes;

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
                next if( $pkgs_already_installed{"$pkg:$native_arch"} );
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

        if( $pending_pkg_changes{$pkg}{action} eq 'remove' ) {

            if ($::PKGS_TARGET_STATE{$pkg} and ($::PKGS_TARGET_STATE{$pkg} ne 'remove')) {
                ssm_print "WARNING: Package $pkg is now marked as $pending_pkg_changes{$pkg}{action}, but was already marked as $::PKGS_TARGET_STATE{$pkg}\n";

            } elsif ($::PKGS_FROM_STATE_DEFINITION{$pkg} and $::PKGS_FROM_STATE_DEFINITION{$pkg} !~ m/\bunwanted\b/i ) {
                ssm_print "WARNING: Package $pkg is now marked as $pending_pkg_changes{$pkg}{action}, but is marked for install in the config.\n";
            }

        } else {
            $::PKGS_TARGET_STATE{$pkg} = $pending_pkg_changes{$pkg}{action};
        }
    }

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; sleep 2; }

    return %pending_pkg_changes;
}


#
#   Usage:  my %hash = do_apt_get_dry_run($action, $space_delimited_pkg_list);
#   Usage:  my %hash = do_apt_get_dry_run("install", "ash sendmail rsync");
#   Usage:  my %hash = do_apt_get_dry_run("remove", "ash sendmail rsync");
#   Usage:  my %hash = do_apt_get_dry_run("upgrade");
#
#       Returns a hash of $pkg = $pending_state;
#       Where $pending_state may be one of 'install', 'upgrade', 'dist-upgrade', or 'remove'.
#
sub do_apt_get_dry_run {

    my $action                   = shift;
    my $space_delimited_pkg_list = shift;

    my $timer_start; my $debug_prefix; if( $main::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

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

    my $cmd = "apt-get --dry-run $action $space_delimited_pkg_list";
    ssm_print "$debug_prefix $cmd\n" if( $main::o{debug} );
    open(INPUT,"$cmd|") or die("Couldn't run $cmd for input");
    while(<INPUT>) {
        
        #
        # Example output (as INPUT):
        #
        #   Inst libapt-pkg4.12 [1.0.1ubuntu2.5] (1.0.1ubuntu2.6 Ubuntu:14.04/trusty-updates [amd64])
        #   Conf libapt-pkg4.12 (1.0.1ubuntu2.6 Ubuntu:14.04/trusty-updates [amd64])
        #   Inst apt [1.0.1ubuntu2.5] (1.0.1ubuntu2.6 Ubuntu:14.04/trusty-updates [amd64])
        #   Conf apt (1.0.1ubuntu2.6 Ubuntu:14.04/trusty-updates [amd64])
        #   Inst libapt-inst1.5 [1.0.1ubuntu2.5] (1.0.1ubuntu2.6 Ubuntu:14.04/trusty-updates [amd64])
        #   Inst libpoppler44 [0.24.5-2ubuntu4] (0.24.5-2ubuntu4.1 Ubuntu:14.04/trusty-updates [amd64])
        #   [snip]
        #
        #   Remv skype:i386 [4.3.0.37-1]
        #   Remv libgl1-mesa-dri:i386 [10.1.3-0ubuntu0.1]
        #   [snip]
        #
        if(m/^Inst\s+(\S+)\s+/) { 

            my $pkg = $1;

            my $pkg_ref = $pkg_cache->{$pkg};
            if ($pkg_ref->{CurrentState} and $pkg_ref->{CurrentState} eq 'Installed') {

                # Ok, upgrading existing package
                $pending_pkg_changes{$pkg}{action} = 'upgrade';
                $pending_pkg_changes{$pkg}{current_version} = $pkg_ref->{CurrentVer}{VerStr};
                if (my $candidate_pkg_ref = $policy->candidate($pkg_ref))
                {
                    $pending_pkg_changes{$pkg}{target_version} = $candidate_pkg_ref->{VerStr};
                }

            } else {

                # Not an upgrade, must be a fresh install
                $pending_pkg_changes{$pkg}{action} = 'install';

            }

        } elsif(m/^Remv\s+(\S+)\s+/) {

            my $pkg = $1;
            $pending_pkg_changes{$pkg}{action} = 'remove';
        }
    }
    close(INPUT);

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; sleep 2; }

    return %pending_pkg_changes;
}


sub get_pkgs_that_pkg_manager_says_to_upgrade {

    my $timer_start; my $debug_prefix; if( $main::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my %pkgs_we_need_to_upgrade = get_pkgs_we_need_to_upgrade();

    return (keys %pkgs_we_need_to_upgrade);
}


#
# Returns a hash of packages, with the package names as the keys.
#
# NOTE:  If there are alternates as dependencies, all alternates are returned
#        as the a key in a space seperated string format. -BEF-
#
sub get_pkg_dependencies_old {

    my $timer_start; my $debug_prefix; if( $main::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my @packages = @_;

    my $cmd = 'apt-cache show';
    foreach my $pkg (@packages) {
        $cmd .= " $pkg"
    }

    ssm_print ">> " . substr($cmd, 0, 72) . "...\n" if( $main::o{debug} );
    my @array;
    open(OUTPUT,"$cmd|") or die;
        while(<OUTPUT>) {
            if(s/^Depends://) {
                push @array, split(/,/);
            }
        }
    close(OUTPUT);

    my %dependencies;
    foreach(@array) {
        chomp;
        print "   $_\n" if($main::o{debug});
        s/^\s+//;
        
        ## If there's an alternate dependency "this | that", this only 
        ## gets the first one.  May want to make this whole function
        ## more comprehensive at some point. -BEF-
        #s/\s.*//;   

        # If there's an alternate dependency "this | that", this
        # get's all of them as a space separated list. -BEF-
        s/ \(= \S+\)( \|)?//g;
        $dependencies{$_} = 1;
    }

    my %erasures; #XXX do anything with this? -BEF- 2008.10.20
    return (\%dependencies, \%erasures);
}


sub get_pkg_dependencies {

    my $timer_start; my $debug_prefix; if( $main::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my @packages = @_;

    # [$] apt-cache depends sendmail
    # sendmail
    #   Depends: sendmail-base
    #   Depends: sendmail-bin
    #   Depends: sendmail-cf
    #   Depends: sensible-mda
    #   Suggests: sendmail-doc
    #   Suggests: rmail
    #   Breaks: sendmail-base
    #   Breaks: <sendmail-base:i386>
    #   Replaces: sendmail-base
    #   Replaces: <sendmail-base:i386>
    #   Replaces: <sendmail-tls>
    #   Replaces: <sendmail-tls:i386>
    #
    my $cmd = 'apt-cache depends';
    foreach my $pkg (@packages) {
        $cmd .= " $pkg"
    }
    ssm_print ">> " . substr($cmd, 0, 72) . "...\n" if( $main::o{debug} );

    my %dependencies;
    open(OUTPUT,"$cmd|") or die;
    while(<OUTPUT>) {
        if(m/^\s+Depends:\s+(\S+)/) {
            my $pkg = $1;
            $dependencies{$pkg} = 1;
            ssm_print "get_pkg_dependencies() >> $pkg\n" if( $main::o{debug} );
        }
    }
    close(OUTPUT);

    return (\%dependencies);
}


sub get_pkg_reverse_dependencies {

    my $timer_start; my $debug_prefix; if( $main::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my @packages = @_;

    my %reverse_dependencies;

    foreach my $pkg (@packages) {

        #
        # Find the reverse dependencies
        my $cmd = "apt-cache rdepends $pkg";
        ssm_print ">> $cmd\n" if( $main::o{debug} );
        my @rdeps;
        open(OUTPUT,"$cmd|") or die;
            while(<OUTPUT>) {
                chomp;
                #
                # Match this:
                #   package
                #
                # or this:
                #   |package
                #
                if(m/^\s+[|]?(\S+)/) {
                    push @rdeps, $1;
                }
            }
        close(OUTPUT);

        #
        # Is package really a dependency of each reverse dependency?  If
        # not, remove the reverse dependency.
        #
        # Now take the results for this particular package, and add them
        # to the compiled hash of results.
        foreach my $rdep (@rdeps) {

            #
            # get dependencies of reverse dependencies
            #
            # Unfortunately, rdepends includes Suggests: (and maybe 
            # Replaces:) entries as well as Depends:.  So now we must 
            # query the resulting reverse-dependencies for their 
            # dependencies to see if $pkg is actually listed there.  If 
            # not, then it must just be a Recommends: or Suggests:.
            my %dependencies = get_pkg_dependencies($rdep);

            my @pkg_alternatives;
            foreach $_ (keys %dependencies) {
                push @pkg_alternatives, split(/\s+/, $_);
            }
            foreach my $dependency (@pkg_alternatives) {
                if($dependency eq $pkg) {
                    $reverse_dependencies{$rdep} = 1; 
                }
            }
        }
    }

    return %reverse_dependencies;
}

sub get_pkgs_from_state_definition {

    my $timer_start; my $debug_prefix; if( $main::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    return get_pkg_provides(keys %::PKGS_FROM_STATE_DEFINITION);
}

sub get_pkgs_provided_by_pkgs_from_state_definition {

    my $timer_start; my $debug_prefix; if( $main::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    return get_pkg_provides(keys %::PKGS_FROM_STATE_DEFINITION);
}

#
# Debian packages have the concept of "providing" a capability, which
# may be treated as a virtual package.  For example, exim, postfix, and
# sendmail all "provide" the "mail-transport-agent" capability.  This
# function returns the provided capabilities of all packages in the
# state definition file. -BEF-
#
sub get_pkg_provides {

    my @packages = @_;

    my $timer_start; my $debug_prefix; if( $main::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my $cmd = 'apt-cache show';
    foreach my $pkg (@packages) {
        $cmd .= " $pkg"
    }

    ssm_print ">> " . substr($cmd, 0, 72) . "...\n" if( $main::o{debug} );
    my @array;
    open(OUTPUT,"$cmd|") or die;
        while(<OUTPUT>) {
            if(s/^Provides://) {
                push @array, split(/,/);
            }
        }
    close(OUTPUT);

    my %provides;
    foreach(@array) {
        chomp;
        s/^\s+//;
        s/\s.*//;   
        $provides{$_} = 1;
    }

    return %provides;
}

sub get_running_kernel_pkg_name {

    my $timer_start; my $debug_prefix; if( $main::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    use POSIX;
    my $release = (uname())[2];

    my $running_kernel_pkg_name = `dpkg -S /lib/modules/${release}/kernel`;
    chomp $running_kernel_pkg_name;
    $running_kernel_pkg_name =~ s/:.*//;

    return $running_kernel_pkg_name;
}

sub get_native_arch {

    my $timer_start; my $debug_prefix; if( $main::o{debug} ) { $debug_prefix = (caller(0))[3] . "()"; $timer_start = time; ssm_print "$debug_prefix\n"; }

    my $native_arch = `dpkg --print-architecture`;
    chomp $native_arch;

    ssm_print "$debug_prefix $native_arch\n" if( $main::o{debug} );

    if( $::o{debug} ) { my $duration = time - $timer_start; ssm_print "$debug_prefix Execution time: $duration s\n$debug_prefix\n"; sleep 2; }

    return $native_arch;
}

#
################################################################################


1;

