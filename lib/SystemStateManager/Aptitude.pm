#  
#   Copyright (C) 2006-2008 Brian Elliott Finley
#
#   $Id: SystemStateManager.pm 234 2008-10-16 02:06:06Z finley $
#    vi: set filetype=perl tw=0:
# 

package SystemStateManager::Aptitude;

use Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(
                upgrade_ssm
                reinstall_pkgs
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
            );

use strict;
use SystemStateManager qw(ssm_print run_cmd);


################################################################################
#
#   This package provides the following functions:
#
#       % egrep '^sub ' lib/SystemStateManager/Aptitude.pm | perl -pi -e 's/^sub /#   /; s/ {//;' | sort
#
#   get_pkg_dependencies
#   get_pkg_provides
#   get_pkg_reverse_dependencies
#   get_pkgs_currently_installed
#   get_pkgs_provided_by_pkgs_from_state_definition
#   get_pkgs_that_pkg_manager_says_to_upgrade
#   get_running_kernel_pkg_name
#
################################################################################


################################################################################
#
#   Subroutines
#

sub upgrade_ssm {

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

sub reinstall_pkgs {
    ssm_print ">>\n>> reinstall_pkgs()\n" if( $main::o{debug} );

    my @pkgs = @_;

    my $package_list;
    foreach(@pkgs) {
        next unless(defined $_);
        $package_list .= " $_";
    }

    my $cmd;
    if(defined $package_list) {
        ssm_print "Downloading packages...\n";
        $cmd = 'aptitude -y --download-only reinstall ' . $package_list;
        run_cmd($cmd);

        ssm_print "Re-installing packages...\n";
        $cmd = 'aptitude -y reinstall ' . $package_list;
        run_cmd($cmd);

        # Remove any packages lying around in the cache.  Again.
        $cmd = 'aptitude clean';
        run_cmd($cmd);
    }

    return 1;    
}


sub upgrade_pkgs {
    ssm_print ">>\n>> upgrade_pkgs()\n" if( $main::o{debug} );

    return install_pkgs(@_);    
}


sub install_pkgs {
    ssm_print ">>\n>> install_pkgs()\n" if( $main::o{debug} );

    my @pkgs = @_;

    my $pkgs;
    foreach(@pkgs) {
        next unless(defined $_);
        $pkgs .= " $_";
    }

    if(defined $pkgs) {

        my $cmd;

        ssm_print "FIXING:  Packages -> Downloading.\n";
        $cmd = 'aptitude -y --download-only install' . $pkgs;
        run_cmd($cmd);

        ssm_print "FIXING:  Packages -> Installing.\n";
        $cmd = 'aptitude -y install' . $pkgs;
        run_cmd($cmd);

        # Remove any packages lying around in the cache.  Again.
        $cmd = 'aptitude clean';
        run_cmd($cmd);
    }

    return 1;    
}


sub remove_pkgs {
    ssm_print ">>\n>> remove_pkgs()\n" if( $main::o{debug} );

    my @pkgs = @_;

    my $cmd;
    foreach(@pkgs) {
        next unless(defined $_);
        $cmd .= " $_";
    }

    if(defined $cmd) {
        ssm_print "FIXING:  Packages -> Removing.\n";
        $cmd = 'aptitude -y remove' . $cmd;
        run_cmd($cmd);
    }

    return 1;
}


sub get_pkgs_currently_installed {
    ssm_print ">>\n>> get_pkgs_currently_installed()\n" if( $main::o{debug} );

    #
    # returns a hash: package => version
    #

    my %hash;

    my $cmd = 'dpkg -l';
    ssm_print ">> $cmd\n" if( $main::o{debug} );
    open(FILE,"$cmd|") or die("couldn't open $cmd for reading");
    while (<FILE>) {

            #
            # Only choose packages marked as installed (ii)
            #
            # Sample output:
            #
            #   ii  abcde         2.3.99.2-1         A Better CD Encoder
            #   ii  acpi          0.09-1             displays information on ACPI devices
            #   ii  acpi-support  0.73               a collection of useful events for acpi
            #   ii  acpid         1.0.4-1ubuntu10    Utilities for using ACPI power management
            #   ii  acroread      7.0.1-0.0.ubuntu1  Adobe Acrobat Reader: Portable Document Form
            #   ii  adduser       3.80ubuntu2        Add and remove users and groups
            #
            #                   Matches the package name -> $1
            #                   | 
            #                   |       Matches the version string -> $2
            #                   |       |
            #                   vvvvv   vvvvv
            next unless(m/^ii\s+(\S+)\s+(\S+)\s+/);

            $hash{$1} = $2;
    }
    close(FILE);

    return %hash;
}


sub get_pkgs_that_pkg_manager_says_to_upgrade {
    ssm_print ">>\n>> get_pkgs_that_pkg_manager_says_to_upgrade()\n" if( $main::o{debug} );

    # In this hash, 'pkg' is the key, and 'version' is the value.
    my %hash;
    my $cmd;

    #
    # Get the latest updates
    ssm_print "OK:      Packages -> Updating availability information.\n";
    $cmd = 'aptitude update -q=2';
    #
    # Run even if --no so that we don't get 'Unable to locate package X'
    # errors. -BEF-
    run_cmd($cmd, undef, 1);

    #
    # Get a list of packages that would be upgraded
    $cmd = q(aptitude search --display-format "%p" '~U');
    ssm_print ">> $cmd\n" if( $main::o{debug} );

    #
    # This is harmless, so we run it even if --dry-run, so that we get
    # the output that is interesting for the rest of the dry run.
    #
    open(OUTPUT,"$cmd|");
        while(<OUTPUT>) {
            chomp;
            if( m/^(\S+)/ ) {
                $hash{$1} = 1;
                ssm_print ">>> $1\n" if $main::o{debug};
            }
        }
    close(OUTPUT);

    return (keys %hash);
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

    my $cmd = 'apt-cache show';
    foreach my $pkg (@packages) {
        $cmd .= " $pkg"
    }

    ssm_print ">> $cmd\n" if( $main::o{debug} );
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


sub get_pkg_reverse_dependencies {
    ssm_print ">>\n>> get_pkg_reverse_dependencies()\n" if( $main::o{debug} );

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

sub get_pkgs_provided_by_pkgs_from_state_definition {
    ssm_print ">>\n>> get_pkgs_provided_by_pkgs_from_state_definition()\n" if( $main::o{debug} );

    my $PKGS_FROM_STATE_DEFINITION = shift;
    return get_pkg_provides(keys %$PKGS_FROM_STATE_DEFINITION);
}

#
# Debian packages have the concept of "providing" a capability, which
# may be treated as a virtual package.  For example, exim, postfix, and
# sendmail all "provide" the "mail-transport-agent" capability.  This
# function returns the provided capabilities of all packages in the
# state definition file. -BEF-
#
sub get_pkg_provides {
    ssm_print ">>\n>> get_pkg_provides()\n" if( $main::o{debug} );

    my @packages = @_;

    my $cmd = 'apt-cache show';
    foreach my $pkg (@packages) {
        $cmd .= " $pkg"
    }

    ssm_print ">> $cmd\n" if( $main::o{debug} );
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

    use POSIX;
    my $release = (uname())[2];

    my $running_kernel_pkg_name = `dpkg -S /lib/modules/${release}/kernel`;
    chomp $running_kernel_pkg_name;
    $running_kernel_pkg_name =~ s/:.*//;

    return $running_kernel_pkg_name;
}

#
################################################################################


1;

